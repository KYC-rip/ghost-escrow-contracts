// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GhostTestBaseD} from "../utils/GhostTestBaseD.sol";
import {GhostEscrowV2CImpl} from "../../src/GhostEscrowV2CImpl.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {AppealCourt} from "../../src/AppealCourt.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {SigUtils} from "../utils/SigUtils.sol";

/// @dev Stateful handler: four deals (three sub-threshold, one panel-required)
///      driven through fund / dispute / rule / appeal / slash / escalate /
///      draw / vote / dismiss / finalize / mutual-release / time in random
///      order. Every call is try/catch — illegal transitions must revert in
///      the contracts, never corrupt registry accounting.
contract DisputeHandler is Test {
    GhostEscrowV2CImpl[4] public deals;
    ArbitratorRegistry public immutable registry;
    AppealCourt public immutable court;
    MockERC20 public immutable token;
    uint256 internal immutable buyerPk;
    uint256 internal immutable sellerPk;
    address public immutable buyer;
    address public immutable seller;
    uint256 internal immutable chainId;

    bytes32 private constant RELEASE_TYPEHASH = keccak256("Release(uint256 nonce,uint256 deadline)");
    address[6] public arbs; // for unbond/withdraw churn

    constructor(
        GhostEscrowV2CImpl[4] memory _deals,
        ArbitratorRegistry _registry,
        AppealCourt _court,
        MockERC20 _token,
        uint256 _buyerPk,
        uint256 _sellerPk,
        uint256 _chainId
    ) {
        deals = _deals;
        registry = _registry;
        court = _court;
        token = _token;
        buyerPk = _buyerPk;
        sellerPk = _sellerPk;
        buyer = vm.addr(_buyerPk);
        seller = vm.addr(_sellerPk);
        chainId = _chainId;
    }

    function setArbs(address[6] memory _arbs) external {
        arbs = _arbs;
    }

    function dealCount() external pure returns (uint256) {
        return 4;
    }

    function _deal(uint256 seed) internal view returns (GhostEscrowV2CImpl) {
        return deals[seed % 4];
    }

    function _party(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? buyer : seller;
    }

    function fund(uint256 seed) external {
        GhostEscrowV2CImpl e = _deal(seed);
        uint256 amt = e.dealAmount();
        token.mint(buyer, amt);
        vm.startPrank(buyer);
        token.approve(address(e), amt);
        try e.deposit(amt) {} catch {}
        vm.stopPrank();
    }

    function dispute(uint256 seed) external {
        GhostEscrowV2CImpl e = _deal(seed);
        address opener = _party(seed);
        uint256 fee = e.arbitratorFee();
        token.mint(opener, fee);
        vm.startPrank(opener);
        token.approve(address(e), fee);
        try e.openDispute() {} catch {}
        vm.stopPrank();
    }

    function rule(uint256 seed, uint256 buyerShare) external {
        GhostEscrowV2CImpl e = _deal(seed);
        uint256 amt = e.dealAmount();
        buyerShare = bound(buyerShare, 0, amt);
        vm.prank(e.arbitrator());
        try e.rule(buyerShare, amt - buyerShare, keccak256("r")) {} catch {}
    }

    function appealRuling(uint256 seed) external {
        GhostEscrowV2CImpl e = _deal(seed);
        address who = _party(seed);
        uint256 bond = (e.dealAmount() * e.APPEAL_BOND_BPS()) / 10000;
        token.mint(who, bond);
        vm.startPrank(who);
        token.approve(address(e), bond);
        try e.appeal() {} catch {}
        vm.stopPrank();
    }

    function slashTimeout(uint256 seed) external {
        try _deal(seed).slashForTimeout() {} catch {}
    }

    function escalate(uint256 seed) external {
        vm.prank(_party(seed));
        try _deal(seed).escalateAfterTimeout() {} catch {}
    }

    function requestPanel(uint256 seed) external {
        vm.prank(_party(seed));
        try _deal(seed).requestFirstPanel() {} catch {}
    }

    function draw(uint256 seed) external {
        GhostEscrowV2CImpl e = _deal(seed);
        (,,,,,, uint256 drawBlock,) = court.caseOf(address(e));
        if (drawBlock == 0) return;
        if (block.number <= drawBlock) vm.roll(drawBlock + 1);
        try court.drawPanel(address(e)) {} catch {}
    }

    function vote(uint256 seed, uint256 buyerShare, bool split) external {
        GhostEscrowV2CImpl e = _deal(seed);
        (address[3] memory panel, uint8 len) = court.panelOf(address(e));
        if (len == 0) return;
        uint256 amt = e.dealAmount();
        buyerShare = bound(buyerShare, 0, amt);
        // Two agreeing votes (majority) — or one lone vote when `split` (case
        // stays live, members stay locked; a later call can finish it).
        vm.prank(panel[0]);
        try court.vote(address(e), buyerShare, amt - buyerShare, keccak256("v")) {} catch {}
        if (!split) {
            vm.prank(panel[1]);
            try court.vote(address(e), buyerShare, amt - buyerShare, keccak256("v")) {} catch {}
        }
    }

    function dismissCase(uint256 seed) external {
        try court.dismiss(address(_deal(seed))) {} catch {}
    }

    function finalizeRuling(uint256 seed) external {
        try _deal(seed).finalize() {} catch {}
    }

    function mutualRelease(uint256 seed) external {
        GhostEscrowV2CImpl e = _deal(seed);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(RELEASE_TYPEHASH, e.nonce(), deadline));
        bytes32 digest = SigUtils.digest(address(e), chainId, structHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(buyerPk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(sellerPk, digest);
        try e.release(deadline, abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2)) {} catch {}
    }

    function warp(uint256 secs) external {
        // Mostly short hops so post-warp fund/dispute stay live; a rare long
        // warp still exercises the timeout/auto-release windows (review skew).
        uint256 d = secs % 8 == 0 ? bound(secs, 7 days, 9 days) : bound(secs, 1 hours, 36 hours);
        vm.warp(block.timestamp + d);
        vm.roll(block.number + 10);
    }

    /// v5: the random arbitrator draw (replaces the removed mutual replaceArbitrator action).
    function drawArb(uint256 seed) external {
        GhostEscrowV2CImpl e = _deal(seed);
        vm.roll(block.number + (seed % 300) + 5); // sometimes inside, sometimes past the 256-block horizon
        try e.drawArbitrator() {} catch {}
    }

    /// v5: the 14-day "nobody could decide" split.
    function stalemate(uint256 seed) external {
        vm.prank(_party(seed));
        try _deal(seed).stalemateSplit() {} catch {}
    }

    function claimPot(uint256 seed) external {
        vm.prank(_party(seed));
        try _deal(seed).claimStrandedPot() {} catch {}
    }

    function unbond(uint256 seed, uint256 amount) external {
        address who = arbs[seed % 6];
        amount = bound(amount, 1, 500e6);
        vm.prank(who);
        try registry.requestUnbond(amount) {} catch {}
    }

    function withdrawStake(uint256 seed) external {
        vm.prank(arbs[seed % 6]);
        try registry.withdraw() {} catch {}
    }
}

