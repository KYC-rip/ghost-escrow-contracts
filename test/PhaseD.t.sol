// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GhostTestBaseD, MockSequentialTemplate} from "./utils/GhostTestBaseD.sol";
import {GhostEscrowV2CImpl} from "../src/GhostEscrowV2CImpl.sol";
import {GhostEscrowV2OpenCImpl} from "../src/GhostEscrowV2OpenCImpl.sol";
import {EscrowCloneFactory} from "../src/EscrowCloneFactory.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// Phase D — clone factory + template registry + court sequential cases.
contract PhaseDFactoryTest is GhostTestBaseD {
    // ─── Template curation ───────────────────────────────────────────────────

    function test_addTemplate_curatorOnly() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not curator"));
        factory.addTemplate(address(0x1234));
    }

    function test_addTemplate_requiresCode() public {
        vm.expectRevert(bytes("no code"));
        factory.addTemplate(address(0x1234)); // EOA / empty
    }

    function test_addTemplate_appendOnly_noDoubleList() public {
        vm.expectRevert(bytes("listed"));
        factory.addTemplate(address(stdImpl)); // already added in setUp
    }

    function test_templateCount_andList() public view {
        assertEq(factory.templateCount(), 2);
        assertEq(factory.templateList(0), address(stdImpl));
        assertEq(factory.templateList(1), address(openImpl));
    }

    function test_renounceCurator_freezesList() public {
        factory.renounceCurator();
        assertEq(factory.curator(), address(0));
        vm.expectRevert(bytes("not curator"));
        factory.addTemplate(address(this));
    }

    function test_renounceCurator_onlyCurator() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not curator"));
        factory.renounceCurator();
    }

    function test_activationTimelock_gatesCreate() public {
        // Fresh factory with a 48h delay; templates unusable until it elapses.
        EscrowCloneFactory delayed = new EscrowCloneFactory(registry, feeRecipient, FEE_BPS, 48 hours, address(this));
        GhostEscrowV2CImpl impl = new GhostEscrowV2CImpl(address(delayed), registry, 25_000e6);
        delayed.addTemplate(address(impl));
        _stakeArbEligible();
        vm.expectRevert(bytes("template not active"));
        delayed.createDeal(address(impl), _initData(buyer, seller), bytes32(uint256(1)));
        vm.warp(block.timestamp + 48 hours);
        // Activation reached — creation proceeds (registry not bound to this
        // factory, so init-time view checks still pass: isEligible + court are
        // registry-level views independent of the factory binding).
        address deal = delayed.createDeal(address(impl), _initData(buyer, seller), bytes32(uint256(1)));
        assertTrue(delayed.isEscrow(deal));
    }

    function test_createDeal_unknownTemplateReverts() public {
        vm.expectRevert(bytes("unknown template"));
        factory.createDeal(address(this), _initData(buyer, seller), bytes32(0));
    }

    // ─── Address binding (salt commits impl + terms) ─────────────────────────

    function test_predict_matches_create_bothTemplates() public {
        _stakeArbEligible();
        bytes memory dStd = _initData(buyer, seller);
        address predictedStd = factory.predictAddress(address(stdImpl), dStd, bytes32(uint256(7)));
        address dealStd = factory.createDeal(address(stdImpl), dStd, bytes32(uint256(7)));
        assertEq(predictedStd, dealStd);

        bytes memory dOpen = _initData(buyer, address(0)); // seller-open
        address predictedOpen = factory.predictAddress(address(openImpl), dOpen, bytes32(uint256(8)));
        address dealOpen = factory.createDeal(address(openImpl), dOpen, bytes32(uint256(8)));
        assertEq(predictedOpen, dealOpen);
        assertEq(factory.implementationOf(dealStd), address(stdImpl));
        assertEq(factory.implementationOf(dealOpen), address(openImpl));
    }

    function test_salt_commitsToTermsAndTemplate() public {
        bytes memory d1 = _initData(buyer, seller);
        bytes memory d2 = _initData(buyer, stranger); // one field differs
        bytes32 us = bytes32(uint256(42));
        address a1 = factory.predictAddress(address(stdImpl), d1, us);
        address a2 = factory.predictAddress(address(stdImpl), d2, us);
        address a3 = factory.predictAddress(address(openImpl), d1, us);
        assertTrue(a1 != a2); // different terms → different address
        assertTrue(a1 != a3); // different template → different address
    }

    function test_replay_sameSaltReverts() public {
        _stakeArbEligible();
        bytes memory d = _initData(buyer, seller);
        factory.createDeal(address(stdImpl), d, bytes32(uint256(9)));
        vm.expectRevert(); // CREATE2 collision — clone already deployed
        factory.createDeal(address(stdImpl), d, bytes32(uint256(9)));
    }

    // ─── Initialize safety ───────────────────────────────────────────────────

    function test_initialize_factoryOnly() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(10)));
        vm.prank(stranger);
        vm.expectRevert(bytes("not factory"));
        e.initialize(feeRecipient, FEE_BPS, _initData(buyer, seller));
    }

    function test_initialize_onceOnly_evenFromFactory() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(11)));
        vm.prank(address(factory));
        vm.expectRevert(bytes("initialized"));
        e.initialize(feeRecipient, FEE_BPS, _initData(buyer, seller));
    }

    function test_bareImplementation_locked() public {
        vm.prank(address(factory));
        vm.expectRevert(bytes("initialized"));
        stdImpl.initialize(feeRecipient, FEE_BPS, _initData(buyer, seller));
        vm.prank(address(factory));
        vm.expectRevert(bytes("initialized"));
        openImpl.initialize(feeRecipient, FEE_BPS, _initData(buyer, address(0)));
    }

    function test_initialize_enforcesEligibility() public {
        // arb NOT staked → template-side §5.1-C gate reverts the whole create.
        vm.expectRevert(bytes("arb not eligible"));
        factory.createDeal(address(stdImpl), _initData(buyer, seller), bytes32(uint256(12)));
    }

    function test_initialize_enforcesCourtBound() public {
        // Fresh registry with NO court bound; fresh factory+impl on it.
        ArbitratorRegistry reg2 = new ArbitratorRegistry(
            IERC20(address(token)), STAKE_MULTIPLE, UNBONDING, SLA_DURATION, SLA_SLASH_BPS, OVERTURN_SLASH_BPS, 0, address(this)
        );
        EscrowCloneFactory f2 = new EscrowCloneFactory(reg2, feeRecipient, FEE_BPS, 0, address(this));
        GhostEscrowV2CImpl impl2 = new GhostEscrowV2CImpl(address(f2), reg2, 25_000e6);
        f2.addTemplate(address(impl2));
        reg2.setFactory(address(f2));
        _fund(arb, STAKE_FOR_AMOUNT);
        vm.startPrank(arb);
        token.approve(address(reg2), STAKE_FOR_AMOUNT);
        reg2.stake(STAKE_FOR_AMOUNT, "pk");
        vm.stopPrank();
        vm.expectRevert(bytes("no court"));
        f2.createDeal(address(impl2), _initData(buyer, seller), bytes32(uint256(13)));
    }

    function test_initialize_badTermsRevert() public {
        _stakeArbEligible();
        bytes memory sameParty = abi.encode(
            address(token), buyer, buyer, arb, AMOUNT, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
        vm.expectRevert(bytes("same party"));
        factory.createDeal(address(stdImpl), sameParty, bytes32(uint256(14)));
    }
}

