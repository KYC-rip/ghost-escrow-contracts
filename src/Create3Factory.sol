// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Create3Factory — initcode-independent deterministic deployment
 * @notice Vendored minimal CREATE3 (A1: no external dependency; in audit scope).
 *         `deploy` puts a contract at an address that depends ONLY on
 *         (this factory, msg.sender, salt) — never on the contract's initcode
 *         or constructor args. That is what makes one ground salt yield the
 *         SAME address on every chain even when constructor args differ per
 *         chain (e.g. the registry's staking-token address).
 *
 * @dev Mechanism (the classic CREATE3 pattern):
 *      1. CREATE2 a fixed 16-byte proxy with a caller-namespaced salt
 *         (`keccak256(msg.sender ‖ salt)` — nobody can squat another
 *         deployer's ground address).
 *      2. The proxy, at its nonce 1, plain-CREATEs the real contract from the
 *         calldata it is handed, then self-effaces into inertness (it keeps no
 *         code path to deploy twice: CREATE at nonce 1 can happen once).
 *      Final address = keccak256(rlp([proxy, 1]))[12:] — initcode-free.
 *
 *      PROXY BYTECODE IS FROZEN (A1): the proxy initcode participates in the
 *      address derivation, so changing a single byte invalidates every ground
 *      salt. `PROXY_INITCODE_HASH` is exposed on-chain and pinned in
 *      vanity-salts.json; the grinder and DeployV assert against it.
 *
 *      Proxy initcode `0x67363d3d37363d34f03d5260086018f3` disassembles to:
 *      PUSH8 0x363d3d37363d34f0; RETURNDATASIZE; MSTORE; PUSH1 8; PUSH1 24;
 *      RETURN — i.e. it returns the 8-byte runtime `363d3d37363d34f0`:
 *      CALLDATASIZE COPY; CALLVALUE CREATE — "deploy whatever you call me with".
 */
contract Create3Factory {
    bytes internal constant PROXY_INITCODE = hex"67363d3d37363d34f03d5260086018f3";

    event Deployed(address indexed deployer, bytes32 indexed salt, address addr);

    /// @notice Pinned derivation constant (see contract natspec).
    function PROXY_INITCODE_HASH() public pure returns (bytes32) {
        return keccak256(PROXY_INITCODE);
    }

    /// @notice Deploy `creationCode` at the deterministic address for
    ///         (msg.sender, salt). Reverts if that address is already used —
    ///         one salt, one contract, forever.
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed) {
        bytes32 namespaced = keccak256(abi.encodePacked(msg.sender, salt));
        deployed = _predictFromNamespaced(namespaced);
        require(deployed.code.length == 0, "already deployed");

        bytes memory proxyInit = PROXY_INITCODE;
        address proxy;
        assembly {
            proxy := create2(0, add(proxyInit, 0x20), mload(proxyInit), namespaced)
        }
        require(proxy != address(0), "proxy failed");

        (bool ok,) = proxy.call{value: msg.value}(creationCode);
        require(ok && deployed.code.length != 0, "deploy failed");
        emit Deployed(msg.sender, salt, deployed);
    }

    /// @notice The address (deployer, salt) will land on — chain-independent
    ///         given this factory sits at the same address on every chain.
    function predict(address deployer, bytes32 salt) external view returns (address) {
        return _predictFromNamespaced(keccak256(abi.encodePacked(deployer, salt)));
    }

    function _predictFromNamespaced(bytes32 namespaced) internal view returns (address) {
        address proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), namespaced, PROXY_INITCODE_HASH()))))
        );
        // rlp([proxy, 1]): 0xd6 = list, 22 bytes payload; 0x94 = 20-byte string.
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }
}
