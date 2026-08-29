// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GhostEscrowV2CImpl} from "../../src/GhostEscrowV2CImpl.sol";
import {GhostEscrowV2OpenCImpl} from "../../src/GhostEscrowV2OpenCImpl.sol";
import {EscrowCloneFactory} from "../../src/EscrowCloneFactory.sol";
import {ArbitratorRegistry} from "../../src/ArbitratorRegistry.sol";
import {AppealCourt} from "../../src/AppealCourt.sol";
import {MockERC20} from "./MockERC20.sol";
import {SigUtils} from "./SigUtils.sol";

/// @dev Test-only "future template": a minimal milestone-style escrow that can
///      open SEQUENTIAL appeal cases at the court. Registered through the real
///      addTemplate path, so it simultaneously proves (a) the append-only
///      template-release mechanism and (b) the Phase D sequential-case court
///      change, without touching the production templates.
contract MockSequentialTemplate {
    using SafeERC20 for IERC20;

    address public immutable FACTORY;
    ArbitratorRegistry public immutable REGISTRY;

    IERC20 public token;
    address public buyer;
    address public seller;
    address public arbitrator;
    uint256 public dealAmount;
    bool private _initialized;

    uint256 public upholds;
    uint256 public overturns;
    uint256 public lastBuyerAmount;
    uint256 public lastSellerAmount;

    constructor(address _factory, ArbitratorRegistry _registry) {
        FACTORY = _factory;
        REGISTRY = _registry;
        _initialized = true;
    }

    function initialize(address, uint256, bytes calldata initData) external {
        require(msg.sender == FACTORY, "not factory");
        require(!_initialized, "initialized");
        _initialized = true;
        (address _token, address _buyer, address _seller, address _arbitrator, uint256 _dealAmount,,,) =
            abi.decode(initData, (address, address, address, address, uint256, uint256, uint256, uint256));
        require(REGISTRY.isEligible(_arbitrator, _dealAmount), "arb not eligible");
        require(REGISTRY.court() != address(0), "no court");
        token = IERC20(_token);
        buyer = _buyer;
        seller = _seller;
        arbitrator = _arbitrator;
        dealAmount = _dealAmount;
    }

    /// Open an appeal case at the court for this deal (tranche N dispute).
    /// The bond must already sit on this contract; it is forwarded to the
    /// court exactly like GhostEscrowV2.appeal() does.
    function openAppealCase(address challenger, uint256 bond, uint256 origBuyer, uint256 origSeller) external {
        address c = REGISTRY.court();
        if (bond > 0) token.safeTransfer(c, bond);
        AppealCourt(c).onAppeal(address(this), arbitrator, challenger, bond, origBuyer, origSeller);
    }

    // Court settle callbacks (same selectors as GhostEscrowV2).
    function settleAppealUphold() external {
        upholds += 1;
    }

    function settleAppealOverturn(uint256 b, uint256 s) external {
        overturns += 1;
        lastBuyerAmount = b;
        lastSellerAmount = s;
    }
}

