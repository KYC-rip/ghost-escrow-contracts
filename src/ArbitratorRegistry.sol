// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal view interface the registry uses to authenticate escrows: the
///      matched factory (set once, ownerlessly) records each escrow it deploys.
interface IRegistryAuth {
    function isEscrow(address) external view returns (bool);
}

/**
 * @title ArbitratorRegistry — Phase B (staked, anonymous, permissionless)
 * @notice Ownerless, immutable, no upgrade, no selfdestruct, no admin, no drain
 *         path. Arbitrators bond USDC and register a pseudonymous address +
 *         chat pubkey; eligibility for a deal of `dealAmount` is
 *         `stake * STAKE_MULTIPLE >= dealAmount`.
 *
 * @dev Phase B additions (design §5g + fold-ins):
 *      - ACTIVE-CASE-AWARE UNBONDING (§5f fix): requestUnbond/withdraw revert
 *        while openCases[arb] > 0 — an arbitrator can't unbond out from under
 *        an open dispute, closing the withdraw-then-rule exploit (harmless in
 *        A only because A had no slashing) and delivering the round-1
 *        concurrent-exposure ask.
 *      - SLA-TIMEOUT SLASH: any escrow (via its own slashForTimeout) can slash
 *        an arbitrator who hasn't ruled SLA_DURATION after assignment. Proceeds
 *        go to the dispute opener (compensation), and the deal is cleared for
 *        replacement. Idempotent per deal; a late rule() is impossible because
 *        the escrow clears the arbitrator when slashed.
 *      - Assignment hooks callable ONLY by a genuine factory-deployed escrow:
 *        the matched EscrowFactoryV2 records isEscrow[escrow]=true at deploy
 *        (append-only) and the factory sets itself as this registry's auth in
 *        its own constructor. Registry + factory are a matched immutable pair.
 *
 *      Slashing is otherwise Phases B(partial)/C (AppealCourt overturn) — this
 *      contract will never have an owner or a human slash path.
 */
