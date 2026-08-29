// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title GhostEscrow (reference v1.1)
 * @notice Immutable, single-deal escrow. The chain is the source of truth:
 *         state only advances through deposits, signed mutual actions, an
 *         arbitrator ruling, or permissionless timeouts. No admin keys exist.
 *
 * @dev Changes vs v1 (see REVIEW-2026-08-19.md in the bundle root):
 *      - Every mutual-action signature now carries a `deadline`; stale
 *        signatures are unusable (was: valid forever until a nonce bump).
 *      - Mutual release / refund / split are allowed from Disputed, so
 *        parties who reconcile mid-dispute can settle without the
 *        arbitrator; the pre-paid arbitrator fee returns to the opener.
 *        This is also the practical mitigation for a lazy arbitrator: no
 *        on-chain ruling SLA exists (a "ruling due" clock is UI-only), so
 *        the exits from a stalled dispute are mutual settlement or mutual
 *        arbitrator replacement.
 *      - New mutualSplit(): cooperative custom split (backs the
 *        "cancel & custom-split" mutual action in the UI, which v1 could
 *        only do through the arbitrator).
 *      - Deposits are credited by balance delta (fee-on-transfer safe) and
 *        tracked per depositor; expiry refunds go to whoever actually paid
 *        (was: everything to the buyer).
 *      - syncDeposit() credits tokens transferred directly to this address
 *        (e.g. a Monero->USDC swap into the CREATE2-predicted address),
 *        attributed to the buyer. In v1 such funds were permanently stuck.
 *      - rescueToken() may recover deal-token dust once the deal is fully
 *        settled (was: deal token excluded forever).
 *      - autoReleaseDelay is a per-deal constructor param (bounded 1-90
 *        days) instead of a hardcoded 14 days, making the buyer-unfavorable
 *        "silence pays the seller" default an explicit per-deal choice.
 *
 *      Deployment / immutability model
 *      ---------------------------------
 *      EIP-1167 minimal proxies CANNOT carry per-deal `immutable`s (immutables
 *      live in the implementation bytecode that all clones share). Two ways to
 *      keep per-deal params truly immutable AND cheap to deploy:
 *        (a) Factory deploys full contracts with `new GhostEscrow{salt:..}(...)`
 *            — real immutables, higher gas. (What this file assumes.)
 *        (b) clones-with-immutable-args (Solady `LibClone.clone(impl, argsData)`)
 *            — cheap proxy that appends the params to its own code; read them
 *            back in an `initialize()`-free way. Preferred at scale.
 *      Either way there is no proxy-admin, owner, pause, or upgrade path.
 *
 *      OZ EIP712 is clone-safe: it rebuilds the domain separator whenever
 *      address(this) != the cached deploy address, so the verifyingContract is
 *      always this deal's own address.
 */
