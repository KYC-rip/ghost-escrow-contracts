// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ArbitratorRegistry} from "./ArbitratorRegistry.sol";

/// @dev F8: the exact surface the court needs from ANY escrow template. Future
///      templates implement this instead of matching GhostEscrowV2's full ABI;
///      the compile-time coupling to one template is gone.
interface IEscrowCourtHooks {
    function buyer() external view returns (address);
    function seller() external view returns (address);
    function dealAmount() external view returns (uint256);
    function token() external view returns (address);
    function applyFirstRuling(
        address p0, address p1, address p2, uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash
    ) external;
    function settleAppealUphold() external;
    function settleAppealOverturn(uint256 buyerAmount, uint256 sellerAmount) external;
    /// v5 D4: credit the keeper tip to whoever made a successful drawPanel / dismiss call.
    function creditKeeperTip(address keeper) external;
}

/**
 * @title AppealCourt — Arbitrator Model v2 Phase C
 * @notice Ownerless, immutable, no admin, no drain. Hosts high-value first-
 *         ruling panels and appeal panels. Holds appeal bonds (and, transiently,
 *         overturn-slash proceeds) and distributes them only per the mechanism:
 *         - panel majority (2/3) upholds the ruling → appellant loses the bond
 *           (to the panel); original ruling stands.
 *         - panel majority overturns → the original arb/panel is slashed (via
 *           the registry, OVERTURN_SLASH_BPS), the escrow re-settles per the
 *           panel split, the appellant is made whole (bond + arb fee), and the
 *           slash remainder goes to the panel. Protocol takes 0.
 *
 * @dev C-1 randomness: a permissionless draw uses the hash of a FUTURE block
 *      (drawBlock = now + DRAW_DELAY). The blockhash is unknown at request time
 *      and un-stale at draw time (within the 256-block horizon); if the horizon
 *      is missed the draw re-arms. Panel selection is a deterministic
 *      index-walk over the registry's enumerable stake-ranked set, excluding
 *      both parties + the original arb and requiring higher stake than the
 *      original arb (proxy for higher tier) + deal-value eligibility. Residual:
 *      the proposer of drawBlock can bias one block; stake-sybil makes biasing
 *      toward chosen members costly. Chainlink VRF is a documented upgrade path.
 *
 * @dev C-2 recursion cap (restated for Phase D sequential cases): any ruling
 *      is appealable AT MOST ONCE to a fresh higher 3-panel; an appeal-panel
 *      ruling is FINAL — max two draws per CASE. A deal may host N SEQUENTIAL
 *      cases (milestone-style templates dispute tranche by tranche), but a new
 *      case can only open once the prior one is TERMINAL (settled/dismissed),
 *      and the slot is fully deleted between cases so no state bleeds. For the
 *      single-dispute templates (v2, v2-open) the per-deal behavior is
 *      unchanged: their escrow-side appeal flags allow at most one appeal, so
 *      such deals still see at most two draws over their lifetime.
 */
