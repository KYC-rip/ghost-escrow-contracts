// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GhostTestBase} from "./utils/GhostTestBase.sol";
import {EscrowFactory} from "../src/EscrowFactory.sol";
import {GhostEscrow} from "../src/GhostEscrow.sol";

/// @dev Cross-check: client-side CREATE2 prediction (TS, ethers) must match
///      the contract's predictAddress for identical fixtures.
contract Create2CrossCheckTest is GhostTestBase {
    function test_CrossCheck_ClientPredictionMatchesContract() public {
        // Fixtures identical to the TS cross-check (packages/ghost-escrow).
        address token_ = address(uint160(0x00a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48));
        address buyer_ = address(uint160(0x001111111111111111111111111111111111111111));
        address seller_ = address(uint160(0x002222222222222222222222222222222222222222));
        address arb_ = address(uint160(0x003333333333333333333333333333333333333333));
        address feeRecipient_ = address(uint160(0x00fee5deadbeefdeadbeefdeadbeefdeadbeefdead));
        address factoryAddr = address(uint160(0x004444444444444444444444444444444444444444));
        uint256 dealAmount_ = 4200e6;
        uint256 feeBps_ = 150;
        uint256 arbFee_ = 50e6;
        uint256 depTimeout_ = 259200;
        uint256 autoRel_ = 1209600;
        bytes32 salt = bytes32(uint256(0xabababababababababababababababababababababababababababababababab));

        // Deploy the factory at a fixed address via vm.etch (pure fixture: the
        // address itself is what matters for CREATE2 — init code is factory-
        // independent, but we need a contract at that address to deploy from).
        vm.etch(factoryAddr, address(new EscrowFactory(feeRecipient_, feeBps_)).code);
        EscrowFactory f = EscrowFactory(factoryAddr);

        EscrowFactory.Terms memory terms = EscrowFactory.Terms({
            token: token_,
            buyer: buyer_,
            seller: seller_,
            arbitrator: arb_,
            dealAmount: dealAmount_,
            arbitratorFee: arbFee_,
            depositTimeout: depTimeout_,
            autoReleaseDelay: autoRel_
        });

address predicted = f.predictAddress(terms, salt);
        // Client-side (TS/ethers) result for these exact fixtures — keeps the
        // frontend CREATE2 predictor honest with the contract.
        // Re-pinned 2026-10-28: the repo now compiles with via_ir (v5 size budget), which changes the LEGACY v1
        // GhostEscrow creation code and so this CREATE2 address. The v1 app path (embedded creationCode blobs) is
        // retired; deployed v1 deals are unaffected. Old value under the legacy pipeline: 0xe4887cfca592acb4ae9af41fb8008cd374a70001.
        assertEq(predicted, address(uint160(0x00f5d9d3920ebc0adffeaa0cdeb135d6e1dc044bbb)), "CREATE2 cross-check failed");
    }

    /// The creation code must be metadata-free (bytecode_hash = "none") —
    /// otherwise the frontend's embedded init code drifts across builds and a
    /// pre-funded predicted address never gets deployed to (stranded funds).
    function test_CreationCode_IsMetadataFree() public {
        bytes memory creationCode = type(GhostEscrow).creationCode;
        // IPFS metadata trailer marker (`a2 64 69706673 58 22`).
        bytes memory needle = hex"a264697066735822";
        bool metadataFound = false;
        for (uint256 i = 0; i + needle.length <= creationCode.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (creationCode[i + j] != needle[j]) { found = false; break; }
            }
            if (found) metadataFound = true;
        }
        assertFalse(metadataFound, "creation code contains IPFS metadata hash");
    }
}