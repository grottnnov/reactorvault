// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";

/// @title deployments.json guard: schema, hygiene, live cross-check
/// @dev The manifest is the single source of truth for addresses and
///      event topics (D-2511-2): the README points here, nothing
///      duplicates it. Offline part always runs - structure is sane
///      and the public-artifact hygiene holds (no secrets, no internal
///      paths). Live part runs when LASNA_RPC / SEPOLIA_RPC are set:
///      every address has code and its role getter answers - the live
///      cross-check canon (the USDC-was-LINK lesson, 09.11: never
///      trust an address without asking the chain).
contract DeploymentsManifestTest is Test {
    string json;

    uint256 constant CHAIN_LASNA = 5318007;
    uint256 constant CHAIN_SEPOLIA = 11155111;

    function setUp() public {
        json = vm.readFile("deployments.json");
    }

    // ------------------------------------------------------------------
    // Offline: public-artifact hygiene
    // ------------------------------------------------------------------

    function test_Hygiene_PublicArtifactOnly() public view {
        string[5] memory banned = ["PRIVATE", "SECRET", "internal/", ".secrets", ".env"];
        for (uint256 i = 0; i < banned.length; i++) {
            assertFalse(_contains(json, banned[i]), string.concat("manifest must never contain: ", banned[i]));
        }
    }

    // ------------------------------------------------------------------
    // Offline: schema
    // ------------------------------------------------------------------

    function test_Schema_TopLevel() public view {
        assertEq(vm.parseJsonString(json, ".name"), "reactorvault");
        assertEq(vm.parseJsonUint(json, ".manifestVersion"), 1, "manifestVersion");
        assertGt(bytes(vm.parseJsonString(json, ".description")).length, 0, "description");
        assertGt(vm.parseJsonKeys(json, ".chains").length, 0, "chains declared");
    }

    function test_Schema_ChainsHaveRpcAndExplorer() public view {
        string[] memory keys = vm.parseJsonKeys(json, ".chains");
        for (uint256 i = 0; i < keys.length; i++) {
            string memory base = string.concat(".chains.", keys[i]);
            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".name"))).length, 0);
            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".rpc"))).length, 0);
            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".explorer"))).length, 0);
        }
    }

    function test_Schema_Contracts() public view {
        uint256 n = vm.parseJsonArrayLength(json, ".contracts");
        assertGt(n, 0, "at least one contract");

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".contracts[", vm.toString(i), "]");

            address a = vm.parseJsonAddress(json, string.concat(base, ".address"));
            assertFalse(a == address(0), "zero address");

            uint256 chainId = vm.parseJsonUint(json, string.concat(base, ".chainId"));
            assertTrue(_chainDeclared(chainId), "chainId must be declared in .chains");

            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".name"))).length, 0);
            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".role"))).length, 0);

            string memory generation = vm.parseJsonString(json, string.concat(base, ".generation"));
            assertTrue(
                _contains(json, string.concat('"', generation, '":')), "generation must be described in .generations"
            );

            string memory status = vm.parseJsonString(json, string.concat(base, ".status"));
            assertTrue(
                keccak256(bytes(status)) == keccak256("live") || keccak256(bytes(status)) == keccak256("conserved")
                    || keccak256(bytes(status)) == keccak256("planned"),
                "status must be live | conserved | planned"
            );
        }

        // Within one chain, addresses must be unique.
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (_contractChain(i) != _contractChain(j)) continue;
                assertFalse(_contractAddress(i) == _contractAddress(j), "duplicate address within one chain");
            }
        }
    }

    function test_Schema_Events() public view {
        uint256 n = vm.parseJsonArrayLength(json, ".events");
        assertGt(n, 0, "at least one event");

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".events[", vm.toString(i), "]");

            bytes32 topic0 = vm.parseJsonBytes32(json, string.concat(base, ".topic0"));
            assertFalse(topic0 == bytes32(0), "zero topic0");

            uint256 chainId = vm.parseJsonUint(json, string.concat(base, ".chainId"));
            assertTrue(_chainDeclared(chainId), "event chainId must be declared");

            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".name"))).length, 0);
            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".contract"))).length, 0);
            assertGt(bytes(vm.parseJsonString(json, string.concat(base, ".meaning"))).length, 0);
        }
    }

    // ------------------------------------------------------------------
    // Live (skipped without RPC vars, CI-friendly): code + role getters
    // ------------------------------------------------------------------

    function test_Live_CodeAndRoleGetters() public {
        string memory lasna = vm.envOr("LASNA_RPC", string(""));
        string memory sepolia = vm.envOr("SEPOLIA_RPC", string(""));
        if (bytes(lasna).length == 0 && bytes(sepolia).length == 0) vm.skip(true);

        uint256 lasnaFork;
        uint256 sepoliaFork;
        bool lasnaOn = bytes(lasna).length > 0;
        bool sepoliaOn = bytes(sepolia).length > 0;
        if (lasnaOn) lasnaFork = vm.createFork(lasna);
        if (sepoliaOn) sepoliaFork = vm.createFork(sepolia);

        uint256 n = vm.parseJsonArrayLength(json, ".contracts");
        for (uint256 i = 0; i < n; i++) {
            uint256 chainId = _contractChain(i);
            if (chainId == CHAIN_LASNA) {
                if (!lasnaOn) continue;
                vm.selectFork(lasnaFork);
            } else if (chainId == CHAIN_SEPOLIA) {
                if (!sepoliaOn) continue;
                vm.selectFork(sepoliaFork);
            } else {
                continue; // planned chain: no live check yet
            }

            address a = _contractAddress(i);

            uint256 size;
            assembly {
                size := extcodesize(a)
            }
            assertGt(size, 0, string.concat("no code at ", vm.toString(a)));

            // Optional role getter: the semantic cross-check.
            string memory base = string.concat(".contracts[", vm.toString(i), "]");
            string memory sig = vm.parseJsonString(json, string.concat(base, ".semantics"), "");
            if (bytes(sig).length == 0) continue;
            (bool ok, bytes memory ret) = a.call(abi.encodeWithSignature(sig));
            assertTrue(ok, string.concat("role getter failed: ", sig));
            assertEq(ret.length, 32, string.concat("role getter must return uint256: ", sig));
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _contractChain(uint256 i) internal view returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".contracts[", vm.toString(i), "].chainId"));
    }

    function _contractAddress(uint256 i) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".contracts[", vm.toString(i), "].address"));
    }

    function _chainDeclared(uint256 chainId) internal view returns (bool) {
        // chain keys are the ids themselves: ".chains.5318007"
        string[] memory keys = vm.parseJsonKeys(json, ".chains");
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(vm.toString(chainId)))) {
                return true;
            }
        }
        return false;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory nd = bytes(needle);
        if (nd.length == 0 || h.length < nd.length) return false;
        for (uint256 i = 0; i + nd.length <= h.length; i++) {
            uint256 j = 0;
            while (j < nd.length && h[i + j] == nd[j]) {
                ++j;
            }
            if (j == nd.length) return true;
        }
        return false;
    }
}
