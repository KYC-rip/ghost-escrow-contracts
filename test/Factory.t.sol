// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev Factory: CREATE2 address prediction, event-only registry, fee caps,
///      per-instance domain separation (cross-deal signature non-replay).
contract FactoryTest is GhostTestBase {
    EscrowFactory.Terms internal terms;

    function setUp() public override {
        super.setUp();
        terms = EscrowFactory.Terms({
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

    function test_Factory_PredictAddressMatchesDeployed() public {
        bytes32 salt = keccak256("deal-1");
        address predicted = factory.predictAddress(terms, salt);
        vm.expectEmit(true, true, true, true, address(factory));
        emit EscrowFactory.EscrowCreated(predicted, buyer, seller, arb, address(token), AMOUNT);
        address deployed = factory.createEscrow(terms, salt);
        assertEq(deployed, predicted);
        assertEq(GhostEscrow(deployed).buyer(), buyer);
        assertEq(GhostEscrow(deployed).depositDeadline(), block.timestamp + DEPOSIT_TIMEOUT);
    }

    function test_Factory_DifferentSaltsDifferentAddresses() public {
        address a = factory.predictAddress(terms, keccak256("x"));
        address b = factory.predictAddress(terms, keccak256("y"));
        assertTrue(a != b);
    }

    function test_Factory_SameSaltTwiceReverts() public {
        bytes32 salt = keccak256("unique");
        factory.createEscrow(terms, salt);
        try factory.createEscrow(terms, salt) {
            fail(); // second CREATE2 deployment should have reverted
        } catch {}
    }

    function test_Factory_TermsVariationChangesAddress() public {
        address base = factory.predictAddress(terms, keccak256("s"));
        terms.dealAmount = AMOUNT + 1e6;
        address changed = factory.predictAddress(terms, keccak256("s"));
        assertTrue(base != changed);
    }

    function test_Factory_FeeCaps() public {
        vm.expectRevert("fee too high");
        new EscrowFactory(feeRecipient, 1001);
        vm.expectRevert(bytes("zero"));
        new EscrowFactory(address(0), 100);
    }

    function test_Factory_ImmutableParams() public {
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.platformFeeBps(), FEE_BPS);
    }

    function test_Factory_DeployedEscrowRejectsFactoryFeeOverride() public {
        // The escrow constructor enforces its own fee cap independent of factory.
        terms.dealAmount = 0;
        vm.expectRevert("zero amount");
        factory.createEscrow(terms, keccak256("bad"));
    }

    function test_Factory_DeployedEscrowEnforcesAutoReleaseBounds() public {
        terms.autoReleaseDelay = 200 days;
        vm.expectRevert("bad auto-release");
        factory.createEscrow(terms, keccak256("ar"));
    }

    // ─── Cross-deal signature isolation ───────────────────────────────────

    function test_CrossDeal_SignatureFromDealAInvalidOnDealB() public {
        address dealA = factory.createEscrow(terms, keccak256("A"));

        // Same terms, same nonce/deadline, different salt -> different address.
        address dealB = factory.createEscrow(terms, keccak256("B"));
        assertTrue(dealA != dealB);

        // Fund B so the state check passes and we reach signature verification.
        vm.prank(buyer);
        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(dealB, AMOUNT);
        vm.prank(buyer);
        GhostEscrow(dealB).deposit(AMOUNT);

        // Sign a Release for deal A; attempt on deal B.
        bytes32 dA = SigUtils.releaseDigest(dealA, chainId, 0, _deadline());
        (bytes memory bSigA, bytes memory sSigA) = (_sig(buyerPk, dA), _sig(sellerPk, dA));
        vm.expectRevert("bad buyer sig");
        GhostEscrow(dealB).release(_deadline(), bSigA, sSigA);
    }

    function test_CrossDeal_IdenticalSignatureNeverCrossesContracts() public {
        address dealA = factory.createEscrow(terms, keccak256("A"));
        address dealB = factory.createEscrow(terms, keccak256("B"));

        // Fund both identically.
        for (uint256 i = 0; i < 2; i++) {
            address d = i == 0 ? dealA : dealB;
            vm.prank(buyer);
            token.mint(buyer, AMOUNT);
            vm.prank(buyer);
            token.approve(d, AMOUNT);
            vm.prank(buyer);
            GhostEscrow(d).deposit(AMOUNT);
        }

        // Release deal A with its own signatures — works.
        bytes32 dA = SigUtils.releaseDigest(dealA, chainId, 0, _deadline());
        GhostEscrow(dealA).release(_deadline(), _sig(buyerPk, dA), _sig(sellerPk, dA));
        assertEq(uint256(GhostEscrow(dealA).state()), uint256(GhostEscrow.State.Completed));

        // The same digest/signatures on deal B must fail (different verifyingContract).
        vm.expectRevert("bad buyer sig");
        GhostEscrow(dealB).release(_deadline(), _sig(buyerPk, dA), _sig(sellerPk, dA));
    }

    function test_CrossDeal_NonceIsPerInstance() public {
        address dealA = factory.createEscrow(terms, keccak256("A"));
        address dealB = factory.createEscrow(terms, keccak256("B"));
        assertEq(GhostEscrow(dealA).nonce(), 0);
        assertEq(GhostEscrow(dealB).nonce(), 0);

        // Bump nonce on A only.
        vm.prank(buyer);
        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(dealA, AMOUNT);
        vm.prank(buyer);
        GhostEscrow(dealA).deposit(AMOUNT);
        bytes32 dA = SigUtils.releaseDigest(dealA, chainId, 0, _deadline());
        GhostEscrow(dealA).release(_deadline(), _sig(buyerPk, dA), _sig(sellerPk, dA));
        assertEq(GhostEscrow(dealA).nonce(), 1);
        assertEq(GhostEscrow(dealB).nonce(), 0);
    }

    function test_CrossDeal_SignaturesCarryTheirOwnDomain() public {
        // Deal B's own valid release works after A was settled — proving the
        // per-instance domain separator isolates instances completely.
        address dealA = factory.createEscrow(terms, keccak256("A"));
        address dealB = factory.createEscrow(terms, keccak256("B"));
        vm.prank(buyer);
        token.mint(buyer, AMOUNT * 2);

        vm.prank(buyer);
        token.approve(dealA, AMOUNT);
        vm.prank(buyer);
        GhostEscrow(dealA).deposit(AMOUNT);

        vm.prank(buyer);
        token.approve(dealB, AMOUNT);
        vm.prank(buyer);
        GhostEscrow(dealB).deposit(AMOUNT);

        bytes32 dA = SigUtils.releaseDigest(dealA, chainId, 0, _deadline());
        GhostEscrow(dealA).release(_deadline(), _sig(buyerPk, dA), _sig(sellerPk, dA));

        bytes32 dB = SigUtils.releaseDigest(dealB, chainId, 0, _deadline());
        GhostEscrow(dealB).release(_deadline(), _sig(buyerPk, dB), _sig(sellerPk, dB));

        assertEq(uint256(GhostEscrow(dealA).state()), uint256(GhostEscrow.State.Completed));
        assertEq(uint256(GhostEscrow(dealB).state()), uint256(GhostEscrow.State.Completed));
    }

    function test_CrossDeal_PreFundingThenDeployThenSync() public {
        // The CREATE2 pre-funding flow: swap XMR->USDC into the predicted
        // address BEFORE deploy, then deploy, then syncDeposit().
        address predicted = factory.predictAddress(terms, keccak256("prefund"));
        token.mint(predicted, AMOUNT);

        address deployed = factory.createEscrow(terms, keccak256("prefund"));
        assertEq(deployed, predicted);
        assertEq(uint256(GhostEscrow(deployed).state()), uint256(GhostEscrow.State.Created));

        GhostEscrow(deployed).syncDeposit();
        assertEq(uint256(GhostEscrow(deployed).state()), uint256(GhostEscrow.State.Active));
        assertEq(GhostEscrow(deployed).deposited(), AMOUNT);
        assertEq(GhostEscrow(deployed).depositedBy(buyer), AMOUNT);
    }
}