/// Full lifecycle on standard-template clones (uphold + overturn + hooks + 712).
contract PhaseDLifecycleTest is GhostTestBaseD {
    function _settled(GhostEscrowV2CImpl e) internal view returns (bool) {
        return uint256(e.state()) == uint256(GhostEscrowV2CImpl.State.Completed);
    }

    function test_clone_depositLifecycle_andHooks() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(20)));
        _fundActive(e);
        assertEq(token.balanceOf(address(e)), AMOUNT);
        _openDispute(e);
        assertEq(registry.openCases(arb), 1); // hook authenticated via factory.isEscrow(clone)
        vm.prank(arb);
        e.rule(0, AMOUNT, keccak256("r"));
        assertEq(registry.openCases(arb), 0);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.RuledPendingAppeal));
    }

    function test_clone_eip712_mutualRelease_domainIsClone() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(21)));
        _fundActive(e);
        uint256 dl = _deadline();
        // SigUtils computes the domain from the DEAL (clone) address — proves the
        // OZ EIP712 base rebuilds the separator per clone (not the impl address).
        bytes32 d = SigUtils.releaseDigest(address(e), chainId, e.nonce(), dl);
        e.release(dl, _sig(buyerPk, d), _sig(sellerPk, d));
        assertTrue(_settled(e));
        assertEq(token.balanceOf(seller), AMOUNT - (AMOUNT * FEE_BPS) / 10000);
    }

    function test_clone_appeal_uphold_bondToPanel() public {
        _stakeArbEligible();
        _stakePanel();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(22)));
        _fundActive(e);
        uint256 bond = _toDrawnAppeal(e);
        (address[3] memory panel, uint8 len) = court.panelOf(address(e));
        assertEq(len, 3);
        // 2/3 vote the EXACT original split → uphold.
        vm.prank(panel[0]);
        court.vote(address(e), 0, AMOUNT, keccak256("v1"));
        uint256 p1Before = token.balanceOf(panel[0]);
        vm.prank(panel[1]);
        court.vote(address(e), 0, AMOUNT, keccak256("v2"));
        assertTrue(_settled(e));
        // bond split to panel, dust to member 0
        assertEq(token.balanceOf(panel[0]) - p1Before, bond / 3 + (bond - (bond / 3) * 3));
        // seller got the ruled amount minus fee; arb kept the fee pot
        assertEq(token.balanceOf(seller), AMOUNT - (AMOUNT * FEE_BPS) / 10000);
        assertEq(token.balanceOf(arb), ARB_FEE);
    }

    function test_clone_appeal_overturn_slashAndMakeWhole() public {
        _stakeArbEligible();
        _stakePanel();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(23)));
        _fundActive(e);
        uint256 bond = _toDrawnAppeal(e);
        (address[3] memory panel,) = court.panelOf(address(e));
        uint256 arbStakeBefore = registry.stakeOf(arb);
        uint256 buyerBefore = token.balanceOf(buyer);
        // 2/3 vote a DIFFERENT split (all to buyer) → overturn.
        vm.prank(panel[0]);
        court.vote(address(e), AMOUNT, 0, keccak256("o1"));
        vm.prank(panel[1]);
        court.vote(address(e), AMOUNT, 0, keccak256("o2"));
        assertTrue(_settled(e));
        // original arb slashed 50%
        assertEq(registry.stakeOf(arb), arbStakeBefore - (arbStakeBefore * OVERTURN_SLASH_BPS) / 10000);
        // appellant (buyer): ruled amount minus fee + bond refund + fee pot
        uint256 expected = (AMOUNT - (AMOUNT * FEE_BPS) / 10000) + bond + ARB_FEE;
        assertEq(token.balanceOf(buyer) - buyerBefore, expected);
    }

    function test_clone_slaTimeout_slash() public {
        _stakeArbEligible();
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(24)));
        _fundActive(e);
        _openDispute(e);
        vm.warp(block.timestamp + SLA_DURATION + 1);
        uint256 buyerBefore = token.balanceOf(buyer);
        e.slashForTimeout();
        assertEq(e.arbitrator(), address(0));
        // F5: opener is compensated by the slash ONLY — the fee pot is retained
        // to pay an escalation panel (claimStrandedPot returns it after 30d).
        assertEq(token.balanceOf(buyer) - buyerBefore, (STAKE_FOR_AMOUNT * SLA_SLASH_BPS) / 10000);
        assertEq(e.arbitratorFeePot(), ARB_FEE);
        assertEq(e.timeoutSlashedArb(), arb);
        assertEq(registry.openCases(arb), 0);
        // The stranded-pot valve: too early until 30d pass, then opener reclaims.
        vm.prank(buyer);
        vm.expectRevert(bytes("too early"));
        e.claimStrandedPot();
        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer);
        e.claimStrandedPot();
        assertEq(token.balanceOf(buyer) - buyerBefore, (STAKE_FOR_AMOUNT * SLA_SLASH_BPS) / 10000 + ARB_FEE);
    }
}

