// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev Fully hostile deal token: reenters the escrow on every transfer.
contract ReenterERC20 is ERC20 {
    GhostEscrow public target;
    uint8 public mode;
    bool internal entered;
    string public lastRevert;
    bool public replaceArbSucceeded;

    bytes internal bs;
    bytes internal ss;
    address internal newArb;
    uint256 internal dl;

    constructor() ERC20("Hostile", "HOS") {}

    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
    function arm(GhostEscrow t, uint8 m) external { target = t; mode = m; }
    function armReplace(address a, uint256 d, bytes calldata b, bytes calldata s) external {
        newArb = a; dl = d; bs = b; ss = s;
    }

    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (address(target) == address(0) || entered || from != address(target)) return;
        entered = true;
        if (mode == 1) {
            try target.expire() { lastRevert = "NO REVERT: expire"; }
            catch Error(string memory r) { lastRevert = r; }
            catch { lastRevert = "GUARD"; }
        } else if (mode == 2) {
            try target.syncDeposit() { lastRevert = "NO REVERT: syncDeposit"; }
            catch Error(string memory r) { lastRevert = r; }
            catch { lastRevert = "GUARD"; }
        } else if (mode == 3) {
            try target.autoRelease() { lastRevert = "NO REVERT: autoRelease"; }
            catch Error(string memory r) { lastRevert = r; }
            catch { lastRevert = "GUARD"; }
        } else if (mode == 4) {
            try target.claimExpired() { lastRevert = "NO REVERT: claimExpired"; }
            catch Error(string memory r) { lastRevert = r; }
            catch { lastRevert = "GUARD"; }
        } else if (mode == 5) {
            // replaceArbitrator is the ONLY entry point without nonReentrant
            try target.replaceArbitrator(newArb, dl, bs, ss) { replaceArbSucceeded = true; }
            catch Error(string memory r) { lastRevert = r; }
            catch { lastRevert = "GUARD"; }
        }
        entered = false;
    }
}

contract AuditPoC2 is Test {
    uint256 constant BUYER_PK = 0xA11CE;
    uint256 constant SELLER_PK = 0xB0BEEF;
    uint256 constant ARB_PK = 0xCAFEBABE;

    address buyer = vm.addr(BUYER_PK);
    address seller = vm.addr(SELLER_PK);
    address arb = vm.addr(ARB_PK);
    address feeRecipient = address(0xFEE5);

    uint256 constant AMOUNT = 4200e6;
    uint256 constant FEE_BPS = 150;
    uint256 constant ARB_FEE = 50e6;

    function _sigs(bytes32 d) internal pure returns (bytes memory b, bytes memory s) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(BUYER_PK, d);
        b = abi.encodePacked(r1, s1, v1);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(SELLER_PK, d);
        s = abi.encodePacked(r2, s2, v2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-09  ONE nonce is shared by all five mutual actions. Any unspent
    //       signature pair at nonce N pre-empts whatever the parties actually
    //       agreed at nonce N. A seller holding a stale full-Release from an
    //       earlier negotiation round front-runs the 50/50 mutualSplit and
    //       takes 100%.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F09_sharedNonce_staleSignaturePreemptsAgreedSplit() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        vm.stopPrank();

        uint256 dl = block.timestamp + 7 days;
        uint256 n = e.nonce();

        // Round 1 of the negotiation: buyer agrees to a full release. Not broadcast.
        (bytes memory rb, bytes memory rs) = _sigs(SigUtils.releaseDigest(address(e), block.chainid, n, dl));

        // Round 2: parties renegotiate to a 50/50 split and sign it. SAME nonce.
        uint256 half = AMOUNT / 2;
        (bytes memory sb, bytes memory ss) = _sigs(SigUtils.splitDigest(address(e), block.chainid, half, n, dl));

        // Buyer broadcasts the split; seller front-runs with the stale release.
        vm.prank(seller);
        e.release(dl, rb, rs);

        // The agreed split is now unexecutable and the buyer gets nothing.
        vm.expectRevert(bytes("bad state"));
        e.mutualSplit(half, dl, sb, ss);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(seller), AMOUNT - fee, "seller took 100%");
        assertEq(token.balanceOf(buyer), 0, "buyer got nothing despite the later agreement");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-10  Reentrancy containment probe: a fully hostile deal token reentering
    //       from inside the excess-refund transfer (state still pre-Active,
    //       `deposited` already clamped). Every guarded entry point is blocked.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F10_reentrancyFromExcessRefund_isContained() public {
        for (uint8 m = 1; m <= 4; m++) {
            ReenterERC20 token = new ReenterERC20();
            GhostEscrow e = new GhostEscrow(
                address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
            );
            token.arm(e, m);
            token.mint(buyer, AMOUNT * 2);
            vm.startPrank(buyer);
            token.approve(address(e), type(uint256).max);
            e.deposit(AMOUNT + 1e6); // triggers the excess refund -> reentry
            vm.stopPrank();

            assertEq(token.lastRevert(), "GUARD", "reentry must hit ReentrancyGuard");
            assertEq(e.deposited(), AMOUNT);
            assertEq(token.balanceOf(address(e)), AMOUNT, "accounting intact");
            assertEq(uint256(e.state()), uint256(GhostEscrow.State.Active));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-11  replaceArbitrator() was the one external state-changing function
    //       WITHOUT nonReentrant. FIXED: the reentrant swap is now blocked by
    //       the guard, the arbitrator is unchanged, and only release()'s nonce
    //       was consumed.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F11_replaceArbitratorReachableViaReentrancy() public {
        ReenterERC20 token = new ReenterERC20();
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );
        token.mint(buyer, AMOUNT + ARB_FEE);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        e.openDispute(); // fee pot funded, state Disputed
        vm.stopPrank();

        uint256 dl = block.timestamp + 1 days;
        uint256 n = e.nonce();
        // release() consumes nonce n, so the nested call must sign n+1.
        (bytes memory rb, bytes memory rs) = _sigs(SigUtils.releaseDigest(address(e), block.chainid, n, dl));
        address evilArb = address(0xE7112);
        (bytes memory ab, bytes memory as_) =
            _sigs(SigUtils.replaceArbDigest(address(e), block.chainid, evilArb, n + 1, dl));
        token.armReplace(evilArb, dl, ab, as_);
        token.arm(e, 5); // reenter replaceArbitrator from the fee-pot transfer

        e.release(dl, rb, rs);

        // Guarded now: the nested replaceArbitrator hits nonReentrant.
        assertFalse(token.replaceArbSucceeded(), "reentry into replaceArbitrator must be blocked");
        assertEq(e.arbitrator(), arb, "arbitrator must be unchanged");
        assertEq(e.nonce(), n + 1, "nonce advanced exactly once (release only)");
    }
}