contract ArbitratorRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutable parameters ────────────────────────────────────────────────

    IERC20 public immutable STAKING_TOKEN; // USDC
    /// Stake multiple: stake * STAKE_MULTIPLE >= dealAmount for eligibility.
    uint256 public immutable STAKE_MULTIPLE;
    /// Minimum wait between requestUnbond() and withdraw() (e.g. 21 days).
    uint256 public immutable UNBONDING_DELAY;
    /// Time an arbitrator has to rule after being assigned a dispute.
    uint256 public immutable SLA_DURATION;
    /// Fraction of stake slashed on an SLA miss (e.g. 1000 = 10%).
    uint256 public immutable SLA_SLASH_BPS;
    /// Fraction of stake slashed on an appeal OVERTURN (e.g. 10000 = 100%, C-4).
    uint256 public immutable OVERTURN_SLASH_BPS;
    /// Minimum total stake to enter/stay in the draw list (F4: raises the cost
    /// of dust-sybil bloating of the panel-draw walk). 0 disables (tests only).
    uint256 public immutable MIN_STAKE;

    /// The matched factory (set ONCE by the deployer, post-deploy) AND the
    /// AppealCourt (also set once by the deployer). Ownerless post-bind:
    /// `deployer` is a one-shot bootstrap (records who deployed the registry)
    /// with no ongoing power — the only things it can ever do are bind the
    /// factory and the court once each, before any hook/slash can run.
    address public immutable deployer;
    IRegistryAuth public factory;
    address public court; // AppealCourt — sole caller of slashOnOverturn (C-5)

    // ─── State ───────────────────────────────────────────────────────────────

    struct Arbitrator {
        uint256 stake; // USDC, base units
        uint256 pendingUnbond; // amount requested for unbonding
        uint256 pendingSince; // block.timestamp of the unbond request
        string chatPubkey; // for dispute-time CK encryption (Shamir rev 3)
    }

    mapping(address => Arbitrator) private _arbitrators;

    /// @dev Enumerable append-only arbitrator set (C-1) for panel draws.
    address[] private _arbList;
    mapping(address => uint256) private _arbIndex; // position + 1; 0 = absent

    /// @dev Open (assigned, unruled) disputes per arbitrator — gates unbonding.
    mapping(address => uint256) public openCases;

    struct Assignment {
        bool assigned;
        address arb;
        address escrow; // which escrow opened the case (slash authority scoping)
        address opener; // dispute opener — slash compensation recipient
        uint256 assignedAt; // SLA anchor
    }
    mapping(address => Assignment) private _assignments; // by deal address
    mapping(address => bool) public slashed; // per deal — idempotent slash

    // ─── Events (reputation read-model source) ───────────────────────────────

    event Staked(address indexed arb, uint256 amount, string chatPubkey);
    event ChatPubkeyUpdated(address indexed arb, string chatPubkey);
    event UnbondRequested(address indexed arb, uint256 amount, uint256 since);
    event Unbonded(address indexed arb, uint256 amount);
    event Assigned(address indexed deal, address indexed arb, address escrow);
    event Resolved(address indexed deal, address indexed arb);
    event Slashed(address indexed deal, address indexed arb, uint256 amount, address opener);
    event OverturnSlashed(address indexed arb, uint256 amount);

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        IERC20 _stakingToken,
        uint256 _stakeMultiple,
        uint256 _unbondingDelay,
        uint256 _slaDuration,
        uint256 _slaSlashBps,
        uint256 _overturnSlashBps,
        uint256 _minStake,
        address _deployer
    ) {
        require(address(_stakingToken) != address(0), "zero token");
        require(_stakeMultiple > 0, "zero multiple");
        require(_unbondingDelay > 0, "zero delay");
        require(_slaDuration > 0, "zero sla");
        require(_slaSlashBps > 0 && _slaSlashBps <= 10000, "bad slash");
        require(_overturnSlashBps > 0 && _overturnSlashBps <= 10000, "bad overturn");
        STAKING_TOKEN = _stakingToken;
        STAKE_MULTIPLE = _stakeMultiple;
        UNBONDING_DELAY = _unbondingDelay;
        SLA_DURATION = _slaDuration;
        SLA_SLASH_BPS = _slaSlashBps;
        OVERTURN_SLASH_BPS = _overturnSlashBps;
        MIN_STAKE = _minStake;
        // Explicit arg, not msg.sender: under a CREATE3 deploy the constructor
        // runs from an ephemeral proxy that can never call again — the one-shot
        // bind gate must name the real ops key. Semantics unchanged otherwise.
        require(_deployer != address(0), "zero deployer");
        deployer = _deployer;
    }

    /// @notice One-time auth binding: the DEPLOYER (recorded at construction)
    ///         binds the matched factory AFTER it is deployed. Gate prevents a
    ///         front-run of setFactory from hijacking the hook/slash auth
    ///         (Phase B review — MEDIUM-HIGH). Ownerless post-bind: the
    ///         deployer can do nothing else, ever. Reverts if already bound.
    function setFactory(address _factory) external {
        require(msg.sender == deployer, "not deployer");
        require(address(factory) == address(0), "locked");
        require(_factory != address(0), "zero");
        factory = IRegistryAuth(_factory);
    }

    /// @notice One-time court binding, same deployer-gated discipline as
    ///         setFactory (C-5). The court is the SOLE caller of slashOnOverturn,
    ///         so this gate is fund-critical: a front-run must not be able to
    ///         install a rogue court that slashes staked USDC. Ownerless
    ///         post-bind — reverts if already set.
    function setCourt(address _court) external {
        require(msg.sender == deployer, "not deployer");
        require(court == address(0), "locked");
        require(_court != address(0), "zero");
        court = _court;
    }

    // ─── Staking / registration ──────────────────────────────────────────────

    function stake(uint256 amount, string calldata chatPubkey) external nonReentrant {
        require(amount > 0, "zero");
        Arbitrator storage a = _arbitrators[msg.sender];
        require(a.stake + amount >= MIN_STAKE, "below min stake");
        if (a.stake == 0) {
            require(bytes(chatPubkey).length > 0, "no pubkey");
            a.chatPubkey = chatPubkey;
            if (_arbIndex[msg.sender] == 0) {
                _arbList.push(msg.sender);
                _arbIndex[msg.sender] = _arbList.length;
            }
        }
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        a.stake += amount;
        emit Staked(msg.sender, amount, a.chatPubkey);
    }

    /// @dev F4: swap-and-pop an arb out of the draw list the moment their stake
    ///      hits 0 (full withdraw / slash-to-zero) so `drawPanel`'s walk stays
    ///      bounded by arbs with skin in the game. Re-staking re-enters via the
    ///      `_arbIndex == 0` branch in stake(). No-op when absent.
    function _removeFromList(address arb) internal {
        uint256 pos = _arbIndex[arb]; // position + 1
        if (pos == 0) return;
        uint256 lastIdx = _arbList.length - 1;
        address last = _arbList[lastIdx];
        if (pos - 1 != lastIdx) {
            _arbList[pos - 1] = last;
            _arbIndex[last] = pos;
        }
        _arbList.pop();
        _arbIndex[arb] = 0;
    }

    function setChatPubkey(string calldata chatPubkey) external {
        require(bytes(chatPubkey).length > 0, "no pubkey");
        require(_arbitrators[msg.sender].stake > 0, "not staked");
        _arbitrators[msg.sender].chatPubkey = chatPubkey;
        emit ChatPubkeyUpdated(msg.sender, chatPubkey);
    }

    // ─── Assignment hooks (escrow → registry; CEI-safe, escrow-authenticated) ─

    function _requireEscrow() internal view {
        require(address(factory) != address(0), "no factory");
        require(factory.isEscrow(msg.sender), "not escrow");
    }

    function _assign(address arb, address deal) internal {
        Assignment storage asg = _assignments[deal];
        require(!asg.assigned, "already assigned");
        openCases[arb] += 1;
        asg.assigned = true;
        asg.arb = arb;
        asg.escrow = msg.sender;
        asg.assignedAt = block.timestamp;
        emit Assigned(deal, arb, msg.sender);
    }

    /// @notice A dispute opened: record the case + the SLA anchor + the opener
    ///         (slash compensation recipient).
    function onDisputeOpened(address arb, address opener) external {
        _requireEscrow();
        Assignment storage asg = _assignments[msg.sender];
        asg.opener = opener;
        _assign(arb, msg.sender);
    }

    /// @notice An arbitrator was (re)assigned to an open dispute (mutual replace
    ///         while Disputed). Resets the SLA clock for the new arbitrator.
    function onAssigned(address arb, address deal) external {
        _requireEscrow();
        require(msg.sender == deal, "deal != escrow");
        _assign(arb, deal);
    }

    /// @notice A case resolved (ruled / mutually settled / slashed-and-cleared).
    ///         Guarded by assigned[deal] so an Active-only terminal path (no
    ///         dispute ever opened) NO-OPS — never underflows openCases.
    function onResolved(address arb, address deal) external {
        _requireEscrow();
        require(msg.sender == deal, "deal != escrow");
        Assignment storage asg = _assignments[deal];
        if (!asg.assigned) return; // no open case — no-op (underflow guard)
        require(asg.escrow == msg.sender, "wrong escrow");
        openCases[asg.arb] -= 1;
        delete _assignments[deal];
        emit Resolved(deal, arb);
    }

    // ─── SLA-timeout slash (permissionless via the escrow) ───────────────────

    /// @notice Slash an arbitrator who hasn't ruled SLA_DURATION after
    ///         assignment. Called by the escrow (its slashForTimeout) so the
    ///         escrow can also clear its arbitrator + return the fee pot. The
    ///         escrow's auth scopes this to the deal's own escrow.
    function slashTimeoutStake(address deal) external returns (uint256 slashedAmount) {
        _requireEscrow();
        Assignment storage asg = _assignments[deal];
        require(!slashed[deal], "already slashed");
        require(msg.sender == asg.escrow && asg.assigned, "not assigned");
        require(block.timestamp > asg.assignedAt + SLA_DURATION, "too early");

        address arb = asg.arb;
        address opener = asg.opener; // capture BEFORE delete (delete zeroes the struct)
        slashedAmount = (_arbitrators[arb].stake * SLA_SLASH_BPS) / 10000;
        require(_arbitrators[arb].stake >= slashedAmount, "low stake");

        openCases[arb] -= 1;
        _arbitrators[arb].stake -= slashedAmount;
        delete _assignments[deal];
        slashed[deal] = true;

        if (_arbitrators[arb].stake == 0) _removeFromList(arb);
        STAKING_TOKEN.safeTransfer(opener, slashedAmount);
        emit Slashed(deal, arb, slashedAmount, opener);
    }

    // ─── Panel locks (AppealCourt only, F3) ──────────────────────────────────

    /// @notice A panel was drawn for a case: lock every member's unbonding for
    ///         the life of the case (openCases++ each). Without this a drawn
    ///         member could requestUnbond mid-case and evade the overturn-slash
    ///         deterrent entirely — the 21d UNBONDING_DELAY was the only guard.
    function onPanelSeated(address[3] calldata panel, uint8 len) external {
        require(msg.sender == court, "not court");
        for (uint8 i = 0; i < len; i++) openCases[panel[i]] += 1;
    }

    /// @notice The case turned terminal (settled or dismissed): release the
    ///         drawn members. The court pairs this 1:1 with onPanelSeated via
    ///         its per-case `panelCleared` flag, so no underflow is reachable.
    function onPanelCleared(address[3] calldata panel, uint8 len) external {
        require(msg.sender == court, "not court");
        for (uint8 i = 0; i < len; i++) openCases[panel[i]] -= 1;
    }

    // ─── Overturn slash (AppealCourt only) ───────────────────────────────────

    /// @notice Slash OVERTURN_SLASH_BPS of an arbitrator's stake on an appeal
    ///         overturn. Callable ONLY by the bound court (C-5). Proceeds are
    ///         transferred to the court (msg.sender), which pays the appeal
    ///         panel. CEI: stake reduced before the transfer. `amount <= stake`
    ///         always (BPS <= 10000), so no underflow. Reputation read-model
    ///         emits OverturnSlashed. (If the arb has a pending unbond, the
    ///         UNBONDING_DELAY is sized to outlast the 48h appeal window so the
    ///         slash lands before any withdrawal completes.)
    function slashOnOverturn(address arb) external returns (uint256 amount) {
        require(msg.sender == court, "not court");
        amount = (_arbitrators[arb].stake * OVERTURN_SLASH_BPS) / 10000;
        _arbitrators[arb].stake -= amount;
        if (_arbitrators[arb].stake == 0) _removeFromList(arb);
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit OverturnSlashed(arb, amount);
    }

    // ─── Unbonding (blocked while any case is open) ──────────────────────────

    function requestUnbond(uint256 amount) external {
        require(openCases[msg.sender] == 0, "open cases");
        Arbitrator storage a = _arbitrators[msg.sender];
        require(amount > 0 && amount <= a.stake, "bad amount");
        // F4: a PARTIAL exit may not leave a sub-floor stub in the draw list —
        // that would let a sybil pay MIN_STAKE once, unbond to dust and keep a
        // list slot forever. Leave at least the floor, or leave entirely.
        // (An involuntary slash may still land below the floor — punishment
        // shrinks the stake in place; it does not mint list slots.)
        require(amount == a.stake || a.stake - amount >= MIN_STAKE, "leave min or all");
        a.pendingUnbond = amount;
        a.pendingSince = block.timestamp;
        emit UnbondRequested(msg.sender, amount, block.timestamp);
    }

    function withdraw() external nonReentrant {
        require(openCases[msg.sender] == 0, "open cases");
        Arbitrator storage a = _arbitrators[msg.sender];
        require(a.pendingUnbond > 0, "nothing pending");
        require(block.timestamp >= a.pendingSince + UNBONDING_DELAY, "too early");
        // Cap to current stake: an overturn slash may have legitimately beaten the
        // exit and reduced stake below the pending amount (C-REV-2). Without this
        // `a.stake -= amount` would underflow-revert and strand the remaining stake.
        uint256 amount = a.pendingUnbond;
        if (amount > a.stake) amount = a.stake;
        a.pendingUnbond = 0;
        a.stake -= amount;
        if (a.stake == 0) _removeFromList(msg.sender);
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit Unbonded(msg.sender, amount);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    function isEligible(address arb, uint256 dealAmount) external view returns (bool) {
        if (dealAmount == 0) return true;
        uint256 stk = _arbitrators[arb].stake;
        if (stk == 0) return false;
        return stk * STAKE_MULTIPLE >= dealAmount;
    }

    function stakeOf(address arb) external view returns (uint256) {
        return _arbitrators[arb].stake;
    }

    function chatPubkeyOf(address arb) external view returns (string memory) {
        return _arbitrators[arb].chatPubkey;
    }

    function pendingUnbondOf(address arb) external view returns (uint256, uint256) {
        return (_arbitrators[arb].pendingUnbond, _arbitrators[arb].pendingSince);
    }

    function assignmentOf(address deal)
        external
        view
        returns (bool assigned, address arb, address escrow, address opener, uint256 assignedAt)
    {
        Assignment storage a = _assignments[deal];
        return (a.assigned, a.arb, a.escrow, a.opener, a.assignedAt);
    }

    // ─── Enumerable arb set (C-1: panel draws) ───────────────────────────────

    function arbCount() external view returns (uint256) {
        return _arbList.length;
    }

    function arbAt(uint256 i) external view returns (address) {
        return _arbList[i];
    }
}