contract GhostEscrow is ReentrancyGuard, EIP712 {
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
        Expired
    }

    // ─── Immutable deal parameters ───────────────────────────────────────────

    IERC20 public immutable token;
    address public immutable buyer;
    address public immutable seller;
    address public immutable feeRecipient;
    uint256 public immutable dealAmount; // exact amount required to go Active
    uint256 public immutable platformFeeBps; // e.g. 150 = 1.5%
    uint256 public immutable arbitratorFee; // fixed; pre-paid by the dispute opener
    uint256 public immutable depositDeadline; // creation + depositTimeout (e.g. 72h)
    uint256 public immutable autoReleaseDelay; // per-deal, bounded below

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

    /// @dev Who paid what, so expiry refunds go to the actual depositor.
    ///      Direct (synced) transfers are attributed to the buyer.
    mapping(address => uint256) public depositedBy;

    // ─── EIP-712 typehashes (verifyingContract = this deal, so no dealId needed) ─
    // Every mutual action is bound to the current nonce AND a deadline: a
    // signature a counterparty sat on cannot be sprung later.

    bytes32 private constant RELEASE_TYPEHASH = keccak256("Release(uint256 nonce,uint256 deadline)");
    bytes32 private constant REFUND_TYPEHASH = keccak256("Refund(uint256 nonce,uint256 deadline)");
    bytes32 private constant SPLIT_TYPEHASH = keccak256("Split(uint256 buyerAmount,uint256 nonce,uint256 deadline)");
    bytes32 private constant REPLACE_ARB_TYPEHASH =
        keccak256("ReplaceArbitrator(address newArbitrator,uint256 nonce,uint256 deadline)");
    bytes32 private constant RESCUE_TYPEHASH =
        keccak256("RescueToken(address token,address to,uint256 nonce,uint256 deadline)");

    // ─── Events ──────────────────────────────────────────────────────────────

    event Deposited(address indexed from, uint256 amount, uint256 total);
    event ExcessRefunded(address indexed to, uint256 amount);
    event StateChanged(State previous, State current);
    event DisputeOpened(address indexed opener);
    event Released(address indexed to, uint256 amount, uint256 platformFee);
    event Refunded(address indexed to, uint256 amount, uint256 platformFee);
    event Split(uint256 buyerAmount, uint256 sellerAmount, uint256 platformFee, bool byArbitrator);
    event Ruled(uint256 buyerAmount, uint256 sellerAmount, uint256 platformFee, bytes32 rationaleHash);
    event ArbitratorReplaced(address indexed oldArb, address indexed newArb);
    event ArbitratorFeeSettled(address indexed to, uint256 amount, bool openerWon);
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
        uint256 _autoReleaseDelay
    ) EIP712("GhostEscrow", "1") {
        require(_token != address(0) && _buyer != address(0) && _seller != address(0), "zero addr");
        require(_arbitrator != address(0) && _feeRecipient != address(0), "zero addr");
        require(_buyer != _seller, "same party");
        require(_arbitrator != _buyer && _arbitrator != _seller, "bad arb");
        require(_dealAmount > 0, "zero amount");
        require(_platformFeeBps <= 1000, "fee too high"); // hard cap 10%
        require(_autoReleaseDelay >= MIN_AUTO_RELEASE && _autoReleaseDelay <= MAX_AUTO_RELEASE, "bad auto-release");
        require(_depositTimeout >= MIN_DEPOSIT_TIMEOUT && _depositTimeout <= MAX_DEPOSIT_TIMEOUT, "bad deposit timeout");

        token = IERC20(_token);
        buyer = _buyer;
        seller = _seller;
        arbitrator = _arbitrator;
        feeRecipient = _feeRecipient;
        dealAmount = _dealAmount;
        platformFeeBps = _platformFeeBps;
        arbitratorFee = _arbitratorFee;
        depositDeadline = block.timestamp + _depositTimeout;
        autoReleaseDelay = _autoReleaseDelay;

        state = State.Created;
    }

    // ─── Deposit ─────────────────────────────────────────────────────────────

    /// @notice Deposit deal funds. Credits the balance actually received (so a
    ///         fee-on-transfer token cannot desync accounting). Reaching
    ///         dealAmount flips to Active; any overshoot is refunded in-tx.
    function deposit(uint256 amount) external nonReentrant {
        require(state == State.Created || state == State.PartiallyDeposited, "bad state");
        require(block.timestamp <= depositDeadline, "deposit window closed");
        require(amount > 0, "zero");

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 credited = token.balanceOf(address(this)) - before;
        require(credited > 0, "zero credited");

        _credit(msg.sender, credited);
    }

    /// @notice Credit deal tokens transferred directly to this address — e.g. a
    ///         Monero->USDC swap paid into the CREATE2-predicted address before
    ///         or after deploy. Attributed to the buyer. Permissionless.
    function syncDeposit() external nonReentrant {
        require(state == State.Created || state == State.PartiallyDeposited, "bad state");
        require(block.timestamp <= depositDeadline, "deposit window closed");

        // No arbitrator fee pot can exist pre-Active, so any balance above
        // `deposited` is an uncredited direct transfer.
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
                // excess <= credited, so the depositor's tally covers it
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

    // ─── Mutual actions (both signatures, EIP-712, nonce + deadline) ─────────
    // Allowed from Active AND Disputed: two parties who reconcile mid-dispute
    // settle without the arbitrator; the fee pot returns to the opener (no
    // ruling was rendered).

    function release(uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig) external nonReentrant {
        require(state == State.Active || state == State.Disputed, "bad state");
        _consumeMutual(keccak256(abi.encode(RELEASE_TYPEHASH, nonce, deadline)), deadline, buyerSig, sellerSig);

        (uint256 toSeller, uint256 fee) = _split(dealAmount);
        _setState(State.Completed); // CEI: state first, external calls after
        _settleFeePotToOpener();
        _payDeal(seller, toSeller);
        _payDeal(feeRecipient, fee);
        emit Released(seller, toSeller, fee);
    }

    /// @dev Note (product decision, on record): a mutual refund still pays the
    ///      platform fee, while a deposit-window expiry is fee-free.
    function refund(uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig) external nonReentrant {
        require(state == State.Active || state == State.Disputed, "bad state");
        _consumeMutual(keccak256(abi.encode(REFUND_TYPEHASH, nonce, deadline)), deadline, buyerSig, sellerSig);

        (uint256 toBuyer, uint256 fee) = _split(dealAmount);
        _setState(State.Cancelled); // CEI: state first, external calls after
        _settleFeePotToOpener();
        _payDeal(buyer, toBuyer);
        _payDeal(feeRecipient, fee);
        emit Refunded(buyer, toBuyer, fee);
    }

    /// @notice Cooperative custom split ("cancel & custom-split" in the UI):
    ///         both parties sign a buyerAmount (pre-fee, out of dealAmount);
    ///         fee comes off the top, remainder splits in the signed ratio.
    function mutualSplit(uint256 buyerAmount, uint256 deadline, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        nonReentrant
    {
        require(state == State.Active || state == State.Disputed, "bad state");
        require(buyerAmount <= dealAmount, "over amount");
        _consumeMutual(
            keccak256(abi.encode(SPLIT_TYPEHASH, buyerAmount, nonce, deadline)), deadline, buyerSig, sellerSig
        );

        _setState(State.Completed); // CEI: state first, external calls after
        _settleFeePotToOpener();
        _paySplit(buyerAmount, false);
    }

    /// @notice Replace the arbitrator by mutual agreement (e.g. unresponsive).
    function replaceArbitrator(
        address newArbitrator,
        uint256 deadline,
        bytes calldata buyerSig,
        bytes calldata sellerSig
    ) external nonReentrant {
        require(state == State.Active || state == State.Disputed, "bad state");
        require(newArbitrator != address(0) && newArbitrator != buyer && newArbitrator != seller, "bad arb");
        _consumeMutual(
            keccak256(abi.encode(REPLACE_ARB_TYPEHASH, newArbitrator, nonce, deadline)), deadline, buyerSig, sellerSig
        );

        address old = arbitrator;
        arbitrator = newArbitrator;
        emit ArbitratorReplaced(old, newArbitrator);
    }

    /// @notice Mutually rescue a stray token to a party. The deal token itself
    ///         is rescuable only once the deal is fully settled (all deal funds
    ///         and any fee pot paid out), so post-settlement dust isn't locked
    ///         forever but live deal funds can never be siphoned.
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

        // Pre-deposit the arbitrator fee into a SEPARATE pot (never mixed with deal funds).
        if (arbitratorFee > 0) {
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), arbitratorFee);
            require(token.balanceOf(address(this)) - before == arbitratorFee, "fee short");
            arbitratorFeePot = arbitratorFee;
        }
        disputeOpener = msg.sender;
        autoReleaseDeadline = type(uint256).max; // freeze auto-release
        _setState(State.Disputed);
        emit DisputeOpened(msg.sender);
    }

    /**
     * @notice Arbitrator's final ruling: split the pot as buyerAmount/sellerAmount
     *         (must sum to dealAmount, pre-fee). Platform fee is taken from the pot,
     *         then the remainder is split in the ruled ratio.
     * @dev There is deliberately NO on-chain ruling deadline: a "ruling due"
     *      clock is a UI/reputation construct. If the arbitrator stalls, the
     *      parties' exits are mutual settlement (release/refund/mutualSplit
     *      from Disputed) or mutual replacement — both require the two parties
     *      to cooperate; no code can adjudicate for them.
     * @param rationaleHash keccak256 of the off-chain written rationale (audit trail).
     */
    function rule(uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash) external nonReentrant {
        require(msg.sender == arbitrator, "not arbitrator");
        require(state == State.Disputed, "not disputed");
        require(buyerAmount + sellerAmount == dealAmount, "sum != dealAmount");

        _setState(State.Completed);

        // Settle the arbitrator-fee pot: opener gets it back if they won, else it
        // pays the arbitrator. A tie (equal split) counts as an opener win —
        // surface that in the UI.
        if (arbitratorFeePot > 0) {
            bool openerWon = (disputeOpener == buyer && buyerAmount >= sellerAmount)
                || (disputeOpener == seller && sellerAmount >= buyerAmount);
            address feeTo = openerWon ? disputeOpener : arbitrator;
            uint256 pot = arbitratorFeePot;
            arbitratorFeePot = 0;
            token.safeTransfer(feeTo, pot);
            emit ArbitratorFeeSettled(feeTo, pot, openerWon);
        }

        uint256 fee = _paySplit(buyerAmount, true);
        emit Ruled(buyerAmount, sellerAmount, fee, rationaleHash);
    }

    // ─── Permissionless timeouts ─────────────────────────────────────────────

    /// @notice After the deposit window, close the deal — no platform fee. The
    ///         buyer's own funds are pushed back immediately; any other
    ///         depositor reclaims theirs via claimExpired() (refunds go to
    ///         whoever actually paid, not blanket to the buyer).
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

    /// @notice Reclaim your deposit from an expired deal.
    function claimExpired() external nonReentrant {
        require(state == State.Expired, "not expired");
        uint256 amount = depositedBy[msg.sender];
        require(amount > 0, "nothing to claim");

        depositedBy[msg.sender] = 0;
        deposited -= amount;
        token.safeTransfer(msg.sender, amount);
        emit ExpiredClaimed(msg.sender, amount);
    }

    /// @notice After autoReleaseDelay with no action or dispute, funds go to the
    ///         seller. Direction is a per-deal, surfaced product choice: silence
    ///         is treated as acceptance of delivery; the buyer's protection is
    ///         the dispute button and the countdown shown in the deal room.
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

    /// @dev Fee off the top, remainder split pro-rata to a pre-fee buyerAmount.
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

    /// @dev On a mutual settlement out of Disputed no ruling was rendered, so
    ///      the pre-paid arbitrator fee goes back to whoever fronted it.
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

/// @dev Pays out of deal funds only. `depositedBy` is scoped to non-terminal
///      states: it records who put money in, and is only ever read by the
///      deposit-window expiry paths (expire/claimExpired), which are
///      unreachable once the deal leaves Created/PartiallyDeposited. Payout
///      recipients (seller/feeRecipient/dispute parties) are not depositors,
///      so payouts intentionally do not mutate `depositedBy` — a mapping
///      nothing reads post-terminal. Sum(depositedBy) == deposited holds only
///      in non-terminal states (see StatefulInvariant INV-3).
    function _payDeal(address to, uint256 amount) internal {
        if (amount == 0) return;
        deposited -= amount;
        token.safeTransfer(to, amount);
    }

    /// @dev Verifies the deadline, then buyer AND seller EIP-712 signatures over
    ///      `structHash`, then burns the nonce so the same pair of signatures
    ///      can't be replayed.
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
