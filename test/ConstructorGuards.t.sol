// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";

/// @dev Constructor hardening (Claude M1 findings 1–2):
///      - arbitrator must not be a party (was accepted before the fix)
///      - deposit timeout bounded [1h, 30d] like autoReleaseDelay
contract ConstructorGuardsTest is GhostTestBase {
    function _construct(address arb_) internal returns (GhostEscrow) {
        return new GhostEscrow(
            address(token), buyer, seller, arb_, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function test_Constructor_RevertsWhenArbitratorIsBuyer() public {
        vm.expectRevert(bytes("bad arb"));
        _construct(buyer);
    }

    function test_Constructor_RevertsWhenArbitratorIsSeller() public {
        vm.expectRevert(bytes("bad arb"));
        _construct(seller);
    }

    function test_Constructor_AcceptsIndependentArbitrator() public {
        GhostEscrow e = _construct(arb);
        assertEq(e.arbitrator(), arb);
    }

    function test_Constructor_RevertsWhenDepositTimeoutZero() public {
        vm.expectRevert(bytes("bad deposit timeout"));
        new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 0, AUTO_RELEASE
        );
    }

    function test_Constructor_RevertsWhenDepositTimeoutTooLong() public {
        vm.expectRevert(bytes("bad deposit timeout"));
        new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 31 days, AUTO_RELEASE
        );
    }

    function test_Constructor_AcceptsBoundaryDepositTimeouts() public {
        GhostEscrow minE = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 1 hours, AUTO_RELEASE
        );
        assertEq(minE.depositDeadline(), block.timestamp + 1 hours);
        GhostEscrow maxE = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 30 days, AUTO_RELEASE
        );
        assertEq(maxE.depositDeadline(), block.timestamp + 30 days);
    }
}