contract AppealCourt is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DRAW_DELAY = 4;
    uint256 public constant PANEL_SIZE = 3;

    ArbitratorRegistry public immutable registry;
    IERC20 public immutable STAKING_TOKEN;

    enum Outcome { None, Uphold, Overturn }

    struct Case {
        bool active;
        bool isAppeal; // false = high-value first-ruling panel
        uint8 stage; // 0 = first ruling, 1 = appeal panel (FINAL)
        address originalArb; // arb whose ruling is challenged (single-arb appeals)
        address[3] challengedArbs; // who gets slashed on overturn (len 1 or 3)
        uint8 challengedLen;
        address challenger; // appellant (appeals) / 0 (first-ruling)
        uint256 bond; // appeal bond (0 for first-ruling)
        uint256 drawBlock; // C-1 future block
        uint256 requestedAt; // request timestamp — not-drawn (pool-too-small) timeout anchor
        bool drawn;
        address[3] panel;
        uint8 panelLen;
        uint256 drawDeadline; // no-majority timeout anchor (SLA_DURATION)
        bool settled;
        bool panelCleared; // F3: onPanelSeated/onPanelCleared paired exactly once
        // votes (a member's latest vote; re-vote overwrites)
        address[3] voters;
        uint256[3] voteB;
        uint256[3] voteS;
        uint8 voteCount;
        // majority rule
        uint256 rulingBuyer;
        uint256 rulingSeller;
        bytes32 rulingRationale;
        uint256 origBuyer; // the ruling being challenged (appeals)
        uint256 origSeller;
        uint256 slashedForPanel; // overturn: slash proceeds destined for the panel
    }

    // Internal, NOT public: an auto-generated getter would return all 19
    // non-array Case fields at once → stack-too-deep. Targeted views below.
    mapping(address => Case) internal cases; // by deal (escrow) address

    event PanelRequested(address indexed deal, bool isAppeal, uint256 drawBlock);
    event PanelDrawn(address indexed deal, address[3] panel);
    event PanelVoted(address indexed deal, address member, uint256 buyerAmount, uint256 sellerAmount);
    event AppealResolved(address indexed deal, Outcome outcome, uint256 panelPayout, uint256 appellantRefund);
    event FirstRulingApplied(address indexed deal);
    event OwedCredited(address indexed to, uint256 amount);
    event OwedWithdrawn(address indexed to, uint256 amount);

    /// v5 F3/R3: panel pay / bond refunds a recipient couldn't receive (token blocklist); pull via withdrawOwed.
    mapping(address => uint256) public owed;

    constructor(ArbitratorRegistry _registry) {
        require(address(_registry) != address(0), "zero registry");
        registry = _registry;
        STAKING_TOKEN = _registry.STAKING_TOKEN();
    }

    // ─── Panel request (called by the escrow) ────────────────────────────────

    /// @notice High-value first-ruling panel (C-2): openDispute on a
    ///         dealAmount >= HIGH_VALUE_THRESHOLD calls this. No bond.
    function prepareFirstPanel(address deal, address arb) external {
        require(msg.sender == deal, "deal != escrow");
        _requireEscrow(deal); // F2: only factory-deployed clones open cases
        _request(deal, false, arb, address(0), 0);
    }

    /// @notice Appeal: escrow.appeal() transfers the 20% bond here and calls
    ///         this with the ruling being challenged.
    function onAppeal(
        address deal,
        address originalArb,
        address challenger,
        uint256 bond,
        uint256 origBuyer,
        uint256 origSeller
    ) external {
        require(msg.sender == deal, "deal != escrow");
        _requireEscrow(deal); // F2
        require(bond > 0, "no bond");
        _request(deal, true, originalArb, challenger, bond);
        Case storage c = cases[deal];
        c.origBuyer = origBuyer;
        c.origSeller = origSeller;
        // challenged arb: the single arb who ruled (first-panel overturns set
        // challengedArbs at applyFirstRuling — see below).
        c.challengedArbs[0] = originalArb;
        c.challengedLen = 1;
    }

    function _request(address deal, bool isAppeal, address arb, address challenger, uint256 bond) internal {
        Case storage c = cases[deal];
        // Sequential cases (Phase D / D-REV-1): a new case may open ONLY when no
        // case is in flight. `active` is cleared exactly when a case turns
        // terminal (settle/dismiss set settled=true, active=false together), so
        // !active means the slot is either virgin or terminal. A terminal slot —
        // drawn or not — is fully deleted (delete zeroes every field, panel/vote
        // arrays included) so nothing bleeds into the next case.
        require(!c.active, "case in flight");
        if (c.settled) delete cases[deal];
        c = cases[deal];
        c.active = true;
        c.isAppeal = isAppeal;
        c.originalArb = arb;
        c.challenger = challenger;
        c.bond = bond;
        c.drawBlock = block.number + DRAW_DELAY; // C-1
        c.requestedAt = block.timestamp; // not-drawn timeout anchor (C-REV-1)
        emit PanelRequested(deal, isAppeal, c.drawBlock);
    }

    // ─── C-1 panel draw (permissionless) ─────────────────────────────────────

    /// @notice Permissionless draw: after drawBlock, seed from its blockhash
    ///         (unbiased, unknown at request time, within the 256-block
    ///         horizon). Missed the horizon → re-arm and return (anyone retries).
    function drawPanel(address deal) external nonReentrant {
        Case storage c = cases[deal];
        require(c.active && !c.drawn, "not drawable");
        require(block.number > c.drawBlock, "too early");
        if (block.number - c.drawBlock > 256) {
            c.drawBlock = block.number + DRAW_DELAY; // re-arm
            emit PanelRequested(deal, c.isAppeal, c.drawBlock);
            return;
        }

        bytes32 seed = keccak256(abi.encode(deal, blockhash(c.drawBlock)));
        (address[3] memory panel, uint8 len) = _select(deal, seed, c.originalArb);
        require(len == PANEL_SIZE, "pool too small");
        c.panel = panel;
        c.panelLen = len;
        c.drawn = true;
        c.drawDeadline = block.timestamp + registry.SLA_DURATION();
        registry.onPanelSeated(panel, len); // F3: lock members' unbonding for the case
        emit PanelDrawn(deal, panel);
        _tip(deal); // D4: a successful draw (never a re-arm) earns the tip
    }

    /// @dev Deterministic index-walk over the registry arb set: candidates have
    ///      stake > original arb (higher tier proxy), are deal-eligible, and are
    ///      neither party nor the original arb. Distinct, N=3.
    function _select(address deal, bytes32 seed, address excludeArb)
        internal
        view
        returns (address[3] memory panel, uint8 len)
    {
        uint256 n = registry.arbCount();
        if (n == 0) return (panel, 0); // guard div-by-zero + empty pool
        uint256 idx = uint256(seed) % n;
        for (uint256 examined = 0; examined < n && len < PANEL_SIZE; examined++) {
            address cand = registry.arbAt((idx + examined) % n);
            if (_isCandidate(deal, cand, excludeArb) && !_inPanel(panel, len, cand)) {
                panel[len] = cand;
                len++;
            }
        }
    }

    /// @dev A panel candidate: not a party, not the excluded (original) arb,
    ///      strictly higher stake than the original arb (higher-tier proxy), and
    ///      deal-value-eligible. Extracted to keep _select's stack frame small.
    function _isCandidate(address deal, address cand, address excludeArb) internal view returns (bool) {
        if (cand == excludeArb) return false;
        if (cand == IEscrowCourtHooks(deal).buyer() || cand == IEscrowCourtHooks(deal).seller()) return false;
        // F4 (v5): no "strictly more stake than the excluded arb" gate — it made the top-staked arbitrator's
        // rulings unappealable (no panel could ever seat).
        return registry.isEligible(cand, IEscrowCourtHooks(deal).dealAmount());
    }

    function _inPanel(address[3] memory panel, uint8 len, address cand) internal pure returns (bool) {
        for (uint8 i = 0; i < len; i++) if (panel[i] == cand) return true;
        return false;
    }

    // ─── Voting (panel members) ──────────────────────────────────────────────

    function vote(address deal, uint256 buyerAmount, uint256 sellerAmount, bytes32 rationaleHash) external nonReentrant {
        Case storage c = cases[deal];
        require(c.active && c.drawn && !c.settled, "not votable");
        _requireEscrow(deal); // F2 defense in depth (pre-fix or poisoned state)
        require(_isMember(c, msg.sender), "not member");
        require(buyerAmount + sellerAmount == IEscrowCourtHooks(deal).dealAmount(), "sum != dealAmount");

        _recordVote(c, msg.sender, buyerAmount, sellerAmount);
        emit PanelVoted(deal, msg.sender, buyerAmount, sellerAmount);

        (uint256 b, uint256 s, bool found) = _majority(c);
        if (!found) return;
        _settle(c, deal, b, s, rationaleHash);
    }

    function _recordVote(Case storage c, address member, uint256 b, uint256 s) internal {
        for (uint8 i = 0; i < c.voteCount; i++) {
            if (c.voters[i] == member) {
                c.voteB[i] = b; // re-vote overwrites
                c.voteS[i] = s;
                return;
            }
        }
        require(c.voteCount < PANEL_SIZE, "vote slots full");
        c.voters[c.voteCount] = member;
        c.voteB[c.voteCount] = b;
        c.voteS[c.voteCount] = s;
        c.voteCount++;
    }

    /// @dev Two DISTINCT members with the same (buyerAmount, sellerAmount).
    function _majority(Case storage c) internal view returns (uint256 b, uint256 s, bool found) {
        for (uint8 i = 0; i < c.voteCount; i++) {
            for (uint8 j = i + 1; j < c.voteCount; j++) {
                if (c.voteB[i] == c.voteB[j] && c.voteS[i] == c.voteS[j]) {
                    return (c.voteB[i], c.voteS[i], true);
                }
            }
        }
        return (0, 0, false);
    }

    /// @dev Split into first-panel vs appeal to keep each stack frame small
    ///      (non-via-ir stack budget). Effects (settled/active) are set before the
    ///      external escrow/registry calls (CEI); vote()/dismiss() are nonReentrant.
    function _settle(Case storage c, address deal, uint256 b, uint256 s, bytes32 rationale) internal {
        c.settled = true;
        c.active = false;
        _clearPanel(c); // F3: case terminal — release the members
        if (c.isAppeal) {
            _settleAppeal(c, deal, b, s);
        } else {
            _settleFirstPanel(deal, c, b, s, rationale); // escrow pays the panel from the fee pot
            emit AppealResolved(deal, Outcome.Uphold, 0, 0);
        }
    }

    /// @dev B6: appeal BONDS are held in the DEAL token; overturn SLASH proceeds
    ///      are in STAKING_TOKEN (USDC). Pay each in its own token.
    function _settleAppeal(Case storage c, address deal, uint256 b, uint256 s) internal {
        IERC20 dealToken = IERC20(IEscrowCourtHooks(deal).token());
        if (b == c.origBuyer && s == c.origSeller) {
            _settleUphold(deal, c); // original ruling stands; bond → panel (deal token)
            if (c.bond > 0) _payPanel(c, dealToken, c.bond);
            emit AppealResolved(deal, Outcome.Uphold, c.bond, 0);
        } else {
            _settleOverturn(deal, c, b, s); // slash (USDC → court) + escrow re-settles
            uint256 payout = c.slashedForPanel;
            if (payout > 0) _payPanel(c, STAKING_TOKEN, payout); // slash → panel (USDC)
            if (c.bond > 0 && c.challenger != address(0)) _payOrOwe(dealToken, c.challenger, c.bond); // bond refund (deal token)
            emit AppealResolved(deal, Outcome.Overturn, payout, c.bond);
        }
    }

    function _settleUphold(address deal, Case storage c) internal {
        IEscrowCourtHooks(deal).settleAppealUphold();
    }

    function _settleOverturn(address deal, Case storage c, uint256 b, uint256 s) internal {
        uint256 total;
        for (uint8 i = 0; i < c.challengedLen; i++) {
            total += registry.slashOnOverturn(c.challengedArbs[i]);
        }
        c.slashedForPanel = total;
        IEscrowCourtHooks(deal).settleAppealOverturn(b, s);
    }

    function _settleFirstPanel(address deal, Case storage c, uint256 b, uint256 s, bytes32 rationale) internal {
        for (uint8 i = 0; i < c.panelLen; i++) c.challengedArbs[i] = c.panel[i];
        c.challengedLen = c.panelLen;
        IEscrowCourtHooks(deal).applyFirstRuling(c.panel[0], c.panel[1], c.panel[2], b, s, rationale);
    }

    function _payPanel(Case storage c, IERC20 tkn, uint256 amount) internal {
        uint256 third = amount / 3;
        _payOrOwe(tkn, c.panel[0], third + (amount - third * 3)); // dust to member[0]
        if (c.panelLen > 1) _payOrOwe(tkn, c.panel[1], third);
        if (c.panelLen > 2) _payOrOwe(tkn, c.panel[2], third);
    }

    /// @dev D4: best effort — a template without the hook (pre-v5) or a reverting tip must never block a
    ///      panel draw or a dismissal.
    function _tip(address deal) internal {
        try IEscrowCourtHooks(deal).creditKeeperTip(msg.sender) {} catch {}
    }

    /// @dev F3/R3: a recipient's blocklist must never revert a settlement. Every token here is the registry's
    ///      staking token (F6 binds deal tokens to it), so one owed map suffices.
    function _payOrOwe(IERC20 tkn, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!tkn.trySafeTransfer(to, amount)) {
            owed[to] += amount;
            emit OwedCredited(to, amount);
        }
    }

    function withdrawOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing owed");
        owed[msg.sender] = 0;
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit OwedWithdrawn(msg.sender, amount);
    }

    // ─── Timeout escapes (bounded liveness) ──────────────────────────────────

    /// @notice Two liveness timeouts, both resolving to UPHOLD (original ruling
    ///         stands), so appeal funds can NEVER freeze:
    ///         (1) DRAWN but no 2/3 majority within SLA_DURATION → the drawn
    ///             panel is paid the bond (they showed up, just couldn't agree).
    ///         (2) NEVER DRAWN past requestedAt + SLA_DURATION — the pool was too
    ///             small to seat 3 eligible members (C-REV-1). No panel exists to
    ///             pay, so the bond is REFUNDED to the appellant.
    ///         First-ruling (high-value) panels just clear — the deal stays
    ///         Disputed and the parties keep their mutual-exit paths
    ///         (release/refund/split are valid in Disputed).
    function dismiss(address deal) external nonReentrant {
        Case storage c = cases[deal];
        require(c.active && !c.settled, "not dismissable");
        if (c.drawn) {
            require(block.timestamp >= c.drawDeadline, "too early");
        } else {
            require(block.timestamp >= c.requestedAt + registry.SLA_DURATION(), "too early");
        }
        c.settled = true;
        c.active = false;
        _clearPanel(c); // F3: no-op when never drawn

        if (!c.isAppeal) {
            _tip(deal); // D4: un-sticking a dead first panel
            return; // first-ruling: clear only; escrow stays Disputed (stalemate / re-request paths)
        }

        // Appeal: original ruling stands (uphold). F5 (v5): the bond is ALWAYS refunded to the appellant here —
        // a drawn panel that reached no majority earns nothing (paying it the bond rewarded stalling).
        _settleUphold(deal, c);
        if (c.bond > 0 && c.challenger != address(0)) {
            _payOrOwe(IERC20(IEscrowCourtHooks(deal).token()), c.challenger, c.bond);
            emit AppealResolved(deal, Outcome.Uphold, 0, c.bond);
        } else {
            emit AppealResolved(deal, Outcome.Uphold, 0, 0);
        }
        _tip(deal); // D4
    }

    // ─── Views (targeted — the struct getter would be stack-too-deep) ────────

    /// @notice Case lifecycle flags + the appeal economics.
    function caseOf(address deal)
        external
        view
        returns (bool active, bool isAppeal, bool drawn, bool settled, address challenger, uint256 bond, uint256 drawBlock, uint256 drawDeadline)
    {
        Case storage c = cases[deal];
        return (c.active, c.isAppeal, c.drawn, c.settled, c.challenger, c.bond, c.drawBlock, c.drawDeadline);
    }

    /// @notice The drawn panel and its length.
    function panelOf(address deal) external view returns (address[3] memory panel, uint8 panelLen) {
        Case storage c = cases[deal];
        return (c.panel, c.panelLen);
    }

    /// @notice The ruling being challenged (appeals) — for uphold/overturn checks.
    function origRulingOf(address deal) external view returns (uint256 origBuyer, uint256 origSeller) {
        Case storage c = cases[deal];
        return (c.origBuyer, c.origSeller);
    }

    function isPanelMember(address deal, address who) external view returns (bool) {
        return _isMember(cases[deal], who);
    }

    /// @notice Whether a case is currently in flight for `deal` — lets escrow
    ///         valves (claimStrandedPot) check the court without the full struct.
    function isCaseActive(address deal) external view returns (bool) {
        return cases[deal].active;
    }

    /// @notice When the case was requested (v5: the app no longer has to estimate the not-drawn timeout).
    function requestedAtOf(address deal) external view returns (uint256) {
        return cases[deal].requestedAt;
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    /// @dev F2: only clones recorded by the registry's matched factory may open
    ///      or feed cases. Without this, any contract could report arbitrary
    ///      buyer/seller/dealAmount and grief draws / farm junk cases.
    function _requireEscrow(address deal) internal view {
        require(address(registry.factory()) != address(0), "no factory");
        require(registry.factory().isEscrow(deal), "not escrow");
    }

    /// @dev F3: release drawn members exactly once per case.
    function _clearPanel(Case storage c) internal {
        if (!c.drawn || c.panelCleared) return;
        c.panelCleared = true;
        registry.onPanelCleared(c.panel, c.panelLen);
    }


    function _isMember(Case storage c, address who) internal view returns (bool) {
        for (uint8 i = 0; i < c.panelLen; i++) if (c.panel[i] == who) return true;
        return false;
    }
}