/// @dev Shared harness for the Phase D clone-factory suites: full triad with
///      the clone factory bound as THE registry factory, both production
///      template implementations registered and active (activationDelay = 0).
abstract contract GhostTestBaseD is Test {
    MockERC20 public token; // staking token (USDC) AND deal token
    ArbitratorRegistry public registry;
    EscrowCloneFactory public factory;
    AppealCourt public court;
    GhostEscrowV2CImpl public stdImpl;
    GhostEscrowV2OpenCImpl public openImpl;

    uint256 internal buyerPk = 0xA11CE;
    uint256 internal sellerPk = 0xB0BEEF;
    uint256 internal arbPk = 0xCAFEBABE;
    uint256 internal strangerPk = 0xDEADBEEF;
    uint256 internal p1Pk = 0x9A9E11;
    uint256 internal p2Pk = 0x9A9E12;
    uint256 internal p3Pk = 0x9A9E13;

    address internal buyer;
    address internal seller;
    address internal arb;
    address internal stranger;
    address internal p1;
    address internal p2;
    address internal p3;
    address internal feeRecipient = address(0xFEE5);

    uint256 internal constant STAKE_MULTIPLE = 10;
    uint256 internal constant UNBONDING = 21 days;
    uint256 internal constant SLA_DURATION = 7 days;
    uint256 internal constant SLA_SLASH_BPS = 1000; // 10%
    uint256 internal constant OVERTURN_SLASH_BPS = 5000; // 50%
    uint256 internal constant AMOUNT = 4200e6; // $4200
    uint256 internal constant FEE_BPS = 150; // 1.5%
    uint256 internal constant ARB_FEE = 50e6;
    uint256 internal constant DEPOSIT_TIMEOUT = 72 hours;
    uint256 internal constant AUTO_RELEASE = 14 days;
    uint256 internal constant STAKE_FOR_AMOUNT = (AMOUNT + STAKE_MULTIPLE - 1) / STAKE_MULTIPLE; // $420
    uint256 internal constant PANEL_STAKE = STAKE_FOR_AMOUNT + 100e6; // strictly higher tier

    uint256 internal chainId;

    function setUp() public virtual {
        buyer = vm.addr(buyerPk);
        seller = vm.addr(sellerPk);
        arb = vm.addr(arbPk);
        stranger = vm.addr(strangerPk);
        p1 = vm.addr(p1Pk);
        p2 = vm.addr(p2Pk);
        p3 = vm.addr(p3Pk);
        chainId = block.chainid;

        token = new MockERC20("MockUSDC", "USDC", 6);
        // Deploy order (Phase D): registry → clone factory → court → bind both
        // → implementations(factory, registry) → addTemplate.
        registry = new ArbitratorRegistry(
            IERC20(address(token)), STAKE_MULTIPLE, UNBONDING, SLA_DURATION, SLA_SLASH_BPS, OVERTURN_SLASH_BPS, 0, address(this)
        );
        factory = new EscrowCloneFactory(registry, feeRecipient, FEE_BPS, 0, address(this));
        court = new AppealCourt(registry);
        registry.setFactory(address(factory));
        registry.setCourt(address(court));
        stdImpl = new GhostEscrowV2CImpl(address(factory), registry, 25_000e6);
        openImpl = new GhostEscrowV2OpenCImpl(address(factory), registry, 25_000e6);
        factory.addTemplate(address(stdImpl));
        factory.addTemplate(address(openImpl));
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

    function _stakePanel() internal {
        _stake(p1, PANEL_STAKE, "p1");
        _stake(p2, PANEL_STAKE, "p2");
        _stake(p3, PANEL_STAKE, "p3");
    }

    // ─── initData / deal helpers ───────────────────────────────────────────

    function _initData(address _buyer, address _seller) internal view returns (bytes memory) {
        return abi.encode(
            address(token), _buyer, _seller, arb, AMOUNT, ARB_FEE, DEPOSIT_TIMEOUT, AUTO_RELEASE
        );
    }

    function _createStd(bytes32 userSalt) internal returns (GhostEscrowV2CImpl e) {
        e = GhostEscrowV2CImpl(factory.createDeal(address(stdImpl), _initData(buyer, seller), userSalt));
    }

    function _fund(address who, uint256 amt) internal {
        token.mint(who, amt);
    }

    function _fundActive(GhostEscrowV2CImpl e) internal {
        _fund(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(e), AMOUNT);
        vm.prank(buyer);
        e.deposit(AMOUNT);
        assertEq(uint256(e.state()), uint256(GhostEscrowV2CImpl.State.Active));
    }

    function _openDispute(GhostEscrowV2CImpl e) internal {
        _fund(buyer, ARB_FEE);
        vm.prank(buyer);
        token.approve(address(e), ARB_FEE);
        vm.prank(buyer);
        e.openDispute();
    }

    /// Full path to an appealed, drawn panel on a standard-template clone.
    function _toDrawnAppeal(GhostEscrowV2CImpl e) internal returns (uint256 bond) {
        _openDispute(e);
        vm.prank(arb);
        e.rule(0, AMOUNT, keccak256("ruling"));
        bond = (AMOUNT * e.APPEAL_BOND_BPS()) / 10000;
        _fund(buyer, bond);
        vm.prank(buyer);
        token.approve(address(e), bond);
        vm.prank(buyer);
        e.appeal();
        (,,,,,, uint256 drawBlock,) = court.caseOf(address(e));
        vm.roll(drawBlock + 1);
        court.drawPanel(address(e));
    }

    function _sig(uint256 pk, bytes32 digest_) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}