/// The security-batch invariant seeds (plan §8, review follow-up):
/// ΣopenCases stays exactly balanced against live assignments + seated panels,
/// and an assignment only ever exists where rule() is legally callable (the
/// F1/G1 property, held under ANY action interleaving — not just the tested
/// paths).
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
contract DisputeInvariantTest is GhostTestBaseD {
    DisputeHandler internal handler;
    GhostEscrowV2CImpl[4] internal dealArr;
    address[6] internal trackedArbs;

    uint256 internal constant HV_AMOUNT = 30_000e6;

    function setUp() public override {
        super.setUp();
        // Pool: the nominated arb covers both tiers; three higher-staked panel
        // candidates; two bystanders (must never gain openCases).
        _stake(arb, 3_000e6, "arb");
        _stake(p1, 3_100e6, "p1");
        _stake(p2, 3_100e6, "p2");
        _stake(p3, 3_100e6, "p3");
        address by1 = vm.addr(0xB051);
        address by2 = vm.addr(0xB052);
        _stake(by1, 500e6, "by1");
        _stake(by2, 500e6, "by2");
        trackedArbs = [arb, p1, p2, p3, by1, by2];

        for (uint256 i = 0; i < 3; i++) {
            dealArr[i] = _createStd(bytes32(uint256(0xD15D + i)));
        }
        dealArr[3] = GhostEscrowV2CImpl(
            factory.createDeal(
                address(stdImpl),
                abi.encode(address(token), buyer, seller, address(0), HV_AMOUNT, uint256(0), DEPOSIT_TIMEOUT, AUTO_RELEASE),
                bytes32(uint256(0xD15D + 3))
            )
        );

        handler = new DisputeHandler(dealArr, registry, court, token, buyerPk, sellerPk, chainId);
        handler.setArbs(trackedArbs);
        targetContract(address(handler));
    }

    /// Guard against vacuous invariants: prove the handler actually reaches
    /// the deep states (funded, disputed+assigned, slashed, escalated, drawn,
    /// settled; high-value case without assignment) — if a refactor makes an
    /// action silently revert forever, this fails instead of the invariants
    /// passing over an empty state space.
    function test_handlerReachesDeepStates() public {
        // High-value FIRST — the 8-day warp below would close its 72h deposit window.
        handler.fund(3);
        handler.dispute(3);
        (bool hvAssigned,,,,) = registry.assignmentOf(address(dealArr[3]));
        assertFalse(hvAssigned, "high-value dispute must NOT assign (F1)");
        (bool hvActive,,,,,,,) = court.caseOf(address(dealArr[3]));
        assertTrue(hvActive, "high-value dispute opened a first-panel case");

        handler.fund(0);
        assertEq(uint256(dealArr[0].state()), uint256(GhostEscrowV2CImpl.State.Active));
        handler.dispute(0);
        (bool assigned,,,,) = registry.assignmentOf(address(dealArr[0]));
        assertFalse(assigned, "v5: no assignment until the random draw");
        handler.drawArb(0); // rolls 5 blocks — inside the horizon
        (assigned,,,,) = registry.assignmentOf(address(dealArr[0]));
        assertTrue(assigned, "sub-threshold dispute assigns at the draw");
        invariant_openCasesExactlyBalanced();
        handler.warp(8 days);
        handler.slashTimeout(0);
        assertEq(dealArr[0].arbitrator(), address(0), "timeout slash reached");
        handler.escalate(0);
        (bool active,,,,,,,) = court.caseOf(address(dealArr[0]));
        assertTrue(active, "escalation opened a court case");
        handler.draw(0);
        (,, bool drawn,,,,,) = court.caseOf(address(dealArr[0]));
        assertTrue(drawn, "panel drawn");
        invariant_openCasesExactlyBalanced();
        handler.vote(0, 1_000e6, false);
        (,,, bool settled,,,,) = court.caseOf(address(dealArr[0]));
        assertTrue(settled, "panel majority settled the case");
        assertEq(uint256(dealArr[0].state()), uint256(GhostEscrowV2CImpl.State.RuledPendingAppeal));
        invariant_openCasesExactlyBalanced();
        invariant_assignmentImpliesRulable();
        invariant_registrySolvent();
    }

    /// INV: for every arb, openCases == live single-arb assignments naming them
    /// + seats on drawn-and-unsettled panels. No leak, no underflow, no
    /// stranded lock — under any interleaving.
    function invariant_openCasesExactlyBalanced() public view {
        for (uint256 a = 0; a < trackedArbs.length; a++) {
            address who = trackedArbs[a];
            uint256 expected;
            for (uint256 i = 0; i < 4; i++) {
                address deal = address(dealArr[i]);
                (bool assigned, address asgArb,,,) = registry.assignmentOf(deal);
                if (assigned && asgArb == who) expected += 1;
                (,, bool drawn, bool settled,,,,) = court.caseOf(deal);
                if (drawn && !settled && court.isPanelMember(deal, who)) expected += 1;
            }
            assertEq(registry.openCases(who), expected, "openCases out of balance");
        }
    }

    /// INV (F1/G1): a registry assignment exists ONLY where the assigned arb
    /// could legally rule() right now: deal Disputed, sub-threshold, and still
    /// the deal's current arbitrator.
    function invariant_assignmentImpliesRulable() public view {
        for (uint256 i = 0; i < 4; i++) {
            GhostEscrowV2CImpl e = dealArr[i];
            (bool assigned, address asgArb,,,) = registry.assignmentOf(address(e));
            if (!assigned) continue;
            // F1 (v5): the case stays open through the appeal window, so RuledPendingAppeal is legitimate too.
            assertTrue(
                e.state() == GhostEscrowV2CImpl.State.Disputed || e.state() == GhostEscrowV2CImpl.State.RuledPendingAppeal,
                "assignment outside Disputed/RuledPendingAppeal"
            );
            assertLt(e.dealAmount(), e.HIGH_VALUE_THRESHOLD(), "assignment on a panel-required deal");
            assertEq(e.arbitrator(), asgArb, "assignment names a replaced arb");
        }
    }

    /// INV (v5): every deal can always pay what it owes — deal funds (incl. unclaimed keeper tips), the fee pot and
    /// parked payouts (F3 owed) — whatever the fuzzer did (draws, re-arms, stalemates, slashes, appeals).
    function invariant_dealSolvent() public view {
        for (uint256 i = 0; i < 4; i++) {
            GhostEscrowV2CImpl e = dealArr[i];
            assertGe(
                token.balanceOf(address(e)),
                e.deposited() + e.arbitratorFeePot() + e.owedTotal(),
                "deal holds less than it owes"
            );
            assertLe(e.tipsTotal(), (e.dealAmount() * e.platformFeeBps()) / 10_000, "tips exceed the platform fee");
        }
    }

    /// INV: the registry can always pay out every recorded stake — slashes move
    /// tokens out in the same breath they reduce the number.
    function invariant_registrySolvent() public view {
        uint256 total;
        for (uint256 a = 0; a < trackedArbs.length; a++) {
            total += registry.stakeOf(trackedArbs[a]);
        }
        assertEq(token.balanceOf(address(registry)), total, "registry balance != sum of stakes");
    }
}
