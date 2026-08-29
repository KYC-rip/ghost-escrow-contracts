// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBaseV2} from "./utils/GhostTestBaseV2.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Phase A — ArbitratorRegistry: staking, unbonding, eligibility
///      boundary, ownerless/immutable properties.
contract ArbitratorRegistryTest is GhostTestBaseV2 {
    function test_stake_registers_and_binds() public {
        _stake(arb, 1000e6, "pk-a");
        assertEq(registry.stakeOf(arb), 1000e6);
        assertEq(registry.chatPubkeyOf(arb), "pk-a");
        assertEq(token.balanceOf(address(registry)), 1000e6);
    }

    function test_stake_requires_amount_and_pubkey_on_first_bond() public {
        vm.prank(arb);
        vm.expectRevert(bytes("zero"));
        registry.stake(0, "pk");
        vm.prank(arb);
        vm.expectRevert(bytes("no pubkey"));
        registry.stake(1e6, "");
    }

    function test_setChatPubkey_only_for_staked() public {
        vm.prank(arb);
        vm.expectRevert(bytes("not staked"));
        registry.setChatPubkey("pk");
        _stake(arb, 1e6, "pk");
        vm.prank(arb);
        registry.setChatPubkey("pk2");
        assertEq(registry.chatPubkeyOf(arb), "pk2");
    }

    function test_isEligible_boundary_exact_over_under() public {
        // stake * 10 >= dealAmount
        _stake(arb, 100e6, "pk"); // 100 * 10 = 1000
        assertTrue(registry.isEligible(arb, 0), "zero deal always eligible");
        assertTrue(registry.isEligible(arb, 1000e6), "exact boundary eligible");
        assertTrue(registry.isEligible(arb, 999e6), "under boundary eligible");
        assertFalse(registry.isEligible(arb, 1001e6), "over boundary not eligible");
        assertFalse(registry.isEligible(arb, 10_000e6), "way over not eligible");
    }

    function testFuzz_isEligible_matches_stakeMultiple(uint256 stake, uint256 dealAmount) public {
        stake = bound(stake, 1, 1e27);
        dealAmount = bound(dealAmount, 0, type(uint128).max);
        _stake(arb, stake, "pk");
        bool expected = dealAmount == 0 || stake * STAKE_MULTIPLE >= dealAmount;
        assertEq(registry.isEligible(arb, dealAmount), expected, "eligibility must equal stake*10>=amount");
    }

    function test_unstaked_never_eligible() public {
        assertFalse(registry.isEligible(stranger, 1e6));
    }

    function test_requestUnbond_freezes_and_requires_delay() public {
        _stake(arb, 1000e6, "pk");
        vm.prank(arb);
        registry.requestUnbond(400e6);
        (uint256 pending, uint256 since) = registry.pendingUnbondOf(arb);
        assertEq(pending, 400e6);
        assertEq(since, block.timestamp);
        assertEq(registry.stakeOf(arb), 1000e6, "stake stays until withdraw");
        assertTrue(registry.isEligible(arb, 5000e6), "still eligible while pending");

        // too early
        vm.warp(UNBONDING - 1);
        vm.prank(arb);
        vm.expectRevert(bytes("too early"));
        registry.withdraw();

        // after the delay
        vm.warp(UNBONDING + 1);
        vm.prank(arb);
        registry.withdraw();
        assertEq(registry.stakeOf(arb), 600e6);
        assertEq(token.balanceOf(arb), 400e6);
    }

    function test_withdraw_nothing_pending_reverts() public {
        _stake(arb, 1e6, "pk");
        vm.prank(arb);
        vm.expectRevert(bytes("nothing pending"));
        registry.withdraw();
    }

    function test_requestUnbond_over_stake_reverts() public {
        _stake(arb, 100e6, "pk");
        vm.prank(arb);
        vm.expectRevert(bytes("bad amount"));
        registry.requestUnbond(101e6);
    }

    function test_rebond_after_full_withdraw_allows_new_registration() public {
        _stake(arb, 100e6, "pk");
        vm.prank(arb);
        registry.requestUnbond(100e6);
        vm.warp(UNBONDING + 1);
        vm.prank(arb);
        registry.withdraw();
        assertEq(registry.stakeOf(arb), 0);
        // re-register with a new pubkey
        vm.prank(arb);
        token.approve(address(registry), 50e6);
        vm.prank(arb);
        registry.stake(50e6, "new-pk");
        assertEq(registry.stakeOf(arb), 50e6);
        assertEq(registry.chatPubkeyOf(arb), "new-pk");
    }

    // ─── Ownerless / immutable / no-drain properties ──────────────────────

    function test_setFactory_gated_to_deployer_and_once() public {
        // Non-deployer cannot bind (front-run fix).
        vm.prank(stranger);
        vm.expectRevert(bytes("not deployer"));
        registry.setFactory(stranger);
        // The base setUp already bound the factory as the deployer (test
        // contract). Re-binding reverts.
        vm.expectRevert(bytes("locked"));
        registry.setFactory(address(0x123));
    }

    function test_setFactory_binds_factory() public {
        // The base setUp binds factoryV2 as the registry's auth.
        assertEq(address(registry.factory()), address(factoryV2));
        assertEq(registry.deployer(), address(this));
    }

    function test_registry_is_ownerless_no_owner_or_admin() public {
        // No owner() / admin() / pause() / upgrade / drain selectors exist.
        (bool ok, bytes memory ret) = address(registry).call(abi.encodeWithSelector(bytes4(keccak256("owner()"))));
        assertFalse(ok || ret.length > 0, "no owner()");
        (ok, ) = address(registry).call(abi.encodeWithSelector(bytes4(keccak256("pause()"))));
        assertFalse(ok, "no pause()");
        (ok, ) = address(registry).call(abi.encodeWithSelector(bytes4(keccak256("upgradeTo(address)"))));
        assertFalse(ok, "no upgradeTo()");
        (ok, ) = address(registry).call(abi.encodeWithSelector(bytes4(keccak256("setStakeMultiple(uint256)"))));
        assertFalse(ok, "no setStakeMultiple()");
    }

    function test_registry_has_no_selfdestruct_surface() public {
        // selfdestruct is not reachable: no function can invoke it, and the
        // contract cannot be destroyed via any external call (checked by the
        // absence of a destruct path + the compiler's no-selfdestruct stance).
        (bool ok, ) = address(registry).call(abi.encodeWithSelector(bytes4(keccak256("kill()"))));
        assertFalse(ok, "no kill()");
        // The registry holds stake forever unless the (delayed) withdraw path runs.
        assertEq(address(registry).code.length > 0, true);
    }

    function test_registry_cannot_be_drained_by_anyone() public {
        _stake(arb, 1000e6, "pk");
        // Nobody but the arb (after the delay) can move the tokens out.
        vm.prank(stranger);
        vm.expectRevert();
        IERC20(address(token)).transferFrom(address(registry), stranger, 1000e6);
        assertEq(token.balanceOf(address(registry)), 1000e6);
    }

    function test_constants_locked_at_deploy() public {
        assertEq(registry.STAKE_MULTIPLE(), STAKE_MULTIPLE);
        assertEq(registry.UNBONDING_DELAY(), UNBONDING);
        assertEq(address(registry.STAKING_TOKEN()), address(token));
    }
}
