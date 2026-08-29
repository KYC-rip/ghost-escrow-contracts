// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ArbitratorRegistry} from "./ArbitratorRegistry.sol";

/// @dev Every template implementation exposes this one-shot initializer; the
///      factory calls it atomically in the clone's CREATE2 deploy tx. The
///      template ABI-decodes its own canonical terms tuple from `initData`
///      and enforces the eligibility + court gates itself (vetted by the
///      TEMPLATE_CURATION.md checklist — the factory cannot introspect
///      template-specific terms).
interface IEscrowTemplate {
    function initialize(address feeRecipient, uint256 platformFeeBps, bytes calldata initData) external;
}

/**
 * @title EscrowCloneFactory — versioned escrow templates via EIP-1167 clones (Phase D)
 * @notice Deploys one minimal-proxy clone per deal, pointing at a CURATED,
 *         APPEND-ONLY list of immutable template implementations. Replaces the
 *         creation-code-embedding EscrowFactoryV2 (EIP-170 wall) and makes
 *         future template releases a single `addTemplate` instead of a full
 *         registry/factory/court rotation. The factory holds no funds and has
 *         no power over any deployed deal.
 *
 * @dev Address↔terms binding: with clones, the CREATE2 init code is the
 *      generic 1167 proxy, so the SALT carries the commitment — it is derived
 *      internally from (implementation, keccak256(initData), userSalt).
 *      Callers can never supply a raw salt; every byte of the terms a template
 *      decodes is inside the clone's address. feeRecipient/platformFeeBps are
 *      factory immutables, committed via the factory (deployer) address in
 *      the CREATE2 formula.
 *
 * @dev Curator trust boundary (plan §2.5, review D-REV-2/3): the curator's
 *      ONLY power is appending vetted template implementations (after a
 *      public `activationDelay` timelock — 0 on testnet profiles, 48h on
 *      mainnet). It can never remove or mutate templates, never touch deals,
 *      stakes, fees, or the registry/court bindings, and can renounce to
 *      freeze the list forever. Hook access to the shared registry is scoped
 *      to clones THIS factory deployed (isEscrow), so unvetted code can never
 *      reach the registry hooks or the court — the open-registration griefing
 *      class (pinning an arbitrator's openCases) is closed by curation.
 *      Documented residual: a vetted-but-buggy template with an unbounded
 *      dispute lifecycle could still pin openCases — and its sharper variant,
 *      auto-opened disputes ripening into SLA slashes against unaware
 *      arbitrators (review F1) — which is why the curation checklist makes a
 *      bounded, party-initiated dispute lifecycle a hard requirement.
 *
 * @dev CREATE2 squatting is impossible here (review F5): the predicted clone
 *      address commits to THIS factory as the CREATE2 deployer, so no third
 *      party can pre-deploy at a predicted address, and initialize runs in
 *      the same tx as the deploy — the classic squat/front-run class of
 *      griefing does not exist for these deals.
 */
contract EscrowCloneFactory {
    ArbitratorRegistry public immutable registry;
    address public immutable feeRecipient;
    uint256 public immutable platformFeeBps; // e.g. 150 = 1.5%
    /// Template activation timelock (constructor constant): watchers get this
    /// long to diff a newly-added template's codehash before any deal can use it.
    uint256 public immutable activationDelay;

    /// Append-only template curator; renounceable (=> list frozen forever).
    address public curator;

    struct Template {
        bool listed;
        uint64 activatesAt;
    }

    mapping(address => Template) public templates;
    address[] public templateList;

    /// @dev Authenticates escrow→registry hooks: every clone this factory
    ///      deploys is recorded here, append-only (same contract-auth surface
    ///      the registry trusted in EscrowFactoryV2).
    mapping(address => bool) public isEscrow;
    /// @dev Which template a clone delegates to — forever (clones are immutable).
    mapping(address => address) public implementationOf;

    event TemplateAdded(address indexed implementation, bytes32 codehash, uint256 activatesAt);
    event CuratorRenounced(address indexed lastCurator);
    event EscrowCreated(address indexed escrow, address indexed implementation, bytes32 initDataHash);

    constructor(ArbitratorRegistry _registry, address _feeRecipient, uint256 _platformFeeBps, uint256 _activationDelay) {
        require(address(_registry) != address(0), "zero registry");
        require(_feeRecipient != address(0), "zero");
        require(_platformFeeBps <= 1000, "fee too high");
        registry = _registry;
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
        activationDelay = _activationDelay;
        curator = msg.sender;
        // NOTE: the registry's factory binding is set by the REGISTRY deployer
        // after this constructor (registry.setFactory(address(this))) — never
        // from here; this factory isn't the registry's deployer.
    }

    // ─── Template curation (append-only + timelock + renounce) ───────────────

    function addTemplate(address implementation) external {
        require(msg.sender == curator, "not curator");
        require(implementation.code.length > 0, "no code");
        require(!templates[implementation].listed, "listed");
        uint256 activatesAt = block.timestamp + activationDelay;
        templates[implementation] = Template({listed: true, activatesAt: uint64(activatesAt)});
        templateList.push(implementation);
        emit TemplateAdded(implementation, implementation.codehash, activatesAt);
    }

    function renounceCurator() external {
        require(msg.sender == curator, "not curator");
        emit CuratorRenounced(curator);
        curator = address(0);
    }

    function templateCount() external view returns (uint256) {
        return templateList.length;
    }

    // ─── Deal creation (clone + atomic initialize) ───────────────────────────

    /// @notice Deploy a deal as a deterministic clone of an ACTIVE template and
    ///         initialize it in the same transaction. The clone is recorded in
    ///         isEscrow BEFORE initialize so the template's init-time registry
    ///         views run against an authenticated deal.
    function createDeal(address implementation, bytes calldata initData, bytes32 userSalt)
        external
        returns (address escrow)
    {
        Template memory t = templates[implementation];
        require(t.listed, "unknown template");
        require(block.timestamp >= t.activatesAt, "template not active");

        bytes32 salt = keccak256(abi.encode(implementation, keccak256(initData), userSalt));
        escrow = Clones.cloneDeterministic(implementation, salt);
        isEscrow[escrow] = true;
        implementationOf[escrow] = implementation;
        IEscrowTemplate(escrow).initialize(feeRecipient, platformFeeBps, initData);
        emit EscrowCreated(escrow, implementation, keccak256(initData));
    }

    /// @notice Predict a deal's address without bytecode knowledge (the app's
    ///         old creationCode blobs are obsolete): same salt derivation as
    ///         createDeal over the standard 1167 proxy init code.
    function predictAddress(address implementation, bytes calldata initData, bytes32 userSalt)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(implementation, keccak256(initData), userSalt));
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }
}
