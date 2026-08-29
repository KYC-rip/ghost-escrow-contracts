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
}

/**
 * @title GhostEscrowV2 — Arbitrator Model v2 template (Phase A)
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
contract GhostEscrowV2Open is ReentrancyGuard, EIP712 {
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

    // ─── Immutable deal parameters ───────────────────────────────────────────

    ArbitratorRegistry public immutable ARBITRATOR_REGISTRY; // view-only, STATICCALL
    IERC20 public immutable token;
    // Open variant: exactly ONE of buyer/seller is set at deploy (the creator);
    // the other is address(0) until a claimant join()s it, set-once. Both are
    // storage (not immutable) because the open slot is written post-deploy.
    address public buyer;
    address public seller;
    address public immutable creator; // the party fixed at deploy
    bool public immutable creatorIsBuyer; // true => open slot is the seller
    bool public joined; // set true when the open slot is filled; gates all value paths
    address public immutable feeRecipient;
    uint256 public immutable dealAmount; // exact amount required to go Active
    uint256 public immutable platformFeeBps; // e.g. 150 = 1.5%
    uint256 public immutable arbitratorFee; // fixed; pre-paid by the dispute opener
    uint256 public immutable depositDeadline; // creation + depositTimeout (e.g. 72h)
    uint256 public immutable autoReleaseDelay; // per-deal, bounded below

    /// Above this deal value a 3-panel is REQUIRED at first ruling (C-2).
    uint256 public constant HIGH_VALUE_THRESHOLD = 25_000e6;
    uint256 public constant APPEAL_WINDOW = 48 hours;
    uint256 public constant APPEAL_BOND_BPS = 2000;
    uint256 public constant MIN_AUTO_RELEASE = 1 days;
    uint256 public constant MAX_AUTO_RELEASE = 90 days;
    uint256 public constant MIN_DEPOSIT_TIMEOUT = 1 hours;
    uint256 public constant MAX_DEPOSIT_TIMEOUT = 30 days;

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

    /// @dev Who paid what, so expiry refunds go to the actual depositor.
    mapping(address => uint256) public depositedBy;

    // ─── EIP-712 typehashes (verifyingContract = this deal) ─────────────────
    // Identical to v1.1 so the client signing libs work unchanged for v2 deals.

    bytes32 private constant RELEASE_TYPEHASH = keccak256("Release(uint256 nonce,uint256 deadline)");
    bytes32 private constant REFUND_TYPEHASH = keccak256("Refund(uint256 nonce,uint256 deadline)");
    bytes32 private constant SPLIT_TYPEHASH = keccak256("Split(uint256 buyerAmount,uint256 nonce,uint256 deadline)");
    bytes32 private constant REPLACE_ARB_TYPEHASH =
        keccak256("ReplaceArbitrator(address newArbitrator,uint256 nonce,uint256 deadline)");
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
    event ArbitratorReplaced(address indexed oldArb, address indexed newArb);
    event ArbitratorFeeSettled(address indexed to, uint256 amount, bool openerWon);
    event ArbitratorSlashed(address indexed arb, uint256 amount);
    event Expired(uint256 held);
    event ExpiredClaimed(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _token,
        address _buyer,
        address _seller,
        address _arbitrator,
        address _feeRecipient,
        uint256 _dealAmount,
        uint256 _platformFeeBps,
        uint256 _arbitratorFee,
        uint256 _depositTimeout,
        uint256 _autoReleaseDelay,
        ArbitratorRegistry _registry
    ) EIP712("GhostEscrow", "1") {
        require(_token != address(0) && _feeRecipient != address(0), "zero addr");
        require(_arbitrator != address(0), "zero addr");
        require(address(_registry) != address(0), "zero registry");
        // G1: EXACTLY ONE of buyer/seller is open (address(0)); the other is the
        // creator. Never both-zero, never neither. The open slot is filled once
        // via join(); the CREATE2 address encodes it as 0 so it's join-independent.
        require((_buyer == address(0)) != (_seller == address(0)), "one open slot");
        address _creator = _buyer == address(0) ? _seller : _buyer;
        require(_arbitrator != _creator, "bad arb");
        require(_dealAmount > 0, "zero amount");
        require(_platformFeeBps <= 1000, "fee too high"); // hard cap 10%
        require(_autoReleaseDelay >= MIN_AUTO_RELEASE && _autoReleaseDelay <= MAX_AUTO_RELEASE, "bad auto-release");
        require(_depositTimeout >= MIN_DEPOSIT_TIMEOUT && _depositTimeout <= MAX_DEPOSIT_TIMEOUT, "bad deposit timeout");

        ARBITRATOR_REGISTRY = _registry;
        token = IERC20(_token);
        buyer = _buyer;
        seller = _seller;
        creator = _creator;
        creatorIsBuyer = _buyer != address(0);
        arbitrator = _arbitrator;
        feeRecipient = _feeRecipient;
        dealAmount = _dealAmount;
        platformFeeBps = _platformFeeBps;
        arbitratorFee = _arbitratorFee;
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
    function join(uint256 deadline, address joiner, bytes calldata inviteSig) external {
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
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) token.safeTransfer(creator, bal);
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
        _payDeal(feeRecipient, fee);
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
        _payDeal(feeRecipient, fee);
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

    /// @notice Replace the arbitrator by mutual agreement. The NEW arbitrator
    ///         must be bonded and eligible for this deal's value (view-only
    ///         STATICCALL to the registry — see contract NatSpec). When the
    ///         deal is Disputed, the replacement also re-anchors the SLA clock:
    ///         the old arbitrator is resolved (openCases--) and the new one
    ///         assigned (openCases++ + fresh assignedAt) via the registry.
    function replaceArbitrator(
        address newArbitrator,
        uint256 deadline,
        bytes calldata buyerSig,
        bytes calldata sellerSig
    ) external nonReentrant {
        require(state == State.Active || state == State.Disputed, "bad state");
        bool fromDisputed = state == State.Disputed;
        require(newArbitrator != address(0) && newArbitrator != buyer && newArbitrator != seller, "bad arb");
        require(ARBITRATOR_REGISTRY.isEligible(newArbitrator, dealAmount), "arb not eligible");
        _consumeMutual(
            keccak256(abi.encode(REPLACE_ARB_TYPEHASH, newArbitrator, nonce, deadline)), deadline, buyerSig, sellerSig
        );

        address old = arbitrator;
        arbitrator = newArbitrator;
        if (fromDisputed) {
            ARBITRATOR_REGISTRY.onResolved(old, address(this));
            ARBITRATOR_REGISTRY.onAssigned(newArbitrator, address(this));
        }
        emit ArbitratorReplaced(old, newArbitrator);
    }

    function rescueToken(address stray, address to, uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        nonReentrant
    {
        if (stray == address(token)) {
            require(
                (state == State.Completed || state == State.Cancelled || state == State.Expired) && deposited == 0
                    && arbitratorFeePot == 0,
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
        autoReleaseDeadline = type(uint256).max; // freeze auto-release
        _setState(State.Disputed);
        ARBITRATOR_REGISTRY.onDisputeOpened(arbitrator, msg.sender); // CEI: after state
        if (dealAmount >= HIGH_VALUE_THRESHOLD) {
            IAppeal(ARBITRATOR_REGISTRY.court()).prepareFirstPanel(address(this), arbitrator); // C-2
        }
        emit DisputeOpened(msg.sender);
    }

    /// @notice Arbitrator's final ruling. Phase A pays out immediately (v1.1
    ///         semantics). The Phase B/C staged-ruling hold (RuledPendingAppeal)
    ///         will sit between rule() and final payout so an AppealCourt
    ///         overturn can re-settle; this template's rule() is unchanged so
    ///         nothing precludes that extension.
    function rule(uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash) external nonReentrant {
        require(state == State.Disputed, "not disputed");
        require(msg.sender == arbitrator, "not arbitrator");
        require(dealAmount < HIGH_VALUE_THRESHOLD, "panel required");
        require(buyerAmount + sellerAmount == dealAmount, "sum != dealAmount");
        // CEI: internal state first, external registry call last (C-REV-3).
        _setState(State.RuledPendingAppeal);
        _recordRuling(buyerAmount, sellerAmount, rationaleHash);
        ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this));
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
        // Clear the originally-assigned arbitrator's SLA case: a panel superseded
        // them, so they must NOT stay SLA-slashable for "not ruling" (Escrow-B fix).
        // CEI: registry bookkeeping + state effects BEFORE the external pot transfers.
        ARBITRATOR_REGISTRY.onResolved(arbitrator, address(this));
        _setState(State.RuledPendingAppeal);
        _recordRuling(buyerAmount, sellerAmount, rationaleHash);
        uint256 pot = arbitratorFeePot;
        if (pot > 0) {
            arbitratorFeePot = 0;
            uint256 third = pot / 3;
            token.safeTransfer(p0, third + (pot - third * 3));
            token.safeTransfer(p1, third);
            token.safeTransfer(p2, third);
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
        _settleRuling(rulingBuyerAmount, rulingSellerAmount, potTo);
    }

    function settleAppealUphold() external nonReentrant {
        require(msg.sender == ARBITRATOR_REGISTRY.court(), "not court");
        require(state == State.RuledPendingAppeal && appealed, "not appealable");
        address potTo = _openerWon(rulingBuyerAmount, rulingSellerAmount) ? disputeOpener : arbitrator;
        _settleRuling(rulingBuyerAmount, rulingSellerAmount, potTo);
    }

    function settleAppealOverturn(uint256 buyerAmount, uint256 sellerAmount) external nonReentrant {
        require(msg.sender == ARBITRATOR_REGISTRY.court(), "not court");
        require(state == State.RuledPendingAppeal && appealed, "not appealable");
        require(buyerAmount + sellerAmount == dealAmount, "sum != dealAmount");
        _settleRuling(buyerAmount, sellerAmount, disputeOpener);
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
            token.safeTransfer(potTo, pot);
            emit ArbitratorFeeSettled(potTo, pot, potTo == disputeOpener);
        }
        if (finalBuyer > 0) _payDeal(buyer, finalBuyer);
        if (finalSeller > 0) _payDeal(seller, finalSeller);
        if (fee > 0) _payDeal(feeRecipient, fee);
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
    ///         stake to the dispute opener, return the pre-paid fee pot to the
    ///         opener (the arb did nothing), and clear the arbitrator so the
    ///         parties can replaceArbitrator to an eligible one. A late rule()
    ///         becomes impossible (arbitrator is cleared). Idempotent: the
    ///         registry reverts if this deal was already slashed/resolved.
    function slashForTimeout() external nonReentrant {
        require(state == State.Disputed, "not disputed");
        address cleared = arbitrator;
        uint256 slashedAmt = ARBITRATOR_REGISTRY.slashTimeoutStake(address(this));
        if (arbitratorFeePot > 0) {
            uint256 pot = arbitratorFeePot;
            arbitratorFeePot = 0;
            token.safeTransfer(disputeOpener, pot);
            emit ArbitratorFeeSettled(disputeOpener, pot, true);
        }
        arbitrator = address(0);
        emit ArbitratorSlashed(cleared, slashedAmt);
    }

    // ─── Permissionless timeouts ─────────────────────────────────────────────

    function expire() external nonReentrant {
        require(state == State.Created || state == State.PartiallyDeposited, "bad state");
        require(block.timestamp > depositDeadline, "too early");

        _setState(State.Expired);
        emit Expired(deposited);

        uint256 own = depositedBy[buyer];
        if (own > 0) {
            depositedBy[buyer] = 0;
            deposited -= own;
            token.safeTransfer(buyer, own);
            emit ExpiredClaimed(buyer, own);
        }
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

        (uint256 toSeller, uint256 fee) = _split(dealAmount);
        _setState(State.Completed);
        _payDeal(seller, toSeller);
        _payDeal(feeRecipient, fee);
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
        if (fee > 0) _payDeal(feeRecipient, fee);
        emit Split(finalBuyer, finalSeller, fee, byArbitrator);
    }

    function _settleFeePotToOpener() internal {
        if (arbitratorFeePot > 0) {
            uint256 pot = arbitratorFeePot;
            arbitratorFeePot = 0;
            token.safeTransfer(disputeOpener, pot);
            emit ArbitratorFeeSettled(disputeOpener, pot, true);
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
        token.safeTransfer(to, amount);
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
