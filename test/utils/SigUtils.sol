// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev EIP-712 helpers mirroring GhostEscrow's domain + typehashes.
library SigUtils {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant RELEASE_TYPEHASH = keccak256("Release(uint256 nonce,uint256 deadline)");
    bytes32 internal constant REFUND_TYPEHASH = keccak256("Refund(uint256 nonce,uint256 deadline)");
    bytes32 internal constant SPLIT_TYPEHASH = keccak256("Split(uint256 buyerAmount,uint256 nonce,uint256 deadline)");
    bytes32 internal constant REPLACE_ARB_TYPEHASH =
        keccak256("ReplaceArbitrator(address newArbitrator,uint256 nonce,uint256 deadline)");
    bytes32 internal constant RESCUE_TYPEHASH =
        keccak256("RescueToken(address token,address to,uint256 nonce,uint256 deadline)");

    bytes32 internal constant NAME_HASH = keccak256("GhostEscrow");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    function domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, verifyingContract));
    }

    function digest(address verifyingContract, uint256 chainId, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(verifyingContract, chainId), structHash));
    }

    function releaseDigest(address verifyingContract, uint256 chainId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return digest(verifyingContract, chainId, keccak256(abi.encode(RELEASE_TYPEHASH, nonce, deadline)));
    }

    function refundDigest(address verifyingContract, uint256 chainId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return digest(verifyingContract, chainId, keccak256(abi.encode(REFUND_TYPEHASH, nonce, deadline)));
    }

    function splitDigest(
        address verifyingContract,
        uint256 chainId,
        uint256 buyerAmount,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return digest(verifyingContract, chainId, keccak256(abi.encode(SPLIT_TYPEHASH, buyerAmount, nonce, deadline)));
    }

    function replaceArbDigest(
        address verifyingContract,
        uint256 chainId,
        address newArb,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return digest(verifyingContract, chainId, keccak256(abi.encode(REPLACE_ARB_TYPEHASH, newArb, nonce, deadline)));
    }

    function rescueDigest(
        address verifyingContract,
        uint256 chainId,
        address token,
        address to,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return digest(verifyingContract, chainId, keccak256(abi.encode(RESCUE_TYPEHASH, token, to, nonce, deadline)));
    }
}
