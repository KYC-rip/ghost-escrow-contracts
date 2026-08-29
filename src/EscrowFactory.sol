// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostEscrow} from "./GhostEscrow.sol";

/**
 * @title EscrowFactory (reference v1.1)
 * @notice Deploys one immutable GhostEscrow per deal. The factory holds no
 *         funds and has no admin powers.
 *
 * @dev Privacy — the honest version: keeping no on-chain registry mapping is
 *      NOT what protects parties; the EscrowCreated event below is itself a
 *      public, indexable list of every deal with buyer / seller / arbitrator.
 *      Real unlinkability comes from per-deal burner wallets. The event is
 *      kept because indexers need it; anyone building on this should not
 *      repeat v1's claim that the absent registry hides anything.
 *
 *      CREATE2 lets a client precompute the deal's address (predictAddress)
 *      and fund it — including via a Monero->USDC swap straight into that
 *      address — BEFORE the contract is deployed. After deploy, a
 *      permissionless syncDeposit() credits the direct transfer to the buyer
 *      (v1 stranded such funds).
 */
contract EscrowFactory {
    address public immutable feeRecipient;
    uint256 public immutable platformFeeBps; // e.g. 150 = 1.5%, hard-capped in the escrow

    event EscrowCreated(
        address indexed escrow,
        address indexed buyer,
        address indexed seller,
        address arbitrator,
        address token,
        uint256 amount
    );

    constructor(address _feeRecipient, uint256 _platformFeeBps) {
        require(_feeRecipient != address(0), "zero");
        require(_platformFeeBps <= 1000, "fee too high");
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
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
        escrow = address(
            new GhostEscrow{salt: salt}(
                t.token,
                t.buyer,
                t.seller,
                t.arbitrator,
                feeRecipient,
                t.dealAmount,
                platformFeeBps,
                t.arbitratorFee,
                t.depositTimeout,
                t.autoReleaseDelay
            )
        );
        emit EscrowCreated(escrow, t.buyer, t.seller, t.arbitrator, t.token, t.dealAmount);
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
            t.autoReleaseDelay
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(GhostEscrow).creationCode, args));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
