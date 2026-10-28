// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ArbitratorRegistry} from "./ArbitratorRegistry.sol";

interface IAppeal {
    function onAppeal(
        address deal,
        address originalArb,
        address challenger,
        uint256 bond,
        uint256 origBuyer,
        uint256 origSeller
    ) external;
    function prepareFirstPanel(address deal, address arb) external;
    function isCaseActive(address deal) external view returns (bool);
}

/**
 * @title GhostEscrowV2OpenCImpl — Open (deploy-then-join) template, CLONE implementation (Phase D)
 * @notice Behavior-identical port of GhostEscrowV2Open for the EIP-1167 clone
 *         factory (see GhostEscrowV2CImpl for the port pattern): per-deal
 *         parameters move to storage written once by the factory-gated
 *         `initialize`; FACTORY + ARBITRATOR_REGISTRY are implementation
 *         immutables; the bare implementation self-locks in the constructor.
 *         The open-slot semantics (exactly one of buyer/seller zero at init,
 *         filled once via join/joinAndDeposit with the creator's EIP-712
 *         invite, OPEN-CR-1 buyer-open full-funding) are unchanged.
 *
 * Original v2 template natspec follows (unchanged semantics):
 * @notice Immutable, single-deal escrow, identical deposit/release/refund
 *         lifecycle to v1.1 GhostEscrow, PLUS a VIEW-ONLY reference to the
 *         ArbitratorRegistry so that a mutually-replaced arbitrator must be
 *         bonded and eligible for the deal's value. The fund-holding surface
 *         stays minimal: the registry call is a STATICCALL view and
 *         replaceArbitrator remains nonReentrant.
 *
 * @dev Invariant (locked, §1.2a): every arbitrator that can rule is currently
 *      bonded >= the deal's tier. Enforced at TWO gates:
 *        - creation: the registry-aware EscrowFactoryV2 checks isEligible
 *          (§5.1-C);
 *        - replacement: this contract re-checks isEligible(newArbitrator,
 *          dealAmount) inside replaceArbitrator and reverts otherwise.
 *      Residual risk (both gates are one-time checks): an arbitrator's bond
 *      can be withdrawn AFTER eligibility is checked — bounded by the
 *      registry's UNBONDING_DELAY which is sized >= the appeal-path horizon
 *      (Phase C), so a ruling that could be overturned lands while the bond
 *      is still committed.
 *
 * @dev Phase B/C accommodations (deliberately NOT wired, but not precluded):
 *      - RuledPendingAppeal: a staged-ruling hold (funds parked after rule()
 *        until the appeal window closes) so an AppealCourt overturn can
 *        re-settle. Phase A rule() pays out immediately, exactly as v1.1;
 *        nothing here blocks adding the hold state in a later template.
 *      - Fee-free cooperative cancel: v1.1 refund() charges the platform fee
 *        (product decision on record). A fee-free mutual cancel arrives in a
 *        later phase; this template's refund() is unchanged so the fee model
 *        stays deliberate, and no code here prevents a future fee-free path.
 *
 * @dev The registry reference is immutable (pinned at deploy). If the registry
 *      is ever replaced, a NEW factory deploys NEW deals against the new
 *      registry; this deal keeps its original reference forever (versioned
 *      templates, §5.7). The registry is ownerless and has no selfdestruct, so
 *      this view call can never brick replaceArbitrator.
 */
