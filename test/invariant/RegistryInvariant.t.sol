// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @dev Stateful handler: a fixed cast of actors randomly staking, unbonding
///      and withdrawing against a MIN_STAKE registry. Reverting calls are
///      swallowed — the invariants must hold after ANY interleaving.
contract RegistryHandler is Test {
    ArbitratorRegistry public immutable registry;
    MockERC20 public immutable token;
    address[6] public actors;

    constructor(ArbitratorRegistry _registry, MockERC20 _token) {
        registry = _registry;
        token = _token;
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = address(uint160(0xAC70 + i));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 10_000e6); // includes sub-MIN_STAKE dust attempts
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(registry), amount);
        try registry.stake(amount, "pk") {} catch {}
        vm.stopPrank();
    }

    function requestUnbond(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 10_000e6);
        vm.prank(who);
        try registry.requestUnbond(amount) {} catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        vm.prank(who);
        try registry.withdraw() {} catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
    }
}

/// F4 invariant seeds (plan §8): draw-list membership tracks stake exactly, the
/// list stays duplicate-free, and the registry is always solvent — under any
/// interleaving of stake / unbond / withdraw / time.
contract RegistryInvariantTest is Test {
    ArbitratorRegistry internal registry;
    MockERC20 internal token;
    RegistryHandler internal handler;

    uint256 internal constant MIN_STAKE = 50e6;

    function setUp() public {
        token = new MockERC20("MockUSDC", "USDC", 6);
        registry = new ArbitratorRegistry(IERC20(address(token)), 10, 21 days, 7 days, 1000, 5000, MIN_STAKE);
        handler = new RegistryHandler(registry, token);
        targetContract(address(handler));
    }

    /// membership ⟺ stake > 0, and the enumerable list carries no duplicates.
    function invariant_listMembershipMatchesStake() public view {
        uint256 n = registry.arbCount();
        uint256 listed;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            bool inList;
            for (uint256 j = 0; j < n; j++) {
                if (registry.arbAt(j) == a) {
                    assertFalse(inList, "duplicate list entry");
                    inList = true;
                }
            }
            assertEq(inList, registry.stakeOf(a) > 0, "membership != (stake > 0)");
            if (inList) listed++;
        }
        assertEq(listed, n, "list holds an address outside the actor cast");
    }

    /// no dust below the floor ever enters, and total stake == registry balance.
    function invariant_minStakeFloorAndSolvency() public view {
        uint256 total;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            uint256 stk = registry.stakeOf(handler.actors(i));
            assertTrue(stk == 0 || stk >= MIN_STAKE, "sub-floor stake entered");
            total += stk;
        }
        assertEq(token.balanceOf(address(registry)), total, "registry insolvent vs recorded stakes");
    }
}
