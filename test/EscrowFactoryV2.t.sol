// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBaseV2} from "./utils/GhostTestBaseV2.sol";
import {GhostEscrowV2} from "../src/GhostEscrowV2.sol";
import {EscrowFactoryV2} from "../src/EscrowFactoryV2.sol";
import {ArbitratorRegistry} from "../src/ArbitratorRegistry.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev Phase A — EscrowFactoryV2 eligibility gate + versioning isolation.
contract EscrowFactoryV2Test is GhostTestBaseV2 {
    function test_create_rejects_unstaked_arbitrator() public {
        bytes32 salt = keccak256("u");
        EscrowFactoryV2.Terms memory t = _terms();
        vm.expectRevert(bytes("arb not eligible"));
        factoryV2.createEscrow(t, salt);
    }

    function test_create_rejects_understaked_arbitrator() public {
        _stake(arb, (AMOUNT / STAKE_MULTIPLE) - 1e6, "pk"); // one unit short
        vm.expectRevert(bytes("arb not eligible"));
        factoryV2.createEscrow(_terms(), keccak256("under"));
    }

    function test_create_accepts_eligible_arbitrator_and_deploys_v2() public {
        _stakeArbEligible();
        bytes32 salt = keccak256("ok");
        (address deal, GhostEscrowV2 e) = _createViaFactory(salt);
        assertEq(address(e), deal);
        assertEq(address(e.ARBITRATOR_REGISTRY()), address(registry));
        assertEq(e.arbitrator(), arb);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2.State.Created));
    }

    function test_predicted_address_matches_deploy() public {
        _stakeArbEligible();
        bytes32 salt = keccak256("pred");
        EscrowFactoryV2.Terms memory t = _terms();
        address predicted = factoryV2.predictAddress(t, salt);
        address actual = factoryV2.createEscrow(t, salt);
        assertEq(actual, predicted, "predictAddress must equal createEscrow");
    }

    function test_create_with_zero_arbitrator_reverts_via_constructor_or_gate() public {
        // A zero arbitrator fails eligibility first (unstaked), then the escrow
        // constructor's "zero addr" guard — either way it reverts.
        _stakeArbEligible();
        EscrowFactoryV2.Terms memory t = _terms();
        t.arbitrator = address(0);
        vm.expectRevert(); // "arb not eligible" (registry view on address(0) is false)
        factoryV2.createEscrow(t, keccak256("zeroarb"));
    }

    // ─── Versioning isolation (§5.7): old factory + old deals untouched ────

    function test_v1_factory_and_deal_unaffected_by_v2() public {
        // Deploy the OLD v1.1 factory + escrow with an UNSTAKED arbitrator —
        // v1 has no eligibility gate and must work exactly as before.
        EscrowFactory v1Factory = new EscrowFactory(feeRecipient, FEE_BPS);
        EscrowFactory.Terms memory t = EscrowFactory.Terms({
            token: address(token),
            buyer: buyer,
            seller: seller,
            arbitrator: stranger, // not staked — v1 allows it
            dealAmount: AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: DEPOSIT_TIMEOUT,
            autoReleaseDelay: AUTO_RELEASE
        });
        address deal = v1Factory.createEscrow(t, keccak256("v1"));
        GhostEscrow v1 = GhostEscrow(deal);
        assertEq(v1.arbitrator(), stranger, "v1 keeps unstaked arb");

        // v1 deal still completes via mutual release.
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(deal, AMOUNT);
        vm.prank(buyer);
        v1.deposit(AMOUNT);
        assertEq(uint256(v1.state()), uint256(GhostEscrow.State.Active));
        (bytes memory bSig, bytes memory sSig) = _releaseSigsV1(deal, 0);
        vm.prank(buyer);
        v1.release(_deadline(), bSig, sSig);
        assertEq(uint256(v1.state()), uint256(GhostEscrow.State.Completed));
    }

    function test_v2_registry_ref_is_pinned_per_deal() public {
        _stakeArbEligible();
        (, GhostEscrowV2 e1) = _createViaFactory(keccak256("a"));
        (, GhostEscrowV2 e2) = _createViaFactory(keccak256("b"));
        assertEq(address(e1.ARBITRATOR_REGISTRY()), address(registry));
        assertEq(address(e2.ARBITRATOR_REGISTRY()), address(registry));
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    function _terms() internal view returns (EscrowFactoryV2.Terms memory t) {
        t = EscrowFactoryV2.Terms({
            token: address(token),
            buyer: buyer,
            seller: seller,
            arbitrator: arb,
            dealAmount: AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: DEPOSIT_TIMEOUT,
            autoReleaseDelay: AUTO_RELEASE
        });
    }

    function _releaseSigsV1(address deal, uint256 nonce)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.releaseDigest(deal, chainId, nonce, _deadline());
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }
}
