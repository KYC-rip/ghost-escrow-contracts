// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {SigUtils} from "./utils/SigUtils.sol";

/// @dev USDC/USDT-style token with a transfer blocklist (both real deal tokens have one).
contract BlacklistERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("BlacklistUSD", "bUSD") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blocked[from] && !blocked[to], "blacklisted");
        super._update(from, to, v);
    }
}

contract AuditPoC is Test {
    uint256 constant BUYER_PK = 0xA11CE;
    uint256 constant SELLER_PK = 0xB0BEEF;
    uint256 constant ARB_PK = 0xCAFEBABE;

    address buyer = vm.addr(BUYER_PK);
    address seller = vm.addr(SELLER_PK);
    address arb = vm.addr(ARB_PK);
    address feeRecipient = address(0xFEE5);
    address thirdParty = address(0x7413D);

    uint256 constant AMOUNT = 4200e6;
    uint256 constant FEE_BPS = 150;
    uint256 constant ARB_FEE = 50e6;

    function _sign(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-01  Constructor never checks arbitrator != buyer/seller, although
    //       replaceArbitrator() explicitly forbids exactly that. A seller who
    //       creates the deal names themselves as arbitrator and takes 100%.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F01_sellerIsOwnArbitrator_takesEverything() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);

        // FIXED (finding 1): constructor now rejects arbitrator == a party.
        vm.expectRevert(bytes("bad arb"));
        vm.prank(seller);
        new GhostEscrow(
            address(token), buyer, seller, seller, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-02  expire() PUSHES the buyer's refund. One un-receivable buyer address
    //       (USDC/USDT blocklist) bricks expire() forever -> the whole contract
    //       can never reach a terminal state and EVERY other depositor's funds
    //       are frozen, even though claimExpired() is a perfectly good pull path.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F02_expireBrickedByUnreceivableBuyer_freezesThirdParty() public {
        BlacklistERC20 token = new BlacklistERC20();
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );

        // Buyer part-funds; a third party (co-signer / employer / OTC desk) tops up.
        token.mint(buyer, 1000e6);
        token.mint(thirdParty, 2000e6);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(1000e6);
        vm.stopPrank();
        vm.startPrank(thirdParty);
        token.approve(address(e), type(uint256).max);
        e.deposit(2000e6);
        vm.stopPrank();

        // Deal never reaches dealAmount. Window closes.
        vm.warp(block.timestamp + 73 hours);

        // Issuer blacklists the buyer (or the buyer is simply a contract that
        // cannot receive this token).
        token.setBlocked(buyer, true);

        // expire() is now permanently unreachable...
        vm.expectRevert(bytes("blacklisted"));
        e.expire();

        // ...so claimExpired() is unreachable too: it requires State.Expired.
        vm.prank(thirdParty);
        vm.expectRevert(bytes("not expired"));
        e.claimExpired();

        // And rescueToken() on the deal token needs a terminal state. Dead end.
        (bytes memory bs, bytes memory ss) = _mutualSigs(
            e, SigUtils.rescueDigest(address(e), block.chainid, address(token), seller, e.nonce(), block.timestamp + 1)
        );
        vm.expectRevert(bytes("deal token not settled"));
        e.rescueToken(address(token), seller, block.timestamp + 1, bs, ss);

        assertEq(token.balanceOf(address(e)), 3000e6, "3000 USDC frozen forever");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-03  Every settlement path pays the factory-wide, immutable feeRecipient
    //       inline. If that ONE address becomes un-receivable, release / refund /
    //       mutualSplit / autoRelease / rule ALL revert -> every funded deal from
    //       that factory is permanently frozen, with no admin and no rescue.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F03_unreceivableFeeRecipient_freezesEveryDeal() public {
        BlacklistERC20 token = new BlacklistERC20();
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );

        token.mint(buyer, AMOUNT + ARB_FEE);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        vm.stopPrank();

        token.setBlocked(feeRecipient, true);

        uint256 dl = block.timestamp + 1 days;

        // Mutual release: dead.
        (bytes memory bs, bytes memory ss) =
            _mutualSigs(e, SigUtils.releaseDigest(address(e), block.chainid, e.nonce(), dl));
        vm.expectRevert(bytes("blacklisted"));
        e.release(dl, bs, ss);

        // Mutual refund: dead.
        (bs, ss) = _mutualSigs(e, SigUtils.refundDigest(address(e), block.chainid, e.nonce(), dl));
        vm.expectRevert(bytes("blacklisted"));
        e.refund(dl, bs, ss);

        // Mutual custom split: dead.
        (bs, ss) = _mutualSigs(e, SigUtils.splitDigest(address(e), block.chainid, AMOUNT / 2, e.nonce(), dl));
        vm.expectRevert(bytes("blacklisted"));
        e.mutualSplit(AMOUNT / 2, dl, bs, ss);

        // Auto-release: dead.
        vm.warp(block.timestamp + 15 days);
        vm.expectRevert(bytes("blacklisted"));
        e.autoRelease();

        // Arbitration: dead.
        vm.startPrank(buyer);
        e.openDispute();
        vm.stopPrank();
        vm.prank(arb);
        vm.expectRevert(bytes("blacklisted"));
        e.rule(AMOUNT, 0, keccak256("x"));

        assertEq(token.balanceOf(address(e)), AMOUNT + ARB_FEE, "entire deal frozen by a 3rd-party address");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-04  depositDeadline is set from the DEPLOY timestamp and createEscrow()
    //       is permissionless. The documented flow is "predict the address, pay
    //       into it (e.g. a slow XMR->USDC swap), then deploy". A seller who
    //       deploys immediately burns the whole deposit window before the money
    //       lands: syncDeposit() is closed forever and the buyer's funds are
    //       hostage to the seller's signature.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F04_earlyDeploy_burnsDepositWindow_holdsBuyerFundsHostage() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        EscrowFactory factory = new EscrowFactory(feeRecipient, FEE_BPS);

        EscrowFactory.Terms memory t = EscrowFactory.Terms({
            token: address(token),
            buyer: buyer,
            seller: seller,
            arbitrator: arb,
            dealAmount: AMOUNT,
            arbitratorFee: ARB_FEE,
            depositTimeout: 72 hours,
            autoReleaseDelay: 14 days
        });
        bytes32 salt = keccak256("deal-1");
        address predicted = factory.predictAddress(t, salt);

        // Seller front-runs the deployment the moment terms are agreed.
        vm.prank(seller);
        address deployed = factory.createEscrow(t, salt);
        assertEq(deployed, predicted, "CREATE2 prediction holds");

        // The buyer's Monero->USDC swap settles 4 days later, into the address.
        vm.warp(block.timestamp + 4 days);
        token.mint(predicted, AMOUNT);

        GhostEscrow e = GhostEscrow(deployed);

        // Nobody can credit it any more.
        vm.expectRevert(bytes("deposit window closed"));
        e.syncDeposit();

        // Terminal state reachable, but with deposited == 0 there is nothing to claim.
        e.expire();
        vm.prank(buyer);
        vm.expectRevert(bytes("nothing to claim"));
        e.claimExpired();

        // Only escape: rescueToken -> needs the SELLER's signature. Pure ransom.
        uint256 dl = block.timestamp + 1 days;
        (bytes memory bs, bytes memory ss) =
            _mutualSigs(e, SigUtils.rescueDigest(address(e), block.chainid, address(token), buyer, e.nonce(), dl));
        e.rescueToken(address(token), buyer, dl, bs, ss);
        assertEq(token.balanceOf(buyer), AMOUNT, "recoverable ONLY with counterparty cooperation");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-05  Disputed is an absorbing state: openDispute() freezes auto-release
    //       with no on-chain ruling deadline and no way back to Active. A seller
    //       (or buyer) can lock the counterparty's money forever for the price of
    //       the arbitrator fee if the arbitrator simply never shows up.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F05_disputeIsAbsorbing_permanentFreeze() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );

        token.mint(buyer, AMOUNT);
        token.mint(seller, ARB_FEE);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        vm.stopPrank();

        // Seller opens a bad-faith dispute; arbitrator never rules.
        vm.startPrank(seller);
        token.approve(address(e), type(uint256).max);
        e.openDispute();
        vm.stopPrank();

        vm.warp(block.timestamp + 3650 days); // ten years

        vm.expectRevert(bytes("not active"));
        e.autoRelease();
        vm.expectRevert(bytes("bad state"));
        e.expire();

        assertEq(uint256(e.state()), uint256(GhostEscrow.State.Disputed));
        assertEq(token.balanceOf(address(e)), AMOUNT + ARB_FEE, "frozen a decade later");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-06  A signature cannot be revoked. There is no bumpNonce()/cancel entry
    //       point, so a party who signs a Release early (natural "pre-authorise
    //       the payout" UX) cannot take it back; the counterparty can spring it
    //       at any point until the deadline, including after failing to deliver.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F06_signatureCannotBeRevoked() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        vm.stopPrank();

        // Both parties sign a release up front with a 30-day deadline.
        uint256 dl = block.timestamp + 30 days;
        (bytes memory bs, bytes memory ss) =
            _mutualSigs(e, SigUtils.releaseDigest(address(e), block.chainid, e.nonce(), dl));

        // Buyer changes their mind. There is no on-chain way to invalidate the
        // nonce without the counterparty's cooperation -- every mutual action
        // that would bump it needs the seller's signature too.
        vm.warp(block.timestamp + 29 days);

        // Seller springs the stale signature after failing to deliver.
        vm.prank(seller);
        e.release(dl, bs, ss);
        assertEq(uint256(e.state()), uint256(GhostEscrow.State.Completed));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-07  openDispute() demands an EXACT balance delta, so on a fee-on-transfer
    //       deal token the dispute button is permanently broken while deposits
    //       still work -> the buyer is railroaded into autoRelease to the seller.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F07_feeOnTransferToken_disputeImpossible_autoReleaseStillPays() public {
        MockERC20 token = new MockERC20("FoT", "FoT", 6);
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );

        token.setFeeOnTransfer(100); // 1%
        token.mint(buyer, AMOUNT * 2);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT + (AMOUNT / 99) + 1); // overshoot so the delta reaches AMOUNT
        assertEq(uint256(e.state()), uint256(GhostEscrow.State.Active), "FoT deposits work fine");

        // ...but disputing does not.
        vm.expectRevert(bytes("fee short"));
        e.openDispute();
        vm.stopPrank();

        // So silence pays the seller.
        vm.warp(block.timestamp + 15 days);
        e.autoRelease();
        assertEq(uint256(e.state()), uint256(GhostEscrow.State.Completed));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F-08  Tokens that land on the contract after it goes Active are invisible
    //       to accounting (syncDeposit is state-locked) and are only recoverable
    //       with BOTH signatures -- a second/duplicate swap payment is a hostage.
    // ─────────────────────────────────────────────────────────────────────────
    function test_F08_lateDirectTransferStranded() public {
        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        GhostEscrow e = new GhostEscrow(
            address(token), buyer, seller, arb, feeRecipient, AMOUNT, FEE_BPS, ARB_FEE, 72 hours, 14 days
        );
        token.mint(buyer, AMOUNT * 2);
        vm.startPrank(buyer);
        token.approve(address(e), type(uint256).max);
        e.deposit(AMOUNT);
        // Duplicate swap output lands directly on the deal address.
        token.transfer(address(e), AMOUNT);
        vm.stopPrank();

        vm.expectRevert(bytes("bad state"));
        e.syncDeposit();

        vm.warp(block.timestamp + 15 days);
        e.autoRelease();
        assertEq(token.balanceOf(address(e)), AMOUNT, "buyer's second payment stuck, needs seller's sig");
    }

    // ─── helper ──────────────────────────────────────────────────────────────
    function _mutualSigs(GhostEscrow, bytes32 digest) internal pure returns (bytes memory bs, bytes memory ss) {
        bs = _sign(BUYER_PK, digest);
        ss = _sign(SELLER_PK, digest);
    }
}