contract GhostEscrowV2OpenCImpl is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ─── Types ───────────────────────────────────────────────────────────────

    enum State {
        Created, // waiting for deposit
        PartiallyDeposited, // some funds in, not enough
        Active, // exact amount locked
        Disputed,
        Completed,
        Cancelled,
        Expired,
        RuledPendingAppeal // staged ruling hold (C): funds held during the appeal window
    }

    // ─── Implementation immutables (shared by every clone) ──────────────────

    address public immutable FACTORY; // sole caller of initialize
    ArbitratorRegistry public immutable ARBITRATOR_REGISTRY; // view-only, STATICCALL

    // ─── Per-deal parameters (storage; set once in initialize) ───────────────

    IERC20 public token;
    // Open variant: exactly ONE of buyer/seller is set at init (the creator);
    // the other is address(0) until a claimant join()s it, set-once.
    address public buyer;
    address public seller;
    address public creator; // the party fixed at init
    bool public creatorIsBuyer; // true => open slot is the seller
    bool public joined; // set true when the open slot is filled; gates all value paths
    address public feeRecipient;
    uint256 public dealAmount; // exact amount required to go Active
    uint256 public platformFeeBps; // e.g. 150 = 1.5%
    uint256 public arbitratorFee; // fixed; pre-paid by the dispute opener
    uint256 public depositDeadline; // initialize + depositTimeout (e.g. 72h)
    uint256 public autoReleaseDelay; // per-deal, bounded below
    bool private _initialized; // one-shot initialize guard (impl self-locks)

    /// Above this deal value a 3-panel is REQUIRED at first ruling (C-2).
    /// F7: immutable, set per template deployment — 25_000e6 is $25k ONLY for
    /// 6-decimal tokens; an 18-decimal template passes its own scaled value.
    uint256 public immutable HIGH_VALUE_THRESHOLD;
    /// v5 D3: arbitrator fee = max(dealAmount * ARB_FEE_BPS / 1e4, MIN_ARB_FEE), stored at initialize.
    uint256 public immutable ARB_FEE_BPS;
    uint256 public immutable MIN_ARB_FEE;
    /// v5 D4: keeper tip per un-sticking call = max(dealAmount * TIP_BPS / 1e4, MIN_TIP), all tips <= platform fee.
    uint256 public immutable TIP_BPS;
    uint256 public immutable MIN_TIP;
    /// v5 B: random arbitrator draw from a future blockhash; re-armed at most MAX_REARMS times (R2).
    uint256 public constant DRAW_DELAY = 4;
    uint256 public constant DRAW_HORIZON = 256;
    uint8 public constant MAX_REARMS = 2;
    /// v5 E1/R8: after this long without anyone able to decide, either party may split 50/50.
    uint256 public constant NO_ARB_TIMEOUT = 14 days;
    uint256 public constant APPEAL_WINDOW = 48 hours;
    uint256 public constant APPEAL_BOND_BPS = 2000;
    uint256 public constant MIN_AUTO_RELEASE = 1 days;
    uint256 public constant MAX_AUTO_RELEASE = 90 days;
    uint256 public constant MIN_DEPOSIT_TIMEOUT = 1 hours;
    uint256 public constant MAX_DEPOSIT_TIMEOUT = 30 days;
    /// F5: how long after a timeout slash the opener waits before reclaiming a
    /// fee pot no escalation panel ever consumed.
    uint256 public constant STRANDED_POT_DELAY = 30 days;

    // ─── Mutable state ───────────────────────────────────────────────────────

    address public arbitrator; // replaceable only by mutual signatures
    State public state;
    uint256 public deposited; // deal funds only (never the arbitrator fee)
    uint256 public arbitratorFeePot; // held separately from deal funds
    uint256 public autoReleaseDeadline;
    address public disputeOpener;
    uint256 public nonce; // increments on every accepted mutual action
    uint256 public appealDeadline;
    bool public appealed;
    uint8 public rulingStage;
    uint256 public rulingBuyerAmount;
    uint256 public rulingSellerAmount;
    bytes32 public rulingRationale;
    /// F5: SLA-timeout bookkeeping — who was slashed (excluded from the
    /// escalation draw) and when (anchors the stranded-pot valve).
    address public timeoutSlashedArb;
    uint256 public timeoutSlashedAt;

    /// @dev Who paid what, so expiry refunds go to the actual depositor.
    mapping(address => uint256) public depositedBy;

    /// v5 R1: explicit dispute phases (v4 overloaded arbitrator == 0 as "slashed").
    enum ArbPhase {
        None, // no dispute
        Drawing, // low-value dispute: waiting for drawArbitrator()
        Seated, // a drawn arbitrator holds the case
        Slashed, // the seated arbitrator was SLA-slashed and cleared
        Exhausted, // the draw missed its horizon MAX_REARMS+1 times: only mutual paths / stalemateSplit
        Panel // high-value (or escalated): the court owns the case
    }

    ArbPhase public arbPhase;
    uint256 public createdAtBlock; // R9: draw admits only arbitrators staked strictly before this block
    uint256 public disputeOpenedAt;
    uint256 public drawBlock;
    uint8 public rearms;
    /// v5 F3: payouts a recipient couldn't receive (token blocklist) — pull via withdrawOwed().
    mapping(address => uint256) public owed;
    uint256 public owedTotal;
    /// v5 D4: keeper tips, funded out of the platform fee at settlement; claimable once the deal is terminal.
    mapping(address => uint256) public tipOwed;
    uint256 public tipsTotal;

    // ─── EIP-712 typehashes (verifyingContract = this deal) ─────────────────
    // Identical to v1.1 so the client signing libs work unchanged for v2 deals.

    bytes32 private constant RELEASE_TYPEHASH = keccak256("Release(uint256 nonce,uint256 deadline)");
    bytes32 private constant REFUND_TYPEHASH = keccak256("Refund(uint256 nonce,uint256 deadline)");
    bytes32 private constant SPLIT_TYPEHASH = keccak256("Split(uint256 buyerAmount,uint256 nonce,uint256 deadline)");
    bytes32 private constant RESCUE_TYPEHASH =
        keccak256("RescueToken(address token,address to,uint256 nonce,uint256 deadline)");
    /// Open-claim authorization signed by the creator. `joiner == 0` => anyone
    /// with the link may claim; a specific `joiner` locks the claim to that taker.
    bytes32 private constant JOIN_TYPEHASH =
        keccak256("Join(address deal,uint256 deadline,address joiner)");

    // ─── Events ──────────────────────────────────────────────────────────────

    event Deposited(address indexed from, uint256 amount, uint256 total);
    event ExcessRefunded(address indexed to, uint256 amount);
    event StateChanged(State previous, State current);
    event Joined(address indexed joiner, bool joinerIsBuyer);
    event CancelledUnjoined(address indexed to, uint256 swept);
    event DisputeOpened(address indexed opener);
    event Released(address indexed to, uint256 amount, uint256 platformFee);
    event Refunded(address indexed to, uint256 amount, uint256 platformFee);
    event Split(uint256 buyerAmount, uint256 sellerAmount, uint256 platformFee, bool byArbitrator);
    event Ruled(uint256 buyerAmount, uint256 sellerAmount, uint256 platformFee, bytes32 rationaleHash);
    event ArbitratorDrawn(address indexed arb);
    event DrawRearmed(uint256 drawBlock);
    event DrawExhausted();
    event StalemateSplit(uint256 toBuyer, uint256 toSeller);
    event KeeperTip(address indexed keeper, uint256 amount);
    event OwedCredited(address indexed to, uint256 amount);
    event OwedWithdrawn(address indexed to, uint256 amount);
    event ArbitratorFeeSettled(address indexed to, uint256 amount, bool openerWon);
    event ArbitratorSlashed(address indexed arb, uint256 amount);
    event Expired(uint256 held);
    event ExpiredClaimed(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ─── Constructor (implementation only) + initialize (per clone) ──────────

    /// @dev See GhostEscrowV2CImpl: the constructor locks the bare
    ///      implementation; clones are initialized exactly once by the factory
    ///      in the same tx as their CREATE2 deploy.
    constructor(
        address _factory,
        ArbitratorRegistry _registry,
        uint256 _highValueThreshold,
        uint256 _arbFeeBps,
        uint256 _minArbFee,
        uint256 _tipBps,
        uint256 _minTip
    ) EIP712("GhostEscrow", "1") {
        require(_factory != address(0), "zero factory");
        require(address(_registry) != address(0), "zero registry");
        require(_highValueThreshold > 0, "zero threshold");
        FACTORY = _factory;
        ARBITRATOR_REGISTRY = _registry;
        HIGH_VALUE_THRESHOLD = _highValueThreshold;
        require(_arbFeeBps <= 1000 && _tipBps <= 100, "bad fee params");
        ARB_FEE_BPS = _arbFeeBps;
        MIN_ARB_FEE = _minArbFee;
        TIP_BPS = _tipBps;
        MIN_TIP = _minTip;
        _initialized = true; // the implementation itself can never be a deal
    }

    /// @notice One-shot per-clone initialization; same canonical terms tuple as
    ///         GhostEscrowV2CImpl with the open slot encoded as address(0), so
    ///         the clone's address is join-independent (G1 unchanged).
    function initialize(address _feeRecipient, uint256 _platformFeeBps, bytes calldata initData) external {
        require(msg.sender == FACTORY, "not factory");
        require(!_initialized, "initialized");
        _initialized = true;

        (
            address _token,
            address _buyer,
            address _seller,
            address _arbitrator,
            uint256 _dealAmount,
            uint256 _arbitratorFee,
            uint256 _depositTimeout,
            uint256 _autoReleaseDelay
        ) = abi.decode(initData, (address, address, address, address, uint256, uint256, uint256, uint256));

        require(_token != address(0) && _feeRecipient != address(0), "zero addr");
        // v5 D1/R4: no arbitrator (and no hand-set fee) at creation — one is drawn at random on dispute.
        require(_arbitrator == address(0) && _arbitratorFee == 0, "no arb at init");
        // G1: EXACTLY ONE of buyer/seller is open (address(0)); the other is the
        // creator. Never both-zero, never neither. The open slot is filled once
        // via join(); the CREATE2 address encodes it as 0 so it's join-independent.
        require((_buyer == address(0)) != (_seller == address(0)), "one open slot");
        address _creator = _buyer == address(0) ? _seller : _buyer;
        require(_dealAmount > 0, "zero amount");
        require(_platformFeeBps <= 1000, "fee too high"); // hard cap 10%
        require(_autoReleaseDelay >= MIN_AUTO_RELEASE && _autoReleaseDelay <= MAX_AUTO_RELEASE, "bad auto-release");
        require(_depositTimeout >= MIN_DEPOSIT_TIMEOUT && _depositTimeout <= MAX_DEPOSIT_TIMEOUT, "bad deposit timeout");
        // §5.1-C eligibility gate + C-5 court-bound gate (moved from the factory).
        require(ARBITRATOR_REGISTRY.court() != address(0), "no court");

        // F6: bind the deal token to the registry's staking token (USDC). Keeps
        // the stake gate (usdcStake * MULTIPLE >= dealAmount) decimal-consistent
        // and removes the fee-on-transfer / cross-deal court-bond risk by
        // construction — the court and eligibility math assume one known token.
        require(_token == address(ARBITRATOR_REGISTRY.STAKING_TOKEN()), "token != staking token");
        token = IERC20(_token);
        buyer = _buyer;
        seller = _seller;
        creator = _creator;
        creatorIsBuyer = _buyer != address(0);
        feeRecipient = _feeRecipient;
        dealAmount = _dealAmount;
        platformFeeBps = _platformFeeBps;
        uint256 pctFee = (_dealAmount * ARB_FEE_BPS) / 10_000;
        arbitratorFee = pctFee > MIN_ARB_FEE ? pctFee : MIN_ARB_FEE; // R4: the real fee, readable from day one
        createdAtBlock = block.number;
        depositDeadline = block.timestamp + _depositTimeout;
        autoReleaseDelay = _autoReleaseDelay;

        state = State.Created;
    }

    // ─── Open claim (set-once counterparty) ──────────────────────────────────

    /// @notice Claim the open counterparty slot. Gated by the creator's EIP-712
    ///         Join(deal, deadline, joiner) signature carried in the invite link.
    ///         `joiner == address(0)` => anyone with the link may claim; a specific
    ///         joiner locks the claim to that address (kills seller-open griefing).
    ///         Set-once: after this the party layout is immutable like GhostEscrowV2.
    function join(uint256 deadline, address joiner, bytes calldata inviteSig) external nonReentrant {
        // OPEN-CR-1: plain (unfunded) join is only for the SELLER-open case (the
        // joiner becomes the seller and has nothing to deposit). For a BUYER-open
        // deal the joiner MUST use joinAndDeposit with full funding, so sniping the
        // buyer slot costs the whole deal amount (the advertised mitigation).
        require(creatorIsBuyer, "buyer-open: use joinAndDeposit");
        _join(deadline, joiner, inviteSig);
    }

    /// @notice Claim + fund in ONE tx. Only valid when the open slot is the buyer
    ///         (creator is the seller): a griefer sniping the buyer slot must lock
    ///         the full deal amount, making the snipe economically irrational
    ///         (front-run mitigation A). nonReentrant + CEI (OPEN-3).
    function joinAndDeposit(uint256 deadline, address joiner, bytes calldata inviteSig, uint256 amount)
        external
        nonReentrant
    {
        require(!creatorIsBuyer, "open slot not buyer");
        _join(deadline, joiner, inviteSig);
        require(amount > 0, "zero");
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 credited = token.balanceOf(address(this)) - before;
        require(credited > 0, "zero credited");
        _credit(msg.sender, credited);
        // OPEN-CR-1: the buyer-open claim must FULLY fund in this tx (reach Active),
        // so a griefer can't take the buyer slot with a partial deposit.
        require(state == State.Active, "must fully fund");
    }

    function _join(uint256 deadline, address joiner, bytes calldata inviteSig) internal {
        require(!joined, "joined");
        require(state == State.Created, "bad state");
        require(block.timestamp <= deadline, "invite expired");
        require(deadline <= depositDeadline, "invite outlasts window"); // G4
        require(msg.sender != creator && msg.sender != arbitrator, "bad joiner");
        if (joiner != address(0)) require(msg.sender == joiner, "not invited"); // G3
        bytes32 structHash = keccak256(abi.encode(JOIN_TYPEHASH, address(this), deadline, joiner));
        require(_hashTypedDataV4(structHash).recover(inviteSig) == creator, "bad invite");
        if (creatorIsBuyer) seller = msg.sender;
        else buyer = msg.sender;
        require(buyer != seller, "same party"); // defensive; creator==joiner already blocked
        joined = true;
        emit Joined(msg.sender, !creatorIsBuyer);
    }

    /// @notice Before anyone joins, the creator abandons the offer. Sweeps any
    ///         stray token balance (a mistaken pre-join direct transfer) to the
    ///         creator so nothing is stranded (OPEN-1). Deposits are gated on
    ///         `joined`, so `deposited` is 0 and there is no counterparty to refund.
    function cancelUnjoined() external nonReentrant {
        require(!joined, "joined");
        require(msg.sender == creator, "not creator");
        require(state == State.Created, "bad state");
        _setState(State.Cancelled);
        uint256 bal = token.balanceOf(address(this)) - owedTotal;
        _payOrOwe(creator, bal);
        emit CancelledUnjoined(creator, bal);
    }

    // ─── Deposit ─────────────────────────────────────────────────────────────

    function deposit(uint256 amount) external nonReentrant {
        require(joined, "not joined"); // G2: no value path before the open slot is filled
        require(state == State.Created || state == State.PartiallyDeposited, "bad state");
        require(block.timestamp <= depositDeadline, "deposit window closed");
        require(amount > 0, "zero");

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 credited = token.balanceOf(address(this)) - before;
        require(credited > 0, "zero credited");

        _credit(msg.sender, credited);
    }

    /// @notice Credit deal tokens transferred directly to this address.
    function syncDeposit() external nonReentrant {
        require(joined, "not joined"); // G2
        require(state == State.Created || state == State.PartiallyDeposited, "bad state");
        require(block.timestamp <= depositDeadline, "deposit window closed");

        // F6: sync books uncredited balance to the BUYER, so only the buyer may
        // trigger it — a seller/third-party direct transfer must not be silently
        // converted into buyer credit (expiry would then pay it to the buyer).
        require(msg.sender == buyer, "not buyer");
        uint256 uncredited = token.balanceOf(address(this)) - deposited;
        require(uncredited > 0, "nothing to sync");

        _credit(buyer, uncredited);
    }

    function _credit(address depositor, uint256 credited) internal {
        deposited += credited;
        depositedBy[depositor] += credited;
        emit Deposited(depositor, credited, deposited);

        if (deposited >= dealAmount) {
            uint256 excess = deposited - dealAmount;
            if (excess > 0) {
                deposited = dealAmount;
                depositedBy[depositor] -= excess;
                token.safeTransfer(depositor, excess);
                emit ExcessRefunded(depositor, excess);
            }
            autoReleaseDeadline = block.timestamp + autoReleaseDelay;
            _setState(State.Active);
        } else {
            _setState(State.PartiallyDeposited);
        }
    }

    // ─── Mutual actions ──────────────────────────────────────────────────────

    function release(uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig) external nonReentrant {
        require(state == State.Active || state == State.Disputed, "bad state");
        bool fromDisputed = state == State.Disputed;
        _consumeMutual(keccak256(abi.encode(RELEASE_TYPEHASH, nonce, deadline)), deadline, buyerSig, sellerSig);

        (uint256 toSeller, uint256 fee) = _split(dealAmount);
        _setState(State.Completed);
        _settleFeePotToOpener();
        _payDeal(seller, toSeller);
        _payFee(fee);
        if (fromDisputed) ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this)); // CEI: after state
        emit Released(seller, toSeller, fee);
    }

    /// @dev Fee model identical to v1.1 (a mutual refund still pays the
    ///      platform fee; a deposit-window expiry is fee-free). Fee-free
    ///      cooperative cancel is a Phase B/C change — not wired here.
    function refund(uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig) external nonReentrant {
        require(state == State.Active || state == State.Disputed, "bad state");
        bool fromDisputed = state == State.Disputed;
        _consumeMutual(keccak256(abi.encode(REFUND_TYPEHASH, nonce, deadline)), deadline, buyerSig, sellerSig);

        (uint256 toBuyer, uint256 fee) = _split(dealAmount);
        _setState(State.Cancelled);
        _settleFeePotToOpener();
        _payDeal(buyer, toBuyer);
        _payFee(fee);
        if (fromDisputed) ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this)); // CEI: after state
        emit Refunded(buyer, toBuyer, fee);
    }

    function mutualSplit(uint256 buyerAmount, uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        nonReentrant
    {
        require(state == State.Active || state == State.Disputed, "bad state");
        require(buyerAmount <= dealAmount, "over amount");
        bool fromDisputed = state == State.Disputed;
        _consumeMutual(
            keccak256(abi.encode(SPLIT_TYPEHASH, buyerAmount, nonce, deadline)), deadline, buyerSig, sellerSig
        );

        _setState(State.Completed);
        _settleFeePotToOpener();
        _paySplit(buyerAmount, false);
        if (fromDisputed) ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this)); // CEI: after state
    }

    function rescueToken(address stray, address to, uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        nonReentrant
    {
        if (stray == address(token)) {
            require(
                (state == State.Completed || state == State.Cancelled || state == State.Expired) && deposited == 0
                    && arbitratorFeePot == 0 && owedTotal == 0,
                "deal token not settled"
            );
        }
        require(to == buyer || to == seller, "bad dest");
        _consumeMutual(
            keccak256(abi.encode(RESCUE_TYPEHASH, stray, to, nonce, deadline)), deadline, buyerSig, sellerSig
        );

        uint256 bal = IERC20(stray).balanceOf(address(this));
        IERC20(stray).safeTransfer(to, bal);
        emit TokenRescued(stray, to, bal);
    }

    // ─── Dispute ─────────────────────────────────────────────────────────────

    function openDispute() external nonReentrant {
        require(state == State.Active, "not active");
        require(msg.sender == buyer || msg.sender == seller, "not party");

        if (arbitratorFee > 0) {
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), arbitratorFee);
            require(token.balanceOf(address(this)) - before == arbitratorFee, "fee short");
            arbitratorFeePot = arbitratorFee;
        }
        disputeOpener = msg.sender;
        disputeOpenedAt = block.timestamp;
        autoReleaseDeadline = type(uint256).max; // freeze auto-release
        _setState(State.Disputed);
        if (dealAmount >= HIGH_VALUE_THRESHOLD) {
            // C-2: high-value deals go straight to a court-drawn 3-panel (no single arbitrator).
            arbPhase = ArbPhase.Panel;
            IAppeal(ARBITRATOR_REGISTRY.court()).prepareFirstPanel(address(this), address(0));
        } else {
            // v5 D1: the arbitrator is drawn at random from a FUTURE blockhash (drawArbitrator).
            arbPhase = ArbPhase.Drawing;
            drawBlock = block.number + DRAW_DELAY;
        }
        emit DisputeOpened(msg.sender);
    }

    /// @notice v5 D1: seat a random eligible arbitrator. Permissionless (the keeper, either party, anyone); the
    ///         seed is blockhash(drawBlock), fixed and unknowable when the dispute opened. If nobody calls within
    ///         DRAW_HORIZON blocks the draw re-arms on a new future block, at most MAX_REARMS times; after that the
    ///         deal is Exhausted (R2): suppressing every caller can at best force the stalemate split, never pick
    ///         an arbitrator. The SLA clock starts at the draw.
    function drawArbitrator() external nonReentrant {
        require(state == State.Disputed && arbPhase == ArbPhase.Drawing, "not drawing");
        require(block.number > drawBlock, "too early");
        if (block.number - drawBlock > DRAW_HORIZON) {
            if (rearms >= MAX_REARMS) {
                arbPhase = ArbPhase.Exhausted;
                emit DrawExhausted();
                return;
            }
            rearms++;
            drawBlock = block.number + DRAW_DELAY;
            emit DrawRearmed(drawBlock);
            return;
        }
        address arb = ARBITRATOR_REGISTRY.drawEligible(
            keccak256(abi.encode(address(this), blockhash(drawBlock))), dealAmount, buyer, seller, createdAtBlock
        );
        require(arb != address(0), "no eligible arb");
        arbitrator = arb;
        arbPhase = ArbPhase.Seated;
        _accrueTip(msg.sender);
        ARBITRATOR_REGISTRY.onDisputeOpened(arb, disputeOpener); // SLA anchor = now
        emit ArbitratorDrawn(arb);
    }

    /// @notice Arbitrator's ruling — single-arb deals below the panel threshold
    ///         only. Does NOT pay out (F9: the Phase-A immediate-payout note was
    ///         stale): it records the split and parks the deal in
    ///         RuledPendingAppeal for APPEAL_WINDOW. Funds move at finalize()
    ///         (window passed, no appeal) or at the court's settleAppealUphold /
    ///         settleAppealOverturn if a party appeals.
    function rule(uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash) external nonReentrant {
        require(state == State.Disputed, "not disputed");
        require(arbPhase == ArbPhase.Seated && msg.sender == arbitrator, "not arbitrator");
        require(buyerAmount + sellerAmount == dealAmount, "sum != dealAmount");
        // F1 (v5): the case stays OPEN in the registry (openCases) through the appeal window, so the arbitrator
        // can't complete a withdrawal before an overturn slash could land; it resolves at finalize/settle.
        _setState(State.RuledPendingAppeal);
        _recordRuling(buyerAmount, sellerAmount, rationaleHash);
    }

    function _recordRuling(uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash) internal {
        rulingBuyerAmount = buyerAmount;
        rulingSellerAmount = sellerAmount;
        rulingRationale = rationaleHash;
        rulingStage = 0;
        appealDeadline = block.timestamp + APPEAL_WINDOW;
    }

    function applyFirstRuling(
        address p0, address p1, address p2, uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash
    ) external nonReentrant {
        require(msg.sender == ARBITRATOR_REGISTRY.court(), "not court");
        require(state == State.Disputed, "not disputed");
        require(buyerAmount + sellerAmount == dealAmount, "sum != dealAmount");
        // F10 (v5): a Panel-phase deal never carries a registry assignment (high-value deals never seat one;
        // escalated deals' arbitrator was cleared by the SLA slash), so there is nothing to resolve here.
        _setState(State.RuledPendingAppeal);
        _recordRuling(buyerAmount, sellerAmount, rationaleHash);
        uint256 pot = arbitratorFeePot;
        if (pot > 0) {
            arbitratorFeePot = 0;
            uint256 third = pot / 3;
            _payOrOwe(p0, third + (pot - third * 3));
            _payOrOwe(p1, third);
            _payOrOwe(p2, third);
            emit ArbitratorFeeSettled(p0, pot, true);
        }
    }

    function appeal() external nonReentrant {
        require(state == State.RuledPendingAppeal, "not ruled-pending");
        // High-value first-ruling PANEL decisions are FINAL (C-2, revised): a
        // 3-panel is already the strongest first ruling; there is no appeal-of-
        // panel. Only single-arbitrator rulings (dealAmount < threshold) are
        // appealable — once — to a fresh panel.
        require(dealAmount < HIGH_VALUE_THRESHOLD, "panel final");
        require(rulingStage == 0, "already appealed");
        require(!appealed, "appealed");
        require(msg.sender == buyer || msg.sender == seller, "not party");
        require(block.timestamp <= appealDeadline, "appeal closed");
        uint256 bond = (dealAmount * APPEAL_BOND_BPS) / 10000;
        address c = ARBITRATOR_REGISTRY.court();
        token.safeTransferFrom(msg.sender, c, bond);
        // Pass the ruling being challenged so the court can detect uphold vs
        // overturn (B1 fix — court needs origBuyer/origSeller).
        IAppeal(c).onAppeal(address(this), arbitrator, msg.sender, bond, rulingBuyerAmount, rulingSellerAmount);
        appealed = true;
        rulingStage = 1;
        appealDeadline = block.timestamp + APPEAL_WINDOW;
    }

    function finalize() external nonReentrant {
        require(state == State.RuledPendingAppeal, "not ruled-pending");
        require(!appealed, "appealed");
        require(block.timestamp > appealDeadline, "too early");
        address potTo = _openerWon(rulingBuyerAmount, rulingSellerAmount) ? disputeOpener : arbitrator;
        _accrueTip(msg.sender); // D4: before the fee is paid out
        _settleRuling(rulingBuyerAmount, rulingSellerAmount, potTo);
        ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this)); // F1: the case closes only now
    }

    function settleAppealUphold() external nonReentrant {
        require(msg.sender == ARBITRATOR_REGISTRY.court(), "not court");
        require(state == State.RuledPendingAppeal && appealed, "not appealable");
        address potTo = _openerWon(rulingBuyerAmount, rulingSellerAmount) ? disputeOpener : arbitrator;
        _settleRuling(rulingBuyerAmount, rulingSellerAmount, potTo);
        ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this)); // F1
    }

    function settleAppealOverturn(uint256 buyerAmount, uint256 sellerAmount) external nonReentrant {
        require(msg.sender == ARBITRATOR_REGISTRY.court(), "not court");
        require(state == State.RuledPendingAppeal && appealed, "not appealable");
        require(buyerAmount + sellerAmount == dealAmount, "sum != dealAmount");
        _settleRuling(buyerAmount, sellerAmount, disputeOpener);
        ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this)); // F1
    }

    function _settleRuling(uint256 buyerAmount, uint256 sellerAmount, address potTo) internal {
        uint256 fee = (dealAmount * platformFeeBps) / 10000;
        uint256 remaining = dealAmount - fee;
        uint256 finalBuyer = (buyerAmount * remaining) / dealAmount;
        uint256 finalSeller = remaining - finalBuyer;
        _setState(State.Completed);
        if (arbitratorFeePot > 0 && potTo != address(0)) {
            uint256 pot = arbitratorFeePot;
            arbitratorFeePot = 0;
            _payOrOwe(potTo, pot);
            emit ArbitratorFeeSettled(potTo, pot, potTo == disputeOpener);
        }
        if (finalBuyer > 0) _payDeal(buyer, finalBuyer);
        if (finalSeller > 0) _payDeal(seller, finalSeller);
        _payFee(fee);
        emit Split(finalBuyer, finalSeller, fee, true);
        emit Ruled(buyerAmount, sellerAmount, fee, rulingRationale);
    }

    function _openerWon(uint256 buyerAmount, uint256 sellerAmount) internal view returns (bool) {
        return (disputeOpener == buyer && buyerAmount >= sellerAmount)
            || (disputeOpener == seller && sellerAmount >= buyerAmount);
    }


    /// @notice Permissionless SLA-timeout slash: if the current arbitrator
    ///         hasn't ruled SLA_DURATION after being assigned this dispute,
    ///         anyone can call this to (registry) slash SLA_SLASH_BPS of their
    ///         stake to the dispute opener and clear the arbitrator. A late
    ///         rule() becomes impossible (arbitrator is cleared). Idempotent:
    ///         the registry reverts if already slashed/resolved. Panel-required
    ///         deals have no assignment (F1) so there is nothing to slash. The
    ///         fee pot is RETAINED (F5): the opener is compensated by the slash
    ///         proceeds; the pot pays the escalation panel, and the 30-day
    ///         claimStrandedPot valve returns it if no panel ever seats.
    function slashForTimeout() external nonReentrant {
        require(state == State.Disputed && arbPhase == ArbPhase.Seated, "no seated arb"); // F1 / R1
        address cleared = arbitrator;
        uint256 slashedAmt = ARBITRATOR_REGISTRY.slashTimeoutStake(address(this));
        timeoutSlashedArb = cleared;
        timeoutSlashedAt = block.timestamp;
        arbitrator = address(0);
        arbPhase = ArbPhase.Slashed;
        _accrueTip(msg.sender); // D4
        emit ArbitratorSlashed(cleared, slashedAmt);
    }

    /// @notice G2: re-arm a dismissed high-value first panel. The court's
    ///         dismiss clears only the COURT case; without a re-request path a
    ///         pool-too-small dismissal left the deal a permanent dead end
    ///         (openDispute needs Active). Either party may re-request; the
    ///         court rejects it while a case is still in flight.
    function requestFirstPanel() external nonReentrant {
        require(state == State.Disputed && arbPhase == ArbPhase.Panel, "not panel deal");
        require(block.timestamp < disputeOpenedAt + NO_ARB_TIMEOUT, "use stalemateSplit"); // R8
        require(msg.sender == buyer || msg.sender == seller, "not party");
        IAppeal(ARBITRATOR_REGISTRY.court()).prepareFirstPanel(address(this), timeoutSlashedArb);
    }

    /// @notice F5: after a timeout slash cleared the arbitrator, either party
    ///         ALONE can escalate to a court-drawn panel — recovery must never
    ///         require the non-cooperative party's signature (that failed
    ///         liveness assumption is what slashForTimeout just punished). The
    ///         slashed arb is excluded from the draw; the retained fee pot pays
    ///         the panel via applyFirstRuling's third-split.
    function escalateAfterTimeout() external nonReentrant {
        require(state == State.Disputed && arbPhase == ArbPhase.Slashed, "not slashed"); // R1
        require(msg.sender == buyer || msg.sender == seller, "not party");
        arbPhase = ArbPhase.Panel;
        IAppeal(ARBITRATOR_REGISTRY.court()).prepareFirstPanel(address(this), timeoutSlashedArb);
    }

    /// @notice F5 valve: if no panel materialized STRANDED_POT_DELAY after a
    ///         timeout slash (and no court case is in flight), the opener
    ///         reclaims the fee pot they prepaid.
    function claimStrandedPot() external nonReentrant {
        require(state == State.Disputed && arbPhase == ArbPhase.Slashed && timeoutSlashedAt != 0, "not stranded"); // R1
        require(msg.sender == disputeOpener, "not opener");
        require(block.timestamp >= timeoutSlashedAt + STRANDED_POT_DELAY, "too early");
        require(!IAppeal(ARBITRATOR_REGISTRY.court()).isCaseActive(address(this)), "case in flight");
        uint256 pot = arbitratorFeePot;
        require(pot > 0, "no pot");
        arbitratorFeePot = 0;
        _payOrOwe(disputeOpener, pot);
        emit ArbitratorFeeSettled(disputeOpener, pot, true);
    }

    /// @notice v5 E1/R8: nobody was ever able to decide this dispute (no arbitrator could be drawn, the draw was
    ///         exhausted, the seated one was slashed, or no court panel could seat) for NO_ARB_TIMEOUT: either
    ///         party may split the deal 50/50, fee-free; the fee pot goes back to the opener. Keeper tips already
    ///         earned are funded from the deal (there is no platform fee to take them from). Funds can never
    ///         be stuck.
    function stalemateSplit() external nonReentrant {
        require(state == State.Disputed, "not disputed");
        require(msg.sender == buyer || msg.sender == seller, "not party");
        require(block.timestamp >= disputeOpenedAt + NO_ARB_TIMEOUT, "too early");
        ArbPhase ph = arbPhase;
        require(
            ph == ArbPhase.Drawing || ph == ArbPhase.Exhausted
                || ((ph == ArbPhase.Panel || ph == ArbPhase.Slashed)
                    && !IAppeal(ARBITRATOR_REGISTRY.court()).isCaseActive(address(this))),
            "decidable"
        );
        _setState(State.Completed);
        _settleFeePotToOpener();
        uint256 net = dealAmount - tipsTotal;
        uint256 toBuyer = net / 2;
        _payDeal(buyer, toBuyer);
        _payDeal(seller, net - toBuyer);
        emit StalemateSplit(toBuyer, net - toBuyer);
    }

    /// @notice v5 D4: the court credits the tip for a successful drawPanel / dismiss on this deal. Only while the
    ///         deal is still open (so the tip is funded by the fee at settlement); a no-op afterwards.
    function creditKeeperTip(address keeper) external {
        require(msg.sender == ARBITRATOR_REGISTRY.court(), "not court");
        if (state == State.Disputed || state == State.RuledPendingAppeal) _accrueTip(keeper);
    }

    /// @notice Collect keeper tips once the deal has settled.
    function claimTip() external nonReentrant {
        require(state == State.Completed || state == State.Cancelled, "not settled");
        uint256 amount = tipOwed[msg.sender];
        require(amount > 0, "no tip");
        tipOwed[msg.sender] = 0;
        deposited -= amount;
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice F3: collect a payout that couldn't be pushed (e.g. while the address was on a token blocklist).
    ///         Settlement never depends on the recipient; this claim does (a still-blocked recipient waits).
    function withdrawOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing owed");
        owed[msg.sender] = 0;
        owedTotal -= amount;
        token.safeTransfer(msg.sender, amount);
        emit OwedWithdrawn(msg.sender, amount);
    }

    // ─── Permissionless timeouts ─────────────────────────────────────────────

    function expire() external nonReentrant {
        require(state == State.Created || state == State.PartiallyDeposited, "bad state");
        require(block.timestamp > depositDeadline, "too early");

        // F2 (v5): no push here — a blocklisted buyer must not be able to brick expiry. Depositors pull with
        // claimExpired().
        _setState(State.Expired);
        emit Expired(deposited);
    }

    function claimExpired() external nonReentrant {
        require(state == State.Expired, "not expired");
        uint256 amount = depositedBy[msg.sender];
        require(amount > 0, "nothing to claim");

        depositedBy[msg.sender] = 0;
        deposited -= amount;
        token.safeTransfer(msg.sender, amount);
        emit ExpiredClaimed(msg.sender, amount);
    }

    function autoRelease() external nonReentrant {
        require(state == State.Active, "not active");
        require(block.timestamp >= autoReleaseDeadline, "too early");

        _accrueTip(msg.sender); // D4
        (uint256 toSeller, uint256 fee) = _split(dealAmount);
        _setState(State.Completed);
        _payDeal(seller, toSeller);
        _payFee(fee);
        emit Released(seller, toSeller, fee);
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    function _split(uint256 amount) internal view returns (uint256 net, uint256 fee) {
        fee = (amount * platformFeeBps) / 10_000;
        net = amount - fee;
    }

    function _paySplit(uint256 buyerAmount, bool byArbitrator) internal returns (uint256 fee) {
        fee = (dealAmount * platformFeeBps) / 10_000;
        uint256 remaining = dealAmount - fee;
        uint256 finalBuyer = (buyerAmount * remaining) / dealAmount;
        uint256 finalSeller = remaining - finalBuyer; // absorbs rounding dust

        if (finalBuyer > 0) _payDeal(buyer, finalBuyer);
        if (finalSeller > 0) _payDeal(seller, finalSeller);
        _payFee(fee);
        emit Split(finalBuyer, finalSeller, fee, byArbitrator);
    }

    function _settleFeePotToOpener() internal {
        if (arbitratorFeePot > 0) {
            uint256 pot = arbitratorFeePot;
            arbitratorFeePot = 0;
            _payOrOwe(disputeOpener, pot);
            emit ArbitratorFeeSettled(disputeOpener, pot, true);
        }
    }

    /// @dev The platform fee net of keeper tips (tips stay in `deposited` until claimTip; total tips <= fee).
    function _payFee(uint256 fee) internal {
        if (fee > tipsTotal) _payDeal(feeRecipient, fee - tipsTotal);
    }

    /// @dev D4: credit a keeper tip, capped so all tips together never exceed this deal's platform fee.
    function _accrueTip(address keeper) internal {
        uint256 cap = (dealAmount * platformFeeBps) / 10_000;
        if (keeper == address(0) || tipsTotal >= cap) return;
        uint256 t = (dealAmount * TIP_BPS) / 10_000;
        if (t < MIN_TIP) t = MIN_TIP;
        if (t > cap - tipsTotal) t = cap - tipsTotal;
        tipOwed[keeper] += t;
        tipsTotal += t;
        emit KeeperTip(keeper, t);
    }

    /// @dev F3: a recipient's blocklist must never revert a settlement; park the amount for withdrawOwed().
    function _payOrOwe(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!token.trySafeTransfer(to, amount)) {
            owed[to] += amount;
            owedTotal += amount;
            emit OwedCredited(to, amount);
        }
    }

    function _setState(State newState) internal {
        emit StateChanged(state, newState);
        state = newState;
    }

    /// @dev Pays out of deal funds only. `depositedBy` is scoped to
    ///      non-terminal states (see v1.1 invariant INV-3).
    function _payDeal(address to, uint256 amount) internal {
        if (amount == 0) return;
        deposited -= amount;
        _payOrOwe(to, amount);
    }

    function _consumeMutual(bytes32 structHash, uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig)
        internal
    {
        require(block.timestamp <= deadline, "sigs expired");
        bytes32 digest = _hashTypedDataV4(structHash);
        require(digest.recover(buyerSig) == buyer, "bad buyer sig");
        require(digest.recover(sellerSig) == seller, "bad seller sig");
        unchecked {
            ++nonce;
        }
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    function timeUntilDepositDeadline() external view returns (uint256) {
        return block.timestamp >= depositDeadline ? 0 : depositDeadline - block.timestamp;
    }

    function timeUntilAutoRelease() external view returns (uint256) {
        if (state != State.Active || block.timestamp >= autoReleaseDeadline) return 0;
        return autoReleaseDeadline - block.timestamp;
    }
}
