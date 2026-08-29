// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GhostEscrowV2} from "../../src/GhostEscrowV2.sol";
import {EscrowFactoryV2} from "../../src/EscrowFactoryV2.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {AppealCourt} from "../../src/AppealCourt.sol";
import {MockERC20} from "./MockERC20.sol";
import {SigUtils} from "./SigUtils.sol";

/// @dev Shared harness for the Arbitrator Model v2 (Phase A) test suites.
abstract contract GhostTestBaseV2 is Test {
    using SigUtils for *;

    MockERC20 public token; // staking token (USDC) AND deal token
    ArbitratorRegistry public registry;
    EscrowFactoryV2 public factoryV2;
    AppealCourt public court;
    GhostEscrowV2 public escrowV2;

    uint256 internal buyerPk = 0xA11CE;
    uint256 internal sellerPk = 0xB0BEEF;
    uint256 internal arbPk = 0xCAFEBABE;
    uint256 internal strangerPk = 0xDEADBEEF;
    uint256 internal newArbPk = 0xBAD0C0DE;

    address internal buyer;
    address internal seller;
    address internal arb;
    address internal newArb;
    address internal stranger;
    address internal feeRecipient = address(0xFEE5);

    uint256 internal constant STAKE_MULTIPLE = 10;
    uint256 internal constant UNBONDING = 21 days;
    uint256 internal constant SLA_DURATION = 7 days;
    uint256 internal constant SLA_SLASH_BPS = 1000; // 10%
    uint256 internal constant OVERTURN_SLASH_BPS = 5000; // 50% (C-4 launch, operator 2026-08-21)
    uint256 internal constant AMOUNT = 4200e6; // $4200
    uint256 internal constant FEE_BPS = 150; // 1.5%
    uint256 internal constant ARB_FEE = 50e6;
    uint256 internal constant DEPOSIT_TIMEOUT = 72 hours;
    uint256 internal constant AUTO_RELEASE = 14 days;
    uint256 internal constant STAKE_FOR_AMOUNT = (AMOUNT + STAKE_MULTIPLE - 1) / STAKE_MULTIPLE; // $420 stake

    uint256 internal chainId;

    function setUp() public virtual {
        buyer = vm.addr(buyerPk);
        seller = vm.addr(sellerPk);
        arb = vm.addr(arbPk);
        newArb = vm.addr(newArbPk);
        stranger = vm.addr(strangerPk);
        chainId = block.chainid;

        token = new MockERC20("MockUSDC", "USDC", 6);
        // Deploy order (C-5): registry → factory → court → deployer binds both.
        registry = new ArbitratorRegistry(
            IERC20(address(token)), STAKE_MULTIPLE, UNBONDING, SLA_DURATION, SLA_SLASH_BPS, OVERTURN_SLASH_BPS, 0, address(this)
        );
        factoryV2 = new EscrowFactoryV2(registry, feeRecipient, FEE_BPS);
        court = new AppealCourt(registry);
        // The test contract is the registry's deployer → bind the factory + court
        // (deployer-gated setFactory/setCourt, per the Phase B review front-run fix).
        registry.setFactory(address(factoryV2));
        registry.setCourt(address(court));
    }

    // ─── Staking helpers ───────────────────────────────────────────────────

    function _stake(address who, uint256 amt, string memory pubkey) internal {
        token.mint(who, amt);
        vm.prank(who);
        token.approve(address(registry), amt);
        vm.prank(who);
        registry.stake(amt, pubkey);
    }

    function _stakeArbEligible() internal {
        _stake(arb, STAKE_FOR_AMOUNT, "arb-pubkey");
    }

    function _stakeNewArbEligible() internal {
        _stake(newArb, STAKE_FOR_AMOUNT, "newarb-pubkey");
    }

    // ─── Deal helpers ──────────────────────────────────────────────────────

    /// @dev Deploy a v2 escrow THROUGH the factory so factory.isEscrow is set
    ///      (Phase B hooks require it). The arb must already be staked eligible.
    function _deployV2Escrow() internal returns (GhostEscrowV2 e) {
        (address deal, GhostEscrowV2 esc) = _createViaFactory(keccak256(abi.encode(arb, escrowV2, block.timestamp, vm.getNonce(address(this)))));
        escrowV2 = esc;
        e = esc;
        assertEq(address(e), deal);
    }

    function _createViaFactory(bytes32 salt)
        internal
        returns (address deal, GhostEscrowV2 e)
    {
        EscrowFactoryV2.Terms memory t = EscrowFactoryV2.Terms({
            token: address(token),
            buyer: buyer,
            seller: seller,
            arbitrator: arb,
            dealAmount: AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: DEPOSIT_TIMEOUT,
            autoReleaseDelay: AUTO_RELEASE
        });
        deal = factoryV2.createEscrow(t, salt);
        e = GhostEscrowV2(deal);
    }

    function _fund(address who, uint256 amt) internal {
        token.mint(who, amt);
    }

    function _fundActiveV2() internal {
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(escrowV2), AMOUNT);
        vm.prank(buyer);
        escrowV2.deposit(AMOUNT);
        assertEq(uint256(escrowV2.state()), uint256(GhostEscrowV2.State.Active));
    }

    /// @dev Fund + open a dispute on the current escrowV2 (arb fee approved).
    function _openDisputeV2() internal {
        _fund(buyer, ARB_FEE);
        vm.prank(buyer);
        token.approve(address(escrowV2), ARB_FEE);
        vm.prank(buyer);
        escrowV2.openDispute();
    }

    function _refundSigsV2(address deal, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.refundDigest(deal, chainId, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _splitSigsV2(address deal, uint256 buyerAmount, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.splitDigest(deal, chainId, buyerAmount, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    // ─── EIP-712 signing helpers (SigUtils domain == v2 domain) ───────────

    function _sig(uint256 pk, bytes32 digest_) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }

    function _replaceArbSigsV2(address deal, address newArb_, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.replaceArbDigest(deal, chainId, newArb_, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _releaseSigsV2(address deal, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.releaseDigest(deal, chainId, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}
