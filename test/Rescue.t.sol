// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {MockERC20} from "./utils/MockERC20.sol";

/// @dev rescueToken guard matrix: stray tokens always rescuable; deal token
///      only once fully settled (terminal state, deposited == 0, pot empty).
contract RescueTest is GhostTestBase {
    MockERC20 internal stray;

    function setUp() public override {
        super.setUp();
        stray = new MockERC20("Stray", "STRY", 18);
    }

    function _strayToEscrow(uint256 amt) internal {
        stray.mint(address(escrow), amt);
    }

    // ─── Stray tokens (not the deal token) ────────────────────────────────

    function test_Rescue_StrayTokenFromActive() public {
        _fundActive();
        _strayToEscrow(100e18);
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(stray), buyer, 0, _deadline());
        vm.expectEmit(true, true, true, true, address(escrow));
        emit GhostEscrow.TokenRescued(address(stray), buyer, 100e18);
        escrow.rescueToken(address(stray), buyer, _deadline(), bSig, sSig);
        assertEq(stray.balanceOf(buyer), 100e18);
        assertEq(stray.balanceOf(address(escrow)), 0);
    }

    function test_Rescue_StrayTokenFromDisputed() public {
        _fundActive();
        _strayToEscrow(5e18);
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(stray), seller, 0, _deadline());
        escrow.rescueToken(address(stray), seller, _deadline(), bSig, sSig);
        assertEq(stray.balanceOf(seller), 5e18);
    }

    function test_Rescue_StrayTokenBadDestReverts() public {
        _fundActive();
        _strayToEscrow(1e18);
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(stray), stranger, 0, _deadline());
        vm.expectRevert("bad dest");
        escrow.rescueToken(address(stray), stranger, _deadline(), bSig, sSig);
    }

    // ─── Deal token guard matrix ──────────────────────────────────────────

    function test_Rescue_DealTokenWhileActiveReverts() public {
        _fundActive();
        token.mint(address(escrow), 1e6); // stray dust
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(token), buyer, 0, _deadline());
        vm.expectRevert("deal token not settled");
        escrow.rescueToken(address(token), buyer, _deadline(), bSig, sSig);
    }

    function test_Rescue_DealTokenWhileDisputedReverts() public {
        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(token), buyer, 0, _deadline());
        vm.expectRevert("deal token not settled");
        escrow.rescueToken(address(token), buyer, _deadline(), bSig, sSig);
    }

    function test_Rescue_DealTokenWhilePartiallyDepositedReverts() public {
        _fund(buyer, AMOUNT / 2);
        _approveDeposit(buyer, AMOUNT / 2);
        _deposit(buyer, AMOUNT / 2);
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(token), buyer, 0, _deadline());
        vm.expectRevert("deal token not settled");
        escrow.rescueToken(address(token), buyer, _deadline(), bSig, sSig);
    }

    function test_Rescue_DealTokenDustAfterRelease() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _releaseSigs(0, _deadline());
        escrow.release(_deadline(), bSig, sSig);
        assertEq(escrow.deposited(), 0);
        assertEq(escrow.arbitratorFeePot(), 0);

        token.mint(address(escrow), 123456); // post-settlement dust
        (bSig, sSig) = _rescueSigs(address(token), buyer, 1, _deadline());
        escrow.rescueToken(address(token), buyer, _deadline(), bSig, sSig);
        assertEq(token.balanceOf(buyer), 123456);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Rescue_DealTokenDustAfterRefund() public {
        _fundActive();
        (bytes memory bSig, bytes memory sSig) = _refundSigs(0, _deadline());
        escrow.refund(_deadline(), bSig, sSig);
        token.mint(address(escrow), 99);
        (bSig, sSig) = _rescueSigs(address(token), seller, 1, _deadline());
        escrow.rescueToken(address(token), seller, _deadline(), bSig, sSig);
        assertEq(token.balanceOf(seller), 99);
    }

    function test_Rescue_DealTokenDustAfterExpiry() public {
        _fund(buyer, AMOUNT / 2);
        _approveDeposit(buyer, AMOUNT / 2);
        _deposit(buyer, AMOUNT / 2);
        vm.warp(block.timestamp + DEPOSIT_TIMEOUT + 1);
        escrow.expire();
        assertEq(escrow.deposited(), 0);
        // Buyer's own funds were pushed at expiry; only the dust remains.

        token.mint(address(escrow), 7);
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(token), buyer, 0, _deadline());
        escrow.rescueToken(address(token), buyer, _deadline(), bSig, sSig);
        assertEq(token.balanceOf(buyer), AMOUNT / 2 + 7);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Rescue_DealTokenBlockedWhileFeePotHoldsFunds() public {
        // After a mutual refund from Disputed, pot returns to opener — but guard
        // the case where a pot somehow remains: must still block.
        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(token), buyer, 0, _deadline());
        vm.expectRevert("deal token not settled");
        escrow.rescueToken(address(token), buyer, _deadline(), bSig, sSig);
        // Pot holds ARB_FEE — not settled.
        assertEq(escrow.arbitratorFeePot(), ARB_FEE);
    }

    function test_Rescue_DealTokenDustAfterRuling() public {
        _fundActive();
        _fund(buyer, ARB_FEE);
        _approveDeposit(buyer, ARB_FEE);
        vm.prank(buyer);
        escrow.openDispute();
        vm.prank(arb);
        escrow.rule(AMOUNT, 0, keccak256("r"));
        assertEq(escrow.deposited(), 0);
        assertEq(escrow.arbitratorFeePot(), 0);

        token.mint(address(escrow), 42);
        (bytes memory bSig, bytes memory sSig) = _rescueSigs(address(token), seller, 0, _deadline());
        escrow.rescueToken(address(token), seller, _deadline(), bSig, sSig);
        assertEq(token.balanceOf(seller), 42);
    }
}