/// Open-template (deploy-then-join) on clones.
contract PhaseDOpenTest is GhostTestBaseD {
    function _openInitData(bool creatorIsBuyer) internal view returns (bytes memory) {
        return creatorIsBuyer ? _initData(buyer, address(0)) : _initData(address(0), seller);
    }

    function _joinDigest(address deal, uint256 deadline, address joiner) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(keccak256("Join(address deal,uint256 deadline,address joiner)"), deal, deadline, joiner)
        );
        return SigUtils.digest(deal, chainId, structHash);
    }

    function test_open_sellerOpen_joinWithInvite() public {
        _stakeArbEligible();
        address deal = factory.createDeal(address(openImpl), _openInitData(true), bytes32(uint256(30)));
        GhostEscrowV2OpenCImpl e = GhostEscrowV2OpenCImpl(deal);
        assertEq(e.creator(), buyer);
        assertTrue(e.creatorIsBuyer());
        uint256 dl = block.timestamp + 24 hours;
        bytes memory inviteSig = _sig(buyerPk, _joinDigest(deal, dl, address(0)));
        vm.prank(seller);
        e.join(dl, address(0), inviteSig);
        assertTrue(e.joined());
        assertEq(e.seller(), seller);
    }

    function test_open_buyerOpen_mustFullyFund() public {
        _stakeArbEligible();
        address deal = factory.createDeal(address(openImpl), _openInitData(false), bytes32(uint256(31)));
        GhostEscrowV2OpenCImpl e = GhostEscrowV2OpenCImpl(deal);
        uint256 dl = block.timestamp + 24 hours;
        bytes memory inviteSig = _sig(sellerPk, _joinDigest(deal, dl, address(0)));
        _fund(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(deal, AMOUNT);
        // OPEN-CR-1: partial funding reverts
        vm.expectRevert(bytes("must fully fund"));
        e.joinAndDeposit(dl, address(0), inviteSig, AMOUNT / 2);
        e.joinAndDeposit(dl, address(0), inviteSig, AMOUNT);
        vm.stopPrank();
        assertEq(uint256(e.state()), uint256(GhostEscrowV2OpenCImpl.State.Active));
        assertEq(e.buyer(), buyer);
    }

    function test_open_cancelUnjoined_sweeps() public {
        _stakeArbEligible();
        address deal = factory.createDeal(address(openImpl), _openInitData(true), bytes32(uint256(32)));
        GhostEscrowV2OpenCImpl e = GhostEscrowV2OpenCImpl(deal);
        token.mint(deal, 77e6); // stray pre-join transfer
        uint256 before = token.balanceOf(buyer);
        vm.prank(buyer);
        e.cancelUnjoined();
        assertEq(token.balanceOf(buyer) - before, 77e6);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2OpenCImpl.State.Cancelled));
    }
}

