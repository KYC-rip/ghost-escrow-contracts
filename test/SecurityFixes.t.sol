// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GhostTestBaseD} from "./utils/GhostTestBaseD.sol";
import {GhostEscrowV2CImpl} from "../src/GhostEscrowV2CImpl.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev F2 fixture: a contract that is NOT a factory clone but tries to open
///      court cases on itself with fabricated deal facts.
contract FakeDeal {
    address public buyer = address(0xB1);
    address public seller = address(0xB2);
    uint256 public dealAmount = 1e6;

    function token() external pure returns (address) {
        return address(0);
    }

    function callPrepare(AppealCourt court) external {
        court.prepareFirstPanel(address(this), address(0xA1));
    }

    function callAppeal(AppealCourt court) external {
        court.onAppeal(address(this), address(0xA1), address(this), 1, 0, 1e6);
    }

    function settleAppealUphold() external {}
    function settleAppealOverturn(uint256, uint256) external {}
    function applyFirstRuling(address, address, address, uint256, uint256, bytes32) external {}
}

/// Regressions for the 9 pre-mainnet findings (+ review amendments G1/G2).
/// Naming: fix id → behavior now guaranteed.
contract SecurityFixesTest is GhostTestBaseD {
    uint256 internal constant HV_AMOUNT = 30_000e6; // above the 25k panel threshold
    uint256 internal constant HV_ARB_STAKE = 3_000e6; // eligible for HV_AMOUNT
    uint256 internal constant HV_PANEL_STAKE = 3_100e6; // strictly higher tier

    bytes32 internal constant REPLACE_ARB_TYPEHASH =
        keccak256("ReplaceArbitrator(address newArbitrator,uint256 nonce,uint256 deadline)");

    // ─── helpers ───────────────────────────────────────────────────────────

    function _hvInitData() internal view returns (bytes memory) {
        return abi.encode(address(token), buyer, seller, arb, HV_AMOUNT, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE);
    }

    function _createHv(bytes32 salt) internal returns (GhostEscrowV2CImpl e) {
        _stake(arb, HV_ARB_STAKE, "arb-pubkey");
        e = GhostEscrowV2CImpl(factory.createDeal(address(stdImpl), _hvInitData(), salt));
        _fund(buyer, HV_AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), HV_AMOUNT);
        vm.prank(buyer);
        e.deposit(HV_AMOUNT);
        _fund(buyer, ARB_FEE);
        vm.prank(buyer);
        token.approve(address(e), ARB_FEE);
        vm.prank(buyer);
        e.openDispute();
    }

    function _stakeHvPanel() internal {
        _stake(p1, HV_PANEL_STAKE, "p1");
        _stake(p2, HV_PANEL_STAKE, "p2");
        _stake(p3, HV_PANEL_STAKE, "p3");
    }

    function _replaceSigs(GhostEscrowV2CImpl e, address newArb, uint256 deadline)
        internal
        returns (bytes memory bSig, bytes memory sSig)
    {
        bytes32 structHash = keccak256(abi.encode(REPLACE_ARB_TYPEHASH, newArb, e.nonce(), deadline));
        bytes32 d = SigUtils.digest(address(e), chainId, structHash);
        bSig = _sig(buyerPk, d);
        sSig = _sig(sellerPk, d);
    }

    function _voteMajority(address deal, uint256 b, uint256 s) internal {
        (address[3] memory panel,) = court.panelOf(deal);
        vm.prank(panel[0]);
        court.vote(deal, b, s, keccak256("r"));
        vm.prank(panel[1]);
        court.vote(deal, b, s, keccak256("r"));
    }

    // ─── F1: high-value deals never SLA-arm the nominated arb ──────────────

    function test_F1_highValueDispute_noAssignment_noSlash() public {
        GhostEscrowV2CImpl e = _createHv(bytes32(uint256(101)));
        (bool assigned,,,,) = registry.assignmentOf(address(e));
        assertFalse(assigned, "no registry assignment on panel deals");
        assertEq(registry.openCases(arb), 0, "no openCases for the nominated arb");

        vm.warp(block.timestamp + SLA_DURATION + 1);
        vm.expectRevert(bytes("panel case"));
        e.slashForTimeout();
    }

    function test_F1_nominatedArbCanUnbondDuringPanelCase() public {
        _createHv(bytes32(uint256(102)));
        vm.prank(arb);
        registry.requestUnbond(HV_ARB_STAKE); // no openCases — must not revert
    }

    function test_F1_dismissedPanelLeavesArbClean_thenG2Rearms() public {
        // No panel stakers → the case can never draw; dismiss after SLA.
        GhostEscrowV2CImpl e = _createHv(bytes32(uint256(103)));
        vm.warp(block.timestamp + SLA_DURATION + 1);
        court.dismiss(address(e));
        (bool assigned,,,,) = registry.assignmentOf(address(e));
        assertFalse(assigned);
        assertEq(registry.openCases(arb), 0);
        // G2: the deal is NOT a dead end — either party re-arms a fresh case.
        vm.prank(seller);
        e.requestFirstPanel();
        (bool active,,,,,,,) = court.caseOf(address(e));
        assertTrue(active, "fresh first-panel case opened");
    }

    // ─── G1: replaceArbitrator must not re-create the F1 assignment ───────

    function test_G1_replaceOnHighValueDisputed_skipsRegistryAssignment() public {
        GhostEscrowV2CImpl e = _createHv(bytes32(uint256(104)));
        address newArb = vm.addr(0xA9B9);
        _stake(newArb, HV_ARB_STAKE, "new-arb");
        (bytes memory bSig, bytes memory sSig) = _replaceSigs(e, newArb, _deadline());
        e.replaceArbitrator(newArb, _deadline(), bSig, sSig);
        assertEq(e.arbitrator(), newArb);
        (bool assigned,,,,) = registry.assignmentOf(address(e));
        assertFalse(assigned, "replacement must not arm an SLA case on a panel deal");
        assertEq(registry.openCases(newArb), 0);
    }

    // ─── G2 gating ─────────────────────────────────────────────────────────

    function test_G2_requestFirstPanel_gates() public {
        GhostEscrowV2CImpl e = _createHv(bytes32(uint256(105)));
        // A case is already in flight from openDispute — the court rejects.
        vm.prank(buyer);
        vm.expectRevert(bytes("case in flight"));
        e.requestFirstPanel();
        // Non-party can never request.
        vm.warp(block.timestamp + SLA_DURATION + 1);
        court.dismiss(address(e));
        vm.prank(stranger);
        vm.expectRevert(bytes("not party"));
        e.requestFirstPanel();
        // Sub-threshold deals have no panel path.
        GhostEscrowV2CImpl small = _createStd(bytes32(uint256(106)));
        _fundActive(small);
        _openDispute(small);
        vm.prank(buyer);
        vm.expectRevert(bytes("not panel deal"));
        small.requestFirstPanel();
    }

    // ─── F2: the court only serves factory-deployed clones ────────────────

    function test_F2_fakeDealCannotOpenCases() public {
        FakeDeal fake = new FakeDeal();
        vm.expectRevert(bytes("not escrow"));
        fake.callPrepare(court);
        vm.expectRevert(bytes("not escrow"));
        fake.callAppeal(court);
    }

    // ─── F3: drawn panel members are locked until the case is terminal ─────

    function test_F3_panelMembersLockedWhileCaseLive_releasedOnSettle() public {
        _stakeArbEligible();
        _stakePanel();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(107)));
        _fundActive(e);
        _toDrawnAppeal(e);
        (address[3] memory panel, uint8 len) = court.panelOf(address(e));
        assertEq(uint256(len), 3);
        for (uint8 i = 0; i < len; i++) {
            assertEq(registry.openCases(panel[i]), 1, "seated member locked");
            vm.prank(panel[i]);
            vm.expectRevert(bytes("open cases"));
            registry.requestUnbond(1);
        }
        _voteMajority(address(e), 0, AMOUNT); // uphold the 0/AMOUNT ruling
        for (uint8 i = 0; i < len; i++) {
            assertEq(registry.openCases(panel[i]), 0, "released at settle");
        }
    }

    function test_F3_panelReleasedOnDrawnDismiss() public {
        _stakeArbEligible();
        _stakePanel();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(108)));
        _fundActive(e);
        _toDrawnAppeal(e);
        (address[3] memory panel,) = court.panelOf(address(e));
        vm.warp(block.timestamp + SLA_DURATION + 1); // no majority in time
        court.dismiss(address(e));
        for (uint8 i = 0; i < 3; i++) {
            assertEq(registry.openCases(panel[i]), 0, "released at dismiss");
        }
    }

    // ─── F4: the draw list shrinks with stake; dust sybils are priced out ──

    function test_F4_fullUnbondRemovesFromList_restakeReenters() public {
        _stakeArbEligible();
        assertEq(registry.arbCount(), 1);
        vm.prank(arb);
        registry.requestUnbond(STAKE_FOR_AMOUNT);
        vm.warp(block.timestamp + UNBONDING + 1);
        vm.prank(arb);
        registry.withdraw();
        assertEq(registry.arbCount(), 0, "zero-stake arb leaves the draw list");
        assertEq(registry.stakeOf(arb), 0);
        _stakeArbEligible();
        assertEq(registry.arbCount(), 1, "re-stake re-enters");
        assertEq(registry.arbAt(0), arb);
    }

    function test_F4_swapAndPopKeepsListConsistent() public {
        _stake(arb, STAKE_FOR_AMOUNT, "a");
        _stake(p1, PANEL_STAKE, "b");
        _stake(p2, PANEL_STAKE, "c");
        // Remove the MIDDLE entry (p1): last (p2) must take its slot.
        vm.prank(p1);
        registry.requestUnbond(PANEL_STAKE);
        vm.warp(block.timestamp + UNBONDING + 1);
        vm.prank(p1);
        registry.withdraw();
        assertEq(registry.arbCount(), 2);
        assertEq(registry.arbAt(0), arb);
        assertEq(registry.arbAt(1), p2);
    }

    function test_F4_minStakeFloorEnforced() public {
        ArbitratorRegistry minReg = new ArbitratorRegistry(
            IERC20(address(token)), STAKE_MULTIPLE, UNBONDING, SLA_DURATION, SLA_SLASH_BPS, OVERTURN_SLASH_BPS, 50e6
        );
        token.mint(stranger, 100e6);
        vm.startPrank(stranger);
        token.approve(address(minReg), 100e6);
        vm.expectRevert(bytes("below min stake"));
        minReg.stake(1, "dust");
        minReg.stake(50e6, "real"); // exactly the floor is fine
        // Partial unbond may not leave a sub-floor stub in the draw list.
        minReg.stake(50e6, "real"); // top up to 100e6
        vm.expectRevert(bytes("leave min or all"));
        minReg.requestUnbond(60e6); // would leave 40e6 < floor
        minReg.requestUnbond(50e6); // leaves exactly the floor — fine
        vm.stopPrank();
        assertEq(minReg.arbCount(), 1);
    }

    // ─── F5: timeout recovery without the hostile party's signature ────────

    function test_F5_slashRetainsPot_escalatePaysPanel() public {
        _stakeArbEligible();
        _stakePanel();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(109)));
        _fundActive(e);
        _openDispute(e);
        vm.warp(block.timestamp + SLA_DURATION + 1);
        e.slashForTimeout();
        assertEq(e.arbitratorFeePot(), ARB_FEE, "pot retained for the panel");
        assertEq(e.timeoutSlashedArb(), arb);

        // The SELLER alone (buyer opened; assume buyer goes hostile) escalates.
        vm.prank(seller);
        e.escalateAfterTimeout();
        // Opener cannot yank the pot while the case is live.
        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer);
        vm.expectRevert(bytes("case in flight"));
        e.claimStrandedPot();

        (,,,,,, uint256 drawBlock,) = court.caseOf(address(e));
        vm.roll(block.number + (drawBlock - block.number) + 1);
        court.drawPanel(address(e));
        (address[3] memory panel,) = court.panelOf(address(e));
        uint256 before0 = token.balanceOf(panel[0]);
        _voteMajority(address(e), AMOUNT, 0); // panel rules 100% buyer
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.RuledPendingAppeal));
        assertEq(e.arbitratorFeePot(), 0, "pot paid to the panel");
        assertEq(token.balanceOf(panel[0]) - before0, ARB_FEE / 3 + (ARB_FEE - (ARB_FEE / 3) * 3));
    }

    function test_F5_escalateOnlyParties_andOnlyAfterSlash() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(110)));
        _fundActive(e);
        _openDispute(e);
        vm.prank(buyer);
        vm.expectRevert(bytes("arb set")); // no slash yet
        e.escalateAfterTimeout();
        vm.warp(block.timestamp + SLA_DURATION + 1);
        e.slashForTimeout();
        vm.prank(stranger);
        vm.expectRevert(bytes("not party"));
        e.escalateAfterTimeout();
    }

    // ─── F6: syncDeposit is buyer-only; stray transfers stay un-credited ───

    function test_F6_syncDepositBuyerOnly_strayNotPaidToBuyer() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(111)));
        _fund(seller, 777e6);
        vm.prank(seller);
        token.transfer(address(e), 777e6); // mistaken direct transfer
        vm.prank(seller);
        vm.expectRevert(bytes("not buyer"));
        e.syncDeposit();
        // Expiry must NOT hand the seller's stray tokens to the buyer.
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        uint256 buyerBefore = token.balanceOf(buyer);
        e.expire();
        assertEq(token.balanceOf(buyer), buyerBefore, "stray transfer not converted to buyer credit");
        assertEq(token.balanceOf(address(e)), 777e6, "stray funds recoverable via mutual rescueToken");
    }

    // ─── F7: threshold is per-deployment, not hardcoded ────────────────────

    function test_F7_thresholdImmutableAndGuarded() public {
        assertEq(stdImpl.HIGH_VALUE_THRESHOLD(), 25_000e6);
        assertEq(openImpl.HIGH_VALUE_THRESHOLD(), 25_000e6);
        vm.expectRevert(bytes("zero threshold"));
        new GhostEscrowV2CImpl(address(factory), registry, 0);
    }
}
