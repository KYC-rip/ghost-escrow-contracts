// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GhostEscrow} from "../../src/GhostEscrow.sol";
import {EscrowFactory} from "../../src/EscrowFactory.sol";
import {MockERC20} from "./MockERC20.sol";
import {SigUtils} from "./SigUtils.sol";

abstract contract GhostTestBase is Test {
    using SigUtils for *;

    MockERC20 public token;
    GhostEscrow public escrow;
    EscrowFactory public factory;

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

    uint256 internal constant AMOUNT = 4200e6;
    uint256 internal constant FEE_BPS = 150; // 1.5%
    uint256 internal constant ARB_FEE = 50e6;
    uint256 internal constant DEPOSIT_TIMEOUT = 72 hours;
    uint256 internal constant AUTO_RELEASE = 14 days;

    uint256 internal chainId;

    function setUp() public virtual {
        buyer = vm.addr(buyerPk);
        seller = vm.addr(sellerPk);
        arb = vm.addr(arbPk);
        newArb = vm.addr(newArbPk);
        stranger = vm.addr(strangerPk);
        chainId = block.chainid;

        token = new MockERC20("MockUSDC", "USDC", 6);
        escrow = _deployEscrow();
        factory = new EscrowFactory(feeRecipient, FEE_BPS);
    }

    // ─── Deployment helpers ───────────────────────────────────────────────

    function _deployEscrow() internal returns (GhostEscrow e) {
        e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function _deployEscrowFull(
        address token_,
        address buyer_,
        address seller_,
        address arb_,
        uint256 amount_,
        uint256 arbFee_,
        uint256 depositTimeout_,
        uint256 autoRelease_
    ) internal returns (GhostEscrow e) {
        e = new GhostEscrow(
            token_, buyer_, seller_, arb_, feeRecipient, amount_, FEE_BPS, arbFee_, depositTimeout_, autoRelease_
        );
    }

    // ─── Fund + deposit helpers ───────────────────────────────────────────

    function _fund(address who, uint256 amt) internal {
        token.mint(who, amt);
    }

    function _fundActive() internal {
        _fund(buyer, AMOUNT);
        _approveDeposit(buyer, AMOUNT);
        _deposit(buyer, AMOUNT);
        assertEq(uint256(escrow.state()), uint256(GhostEscrow.State.Active));
    }

    function _approveDeposit(address who, uint256 amt) internal {
        vm.prank(who);
        token.approve(address(escrow), amt);
    }

    function _deposit(address who, uint256 amt) internal {
        vm.prank(who);
        escrow.deposit(amt);
    }

    // ─── EIP-712 signing helpers ──────────────────────────────────────────

    function _sig(uint256 pk, bytes32 digest_) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }

    function _releaseSigs(uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.releaseDigest(address(escrow), chainId, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _refundSigs(uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.refundDigest(address(escrow), chainId, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _splitSigs(uint256 buyerAmount, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.splitDigest(address(escrow), chainId, buyerAmount, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _replaceArbSigs(address newArb_, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.replaceArbDigest(address(escrow), chainId, newArb_, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _rescueSigs(address token_, address to, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 d = SigUtils.rescueDigest(address(escrow), chainId, token_, to, nonce, deadline);
        buyerSig = _sig(buyerPk, d);
        sellerSig = _sig(sellerPk, d);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}
