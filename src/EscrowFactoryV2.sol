// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostEscrowV2} from "./GhostEscrowV2.sol";
import {GhostEscrowV2Open} from "./GhostEscrowV2Open.sol";
import {ArbitratorRegistry} from "./ArbitratorRegistry.sol";

/**
 * @title EscrowFactoryV2 — Arbitrator Model v2 (Phase A)
 * @notice Registry-aware factory (versioned template, §5.7): deploys one
 *         immutable GhostEscrowV2 per deal for NEW deals only. The factory
 *         holds no funds and has no admin powers.
 *
 * @dev Eligibility gate (§5.1-C, LOCKED): createEscrow reverts unless the
 *      chosen arbitrator is currently bonded and eligible for the deal's
 *      value (registry.isEligible). Combined with the v2 escrow's
 *      replaceArbitrator re-check, every arbitrator that can rule is bonded.
 *
 *      Existing EscrowFactory + GhostEscrow (v1.1) deals are untouched — the
 *      v2 template only applies to deals created through this factory.
 */
contract EscrowFactoryV2 {
    ArbitratorRegistry public immutable registry;
    address public immutable feeRecipient;
    uint256 public immutable platformFeeBps; // e.g. 150 = 1.5%

    /// @dev Authenticates escrow→registry hooks (Phase B): every deal this
    ///      factory deploys is recorded here, append-only, so the registry can
    ///      trust only genuine factory-deployed escrows to mutate assignment.
    mapping(address => bool) public isEscrow;

    event EscrowCreated(
        address indexed escrow,
        address indexed buyer,
        address indexed seller,
        address arbitrator,
        address token,
        uint256 amount
    );

    constructor(ArbitratorRegistry _registry, address _feeRecipient, uint256 _platformFeeBps) {
        require(address(_registry) != address(0), "zero registry");
        require(_feeRecipient != address(0), "zero");
        require(_platformFeeBps <= 1000, "fee too high");
        registry = _registry;
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
        // NOTE: the registry's factory binding is set by the DEPLOYER after
        // this constructor (registry.setFactory(address(this)), deployer-gated
        // — see ArbitratorRegistry). Never bind from this constructor: the
        // factory isn't the registry's deployer.
    }

    struct Terms {
        address token; // vet at the app layer: standard ERC-20s only
        address buyer;
        address seller;
        address arbitrator;
        uint256 dealAmount;
        uint256 arbitratorFee;
        uint256 depositTimeout; // e.g. 72h = 259200
        uint256 autoReleaseDelay; // per-deal, escrow enforces 1-90 days
    }

    function createEscrow(Terms calldata t, bytes32 salt) external returns (address escrow) {
        // §5.1-C eligibility gate: the arbitrator must be bonded >= deal tier.
        require(registry.isEligible(t.arbitrator, t.dealAmount), "arb not eligible");
        // C-5: the court must be bound before any deal is created, so every
        // escrow can resolve registry.court() for the appeal path. The deploy
        // order is registry → factory → court → deployer binds setFactory+setCourt.
        require(registry.court() != address(0), "no court");
        escrow = address(
            new GhostEscrowV2{salt: salt}(
                t.token,
                t.buyer,
                t.seller,
                t.arbitrator,
                feeRecipient,
                t.dealAmount,
                platformFeeBps,
                t.arbitratorFee,
                t.depositTimeout,
                t.autoReleaseDelay,
                registry
            )
        );
        isEscrow[escrow] = true;
        emit EscrowCreated(escrow, t.buyer, t.seller, t.arbitrator, t.token, t.dealAmount);
    }

    /// @notice Open (deploy-then-join) variant: deploy a deal with ONE party slot
    ///         open (t.buyer or t.seller == address(0)); a claimant fills it once
    ///         via join(). Same eligibility + court gates; the escrow constructor
    ///         enforces exactly-one-open. Stable address (open slot encoded as 0).
    function createOpenEscrow(Terms calldata t, bytes32 salt) external returns (address escrow) {
        require(registry.isEligible(t.arbitrator, t.dealAmount), "arb not eligible");
        require(registry.court() != address(0), "no court");
        escrow = address(
            new GhostEscrowV2Open{salt: salt}(
                t.token,
                t.buyer,
                t.seller,
                t.arbitrator,
                feeRecipient,
                t.dealAmount,
                platformFeeBps,
                t.arbitratorFee,
                t.depositTimeout,
                t.autoReleaseDelay,
                registry
            )
        );
        isEscrow[escrow] = true;
        emit EscrowCreated(escrow, t.buyer, t.seller, t.arbitrator, t.token, t.dealAmount);
    }

    /// @notice Precompute the open-deal address (open slot passed as address(0)).
    function predictOpenAddress(Terms calldata t, bytes32 salt) external view returns (address) {
        bytes memory args = abi.encode(
            t.token,
            t.buyer,
            t.seller,
            t.arbitrator,
            feeRecipient,
            t.dealAmount,
            platformFeeBps,
            t.arbitratorFee,
            t.depositTimeout,
            t.autoReleaseDelay,
            address(registry)
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(GhostEscrowV2Open).creationCode, args));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    /// @notice Precompute the deal address for a given salt + terms (fund before deploy).
    function predictAddress(Terms calldata t, bytes32 salt) external view returns (address) {
        bytes memory args = abi.encode(
            t.token,
            t.buyer,
            t.seller,
            t.arbitrator,
            feeRecipient,
            t.dealAmount,
            platformFeeBps,
            t.arbitratorFee,
            t.depositTimeout,
            t.autoReleaseDelay,
            address(registry)
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(GhostEscrowV2).creationCode, args));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