/// Court sequential cases (D-REV-1) — driven by a registered mock "future
/// template", which also proves the addTemplate release path end-to-end.
contract PhaseDSequentialCourtTest is GhostTestBaseD {
    MockSequentialTemplate internal seqImpl;
    MockSequentialTemplate internal seqDeal;
    uint256 internal constant BOND = 100e6;

    function setUp() public override {
        super.setUp();
        _stakeArbEligible();
        _stakePanel();
        seqImpl = new MockSequentialTemplate(address(factory), registry);
        factory.addTemplate(address(seqImpl)); // the future-template release path
        seqDeal = MockSequentialTemplate(
            factory.createDeal(address(seqImpl), _initData(buyer, seller), bytes32(uint256(40)))
        );
        token.mint(address(seqDeal), BOND * 10); // bonds for several rounds
    }

    function _runCase(uint256 voteB, uint256 voteS) internal {
        seqDeal.openAppealCase(buyer, BOND, 0, AMOUNT);
        (,,,,,, uint256 drawBlock,) = court.caseOf(address(seqDeal));
        vm.roll(drawBlock + 1);
        court.drawPanel(address(seqDeal));
        (address[3] memory panel,) = court.panelOf(address(seqDeal));
        vm.prank(panel[0]);
        court.vote(address(seqDeal), voteB, voteS, keccak256("s1"));
        vm.prank(panel[1]);
        court.vote(address(seqDeal), voteB, voteS, keccak256("s2"));
    }

    function test_sequentialCases_afterSettledDrawnCase() public {
        _runCase(0, AMOUNT); // case 1: uphold (matches orig 0/AMOUNT)
        assertEq(seqDeal.upholds(), 1);
        (bool active,,, bool settled,,,,) = court.caseOf(address(seqDeal));
        assertTrue(settled);
        assertFalse(active);

        // Case 2 for the SAME deal — must open cleanly with a full slot reset.
        _runCase(AMOUNT, 0); // overturn (differs from orig)
        assertEq(seqDeal.overturns(), 1);
        assertEq(seqDeal.lastBuyerAmount(), AMOUNT);
    }

    function test_sequentialCases_fullStateReset() public {
        _runCase(0, AMOUNT);
        seqDeal.openAppealCase(seller, BOND, 0, AMOUNT); // case 2 requested
        (bool active, bool isAppeal, bool drawn, bool settled, address challenger, uint256 bond,,) =
            court.caseOf(address(seqDeal));
        assertTrue(active && isAppeal);
        assertFalse(drawn); // prior case's drawn flag did NOT bleed through
        assertFalse(settled);
        assertEq(challenger, seller); // case-2 challenger, not case-1's
        assertEq(bond, BOND);
        (, uint8 panelLen) = court.panelOf(address(seqDeal));
        assertEq(panelLen, 0); // prior panel cleared
    }

    function test_inFlightCase_blocksNewRequest() public {
        seqDeal.openAppealCase(buyer, BOND, 0, AMOUNT);
        vm.expectRevert(bytes("case in flight"));
        seqDeal.openAppealCase(seller, BOND, 0, AMOUNT);
    }

    function test_drawnInFlight_blocksNewRequest() public {
        seqDeal.openAppealCase(buyer, BOND, 0, AMOUNT);
        (,,,,,, uint256 drawBlock,) = court.caseOf(address(seqDeal));
        vm.roll(drawBlock + 1);
        court.drawPanel(address(seqDeal));
        vm.expectRevert(bytes("case in flight"));
        seqDeal.openAppealCase(seller, BOND, 0, AMOUNT);
    }

    function test_perCaseBondAccounting_isolated() public {
        (address[3] memory panelBefore,) = court.panelOf(address(seqDeal));
        panelBefore; // silence
        uint256 b1 = token.balanceOf(p1);
        _runCase(0, AMOUNT); // uphold → bond to panel (deal token)
        uint256 afterCase1 = token.balanceOf(p1) + token.balanceOf(p2) + token.balanceOf(p3);
        _runCase(0, AMOUNT); // second uphold → SECOND bond to panel, same total again
        uint256 afterCase2 = token.balanceOf(p1) + token.balanceOf(p2) + token.balanceOf(p3);
        assertEq(afterCase2 - afterCase1, BOND); // exactly one bond per case
        b1; // silence
    }

    /// The v2/v2-open templates keep their at-most-one-appeal ESCROW-side gate:
    /// after a settled appeal, the deal is terminal — no second court case can
    /// ever originate from them (state != RuledPendingAppeal blocks appeal()).
    function test_v2Clone_stillAtMostOneAppeal() public {
        GhostEscrowV2CImpl e = _createStd(bytes32(uint256(41)));
        _fundActive(e);
        uint256 bond = _toDrawnAppeal(e);
        bond;
        (address[3] memory panel,) = court.panelOf(address(e));
        vm.prank(panel[0]);
        court.vote(address(e), 0, AMOUNT, keccak256("u"));
        vm.prank(panel[1]);
        court.vote(address(e), 0, AMOUNT, keccak256("u"));
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Completed));
        vm.prank(buyer);
        vm.expectRevert(bytes("not ruled-pending"));
        e.appeal();
    }
}
