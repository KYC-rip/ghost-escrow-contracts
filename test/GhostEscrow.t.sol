// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";

/// @dev Deployment invariants, immutables, deposit paths, and the state machine.
contract GhostEscrowTest is GhostTestBase {
    // ─── Deployment ───────────────────────────────────────────────────────

    function test_Deployment_SetsImmutables() public {
        assertEq(address(escrow.token()), address(token));
        assertEq(escrow.buyer(), buyer);
        assertEq(escrow.seller(), seller);
        assertEq(escrow.arbitrator(), arb);
        assertEq(escrow.feeRecipient(), feeRecipient);
        assertEq(escrow.dealAmount(), AMOUNT);
        assertEq(escrow.platformFeeBps(), FEE_BPS);
        assertEq(escrow.arbitratorFee(), ARB_FEE);
        assertEq(escrow.depositDeadline(), block.timestamp + DEPOSIT_TIMEOUT);
        assertEq(escrow.autoReleaseDelay(), AUTO_RELEASE);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Created));
        assertEq(escrow.deposited(), 0);
        assertEq(escrow.nonce(), 0);
    }

    function test_Deployment_RejectsZeroAddresses() public {
        vm.expectRevert("zero addr");
        new GhostEscrow(
            address(0), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
        vm.expectRevert("zero addr");
        new GhostEscrow(
            address(token),
            address(0),
            seller,
            arb,
            feeRecipient,
            AMOUNT,
            FEE_BPS,
            ARB_FEE,
            DEPOSIT_TIMEOUT,
            AUTO_RELEASE
        );
        vm.expectRevert("zero addr");
        new GhostEscrow(
            address(token),
            buyer,
            address(0),
            arb,
            feeRecipient,
            AMOUNT,
            FEE_BPS,
            ARB_FEE,
            DEPOSIT_TIMEOUT,
            AUTO_RELEASE
        );
        vm.expectRevert("zero addr");
        new GhostEscrow(
            address(token),
            buyer,
            seller,
            address(0),
            feeRecipient,
            AMOUNT,
            FEE_BPS,
            ARB_FEE,
            DEPOSIT_TIMEOUT,
            AUTO_RELEASE
        );
        vm.expectRevert("zero addr");
        new GhostEscrow(
            address(token), buyer, seller, arb, address(0), AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function test_Deployment_RejectsSameParty() public {
        vm.expectRevert("same party");
        new GhostEscrow(
            address(token), buyer, buyer, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function test_Deployment_RejectsZeroAmount() public {
        vm.expectRevert("zero amount");
        new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, 0, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function test_Deployment_RejectsFeeOver10Percent() public {
        vm.expectRevert("fee too high");
        new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, 1001, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function test_Deployment_RejectsOutOfRangeAutoRelease() public {
        vm.expectRevert("bad auto-release");
        new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, 0.5 days
        );
        vm.expectRevert("bad auto-release");
        new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, 91 days
        );
    }

    function test_Deployment_AcceptsBoundaryAutoRelease() public {
        GhostEscrow min =
            _deployEscrowFull(address(token), buyer, seller, arb, AMOUNT, ARB_FEE, DEPOSIT_TIMEOUT, 1 days);
        GhostEscrow max =
            _deployEscrowFull(address(token), buyer, seller, arb, AMOUNT, ARB_FEE, DEPOSIT_TIMEOUT, 90 days);
        assertEq(min.autoReleaseDelay(), 1 days);
        assertEq(max.autoReleaseDelay(), 90 days);
    }

    // ─── Deposit ──────────────────────────────────────────────────────────

    function test_Deposit_ExactAmountGoesActive() public {
        _fund(buyer, AMOUNT);
        _approveDeposit(buyer, AMOUNT);
        _deposit(buyer, AMOUNT);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(escrow.deposited(), AMOUNT);
        assertEq(escrow.depositedBy(buyer), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(escrow.autoReleaseDeadline(), block.timestamp + AUTO_RELEASE);
    }

    function test_Deposit_PartialGoesPartiallyDeposited() public {
        _fund(buyer, AMOUNT);
        _approveDeposit(buyer, AMOUNT);
        _deposit(buyer, AMOUNT / 2);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.PartiallyDeposited));
        assertEq(escrow.deposited(), AMOUNT / 2);
        assertEq(escrow.autoReleaseDeadline(), 0);
    }

    function test_Deposit_OvershootRefundsExcess() public {
        _fund(buyer, AMOUNT + 500e6);
        _approveDeposit(buyer, AMOUNT + 500e6);
        _deposit(buyer, AMOUNT + 500e6);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(escrow.deposited(), AMOUNT);
        assertEq(token.balanceOf(buyer), 500e6); // excess returned in-tx
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(escrow.depositedBy(buyer), AMOUNT);
    }

    function test_Deposit_AnyoneCanFund() public {
        _fund(stranger, AMOUNT);
        _approveDeposit(stranger, AMOUNT);
        _deposit(stranger, AMOUNT);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(escrow.depositedBy(stranger), AMOUNT);
    }

    function test_Deposit_ZeroAmountReverts() public {
        _fund(buyer, AMOUNT);
        _approveDeposit(buyer, AMOUNT);
        vm.expectRevert(bytes("zero"));
        _deposit(buyer, 0);
    }

    function test_Deposit_AfterDeadlineReverts() public {
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        _fund(buyer, AMOUNT);
        _approveDeposit(buyer, AMOUNT);
        vm.expectRevert("deposit window closed");
        _deposit(buyer, AMOUNT);
    }

    function test_Deposit_FromNonActiveStateReverts() public {
        _fundActive();
        _fund(seller, AMOUNT);
        _approveDeposit(seller, AMOUNT);
        vm.expectRevert("bad state");
        _deposit(seller, AMOUNT);
    }

    function test_Deposit_NoApprovalReverts() public {
        _fund(buyer, AMOUNT);
        vm.expectRevert();
        _deposit(buyer, AMOUNT);
    }

    function test_Deposit_FeeOnTransferCreditsByDelta() public {
        token.setFeeOnTransfer(100); // 1% fee, burned
        _fund(buyer, AMOUNT);
        _approveDeposit(buyer, AMOUNT);
        _deposit(buyer, AMOUNT);
        uint256 credited = AMOUNT - (AMOUNT * 100) / 10_000;
        assertEq(escrow.deposited(), credited);
        assertEq(escrow.depositedBy(buyer), credited);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.PartiallyDeposited));
        assertEq(token.balanceOf(address(escrow)), credited);
    }

    function test_Deposit_FeeOnTransferCanStillReachActive() public {
        token.setFeeOnTransfer(100);
        uint256 send = (AMOUNT * 100) / 99; // credited == AMOUNT exactly after 1% burn
        _fund(buyer, send);
        _approveDeposit(buyer, send);
        _deposit(buyer, send);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(escrow.deposited(), AMOUNT);
    }

    function test_Deposit_FoTExcessRefundGoesToDepositor() public {
        token.setFeeOnTransfer(100);
        uint256 send = AMOUNT + 500e6;
        uint256 credited = send - (send * 100) / 10_000;
        uint256 excess = credited - AMOUNT;
        _fund(buyer, send);
        _approveDeposit(buyer, send);
        _deposit(buyer, send);
        assertEq(escrow.deposited(), AMOUNT);
        // The excess refund transfer itself carries the FoT fee (burned).
        assertEq(token.balanceOf(buyer), excess - (excess * 100) / 10_000);
        assertEq(escrow.depositedBy(buyer), AMOUNT);
    }

    function test_SyncDeposit_CreditsDirectTransferToBuyer() public {
        token.mint(address(escrow), AMOUNT); // e.g. XMR->USDC swap paid in directly
        escrow.syncDeposit();
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(escrow.deposited(), AMOUNT);
        assertEq(escrow.depositedBy(buyer), AMOUNT);
    }

    function test_SyncDeposit_PartialThenDeposit() public {
        token.mint(address(escrow), AMOUNT / 2);
        escrow.syncDeposit();
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.PartiallyDeposited));
        _fund(seller, AMOUNT / 2);
        _approveDeposit(seller, AMOUNT / 2);
        _deposit(seller, AMOUNT / 2);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
        assertEq(escrow.depositedBy(buyer), AMOUNT / 2);
        assertEq(escrow.depositedBy(seller), AMOUNT / 2);
    }

    function test_SyncDeposit_OvershootRefundsExcessToBuyer() public {
        token.mint(address(escrow), AMOUNT + 700e6);
        escrow.syncDeposit();
        assertEq(escrow.deposited(), AMOUNT);
        assertEq(token.balanceOf(buyer), 700e6);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
    }

    function test_SyncDeposit_NothingToSyncReverts() public {
        vm.expectRevert("nothing to sync");
        escrow.syncDeposit();
    }

    function test_SyncDeposit_AfterDeadlineReverts() public {
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        token.mint(address(escrow), AMOUNT);
        vm.expectRevert("deposit window closed");
        escrow.syncDeposit();
    }

    function test_SyncDeposit_FoTDirectTransferCreditsDelta() public {
        token.setFeeOnTransfer(100);
        // Simulate the real path: a swap transfers AMOUNT into the escrow
        // address; the FoT burn happens on that transfer, not on mint.
        token.mint(stranger, AMOUNT);
        vm.prank(stranger);
        token.transfer(address(escrow), AMOUNT);
        uint256 received = AMOUNT - (AMOUNT * 100) / 10_000;
        escrow.syncDeposit();
        assertEq(escrow.deposited(), received);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.PartiallyDeposited));
    }

    // ─── State machine ────────────────────────────────────────────────────

    function test_StateMachine_IllegalActionsInCreated() public {
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        vm.expectRevert("bad state");
        escrow.release(_deadline(), bSig, sSig);

        (bSig, sSig) = _refundSigs(0, _deadline());
        vm.expectRevert("bad state");
        escrow.refund(_deadline(), bSig, sSig);

        (bSig, sSig) = _splitSigs(AMOUNT / 2, 0, _deadline());
        vm.expectRevert("bad state");
        escrow.mutualSplit(AMOUNT / 2, _deadline(), bSig, sSig);

        vm.expectRevert("not active");
        vm.prank(buyer);
        escrow.openDispute();

        vm.expectRevert("not active");
        escrow.autoRelease();
    }

    function test_StateMachine_IllegalActionsInPartiallyDeposited() public {
        _fund(buyer, AMOUNT / 2);
        _approveDeposit(buyer, AMOUNT / 2);
        _deposit(buyer, AMOUNT / 2);

        vm.expectRevert("not active");
        vm.prank(buyer);
        escrow.openDispute();

        vm.expectRevert("not active");
        escrow.autoRelease();

        vm.expectRevert("too early");
        escrow.expire();
    }

    function test_StateMachine_IllegalActionsInActive() public {
        _fundActive();

        vm.expectRevert("bad state");
        _deposit(buyer, 1e6);

        vm.expectRevert("bad state");
        escrow.expire();

        // openDispute from buyer is legal; from a non-party it reverts
        vm.expectRevert("not party");
        vm.prank(stranger);
        escrow.openDispute();
    }

    function test_StateMachine_IllegalActionsInDisputed() public {
        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();

        vm.expectRevert("bad state");
        _deposit(buyer, 1e6);

        vm.expectRevert("not active");
        escrow.autoRelease();

        vm.expectRevert("not active");
        vm.prank(buyer);
        escrow.openDispute();

        vm.expectRevert("bad state");
        escrow.expire();
    }

    function test_StateMachine_TerminalStatesRejectEverything() public {
        // Completed
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        escrow.release(_deadline(), bSig, sSig);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Completed));
        vm.expectRevert("bad state");
        escrow.expire();
        vm.expectRevert("not active");
        escrow.autoRelease();
        vm.expectRevert("not active");
        vm.prank(buyer);
        escrow.openDispute();
        vm.expectRevert("bad state");
        _deposit(buyer, 1e6);

        // Cancelled
        GhostEscrow escrow2 = _deployEscrow();
        vm.prank(buyer);
        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(escrow2), AMOUNT);
        vm.prank(buyer);
        escrow2.deposit(AMOUNT);
        (bSig, sSig) = _refundSigsFor(escrow2, 0, _deadline());
        escrow2.refund(_deadline(), bSig, sSig);
        assertEq(uint256(escrow2.state()), uint256(GhostEscrow.State.Cancelled));
        vm.expectRevert("bad state");
        escrow2.expire();
        vm.expectRevert("not active");
        escrow2.autoRelease();
        vm.expectRevert("not active");
        vm.prank(seller);
        escrow2.openDispute();
    }

    function _refundSigsFor(GhostEscrow e, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory, bytes memory)
    {
        // Local helper: re-target signatures at a specific escrow instance.
        bytes32 d =
            _digestFor(e, keccak256(abi.encode(keccak256("Refund(uint256 nonce,uint256 deadline)"), nonce, deadline)));
        return (_sig(buyerPk, d), _sig(sellerPk, d));
    }

    function _digestFor(GhostEscrow e, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("GhostEscrow"),
                keccak256("1"),
                chainId,
                address(e)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
