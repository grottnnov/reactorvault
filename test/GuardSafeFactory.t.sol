// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GuardSafeFactory} from "../src/GuardSafeFactory.sol";
import {GuardVault} from "../src/GuardVault.sol";
import {RulesEngine} from "../src/RulesEngine.sol";
import {GuardItem} from "../src/IGuardVault.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";

/// @dev Records the executor-side registration calls.
contract MockGuardExecutor {
    mapping(address => bool) public known;

    function addGuardVault(address, address vault_) external {
        known[vault_] = true;
    }
}

/// @dev The client's door, red-first (D-2611-3). The factory composes
///      the deployed family: the vault is OWNED BY THE CLIENT, the
///      per-asset exchange adapter is created once and reused, the
///      executor admission is registered, and the onboarding event is
///      the exact shape the reactive brain arms itself on. The
///      full-loop test drives factory -> brain -> batch end to end.
contract GuardSafeFactoryTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant SOURCE_CHAIN = 11155111;
    uint256 constant GUARD_CHAIN = 4663;

    uint256 constant RATE_CHANGE_TOPIC = uint256(
        keccak256(
            "ReserveDataUpdated(uint256 indexed reserve,uint256 liquidityRate,uint256 stableBorrowRate,uint256 variableBorrowRate,uint256 liquidityIndex,uint256 variableBorrowIndex)"
        )
    );
    uint256 constant ANSWER_UPDATED = 0x0559884fd3a460db3073b7fc96cc77986f16e378210ded43186175bf646fc5f;

    uint256 constant PRICE = 100e8;

    OmniMockSystem sys;
    RulesEngine engine;
    MockGuardExecutor exec;
    MockFeed feed;
    GuardSafeFactory factory;

    address tsla = makeAddr("tsla");
    address usdg = makeAddr("usdg");
    address pm = makeAddr("poolManager");
    address quoter = makeAddr("quoter");
    address client = makeAddr("client");
    address clientB = makeAddr("clientB");
    address brainExecutor = makeAddr("executor");

    uint64 constant WARN = 500;
    uint64 constant MID = 1000;
    uint64 constant HARD = 2000;
    uint64 constant TARGET = 5000;
    uint64 constant BAND = 1000;
    uint64 constant COOLDOWN = 1 hours;
    uint64 constant MAX_STALE = 900;

    event GuardSafeCreated(
        address indexed client,
        address indexed vault,
        address indexed asset,
        address feed,
        uint8 level,
        uint256 entryRef,
        uint256 packedLadder,
        uint256 packedOps
    );

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        engine = new RulesEngine();
        engine.initialize(makeAddr("origin"), SOURCE_CHAIN, RATE_CHANGE_TOPIC, brainExecutor, SOURCE_CHAIN, 1 hours);
        engine.setExecutor(GUARD_CHAIN, brainExecutor);
        engine.setRule(SOURCE_CHAIN, RATE_CHANGE_TOPIC, false, 1 hours, SOURCE_CHAIN);

        exec = new MockGuardExecutor();
        feed = new MockFeed();
        factory = new GuardSafeFactory(address(exec), usdg, pm, quoter);
        factory.setSpectrumAsset(tsla, address(feed), 3000, 60, true);
        factory.setRiskLevel(1, WARN, MID, HARD, TARGET, BAND, COOLDOWN, MAX_STALE);

        vm.warp(4 hours);
        feed.setRound(int256(PRICE), block.timestamp);
    }

    function _packedLadder() private pure returns (uint256) {
        return uint256(WARN) | (uint256(MID) << 64) | (uint256(HARD) << 128) | (uint256(TARGET) << 192);
    }

    function _packedOps() private pure returns (uint256) {
        return uint256(BAND) | (uint256(COOLDOWN) << 64) | (uint256(MAX_STALE) << 128);
    }

    // ------------------------------------------------------------- creation

    function test_CreateGuardSafe_DeploysClientOwnedVault() public {
        vm.prank(client);
        address vault = factory.createGuardSafe(tsla, 1);

        assertEq(GuardVault(vault).owner(), client, "the CLIENT owns the safe");
        assertTrue(exec.known(vault), "registered with the executor");
        assertEq(GuardVault(vault).assetToken(), tsla);
        assertEq(GuardVault(vault).stableToken(), usdg);
        assertNotEq(factory.adapterOf(tsla), address(0), "the exchange adapter exists");
    }

    function test_SecondClient_NewVault_ReusedAdapter() public {
        vm.startPrank(client);
        address v1 = factory.createGuardSafe(tsla, 1);
        vm.stopPrank();
        address adapter1 = factory.adapterOf(tsla);

        vm.startPrank(clientB);
        address v2 = factory.createGuardSafe(tsla, 1);
        vm.stopPrank();

        assertNotEq(v1, v2, "every client gets their OWN safe");
        assertEq(factory.adapterOf(tsla), adapter1, "the per-asset adapter is reused");
        assertEq(GuardVault(v2).owner(), clientB);
        assertTrue(exec.known(v2));
    }

    function test_EventCarriesLiveEntryAndPreset() public {
        feed.setRound(int256(123e8), block.timestamp); // the live price at onboarding
        // the adapter consumes the first factory nonce, the vault the next
        uint64 n = uint64(vm.getNonce(address(factory)));
        address vaultExpected = vm.computeCreateAddress(address(factory), n + 1);
        vm.expectEmit(true, true, true, true);
        emit GuardSafeCreated(client, vaultExpected, tsla, address(feed), 1, 123e8, _packedLadder(), _packedOps());
        vm.prank(client);
        factory.createGuardSafe(tsla, 1);
    }

    // ------------------------------------------------------------- refusals

    function test_UnknownAsset_Refused() public {
        vm.prank(client);
        vm.expectRevert(GuardSafeFactory.AssetNotOfferable.selector);
        factory.createGuardSafe(makeAddr("junk"), 1);
    }

    function test_UnknownLevel_Refused() public {
        vm.prank(client);
        vm.expectRevert(GuardSafeFactory.LevelNotOfferable.selector);
        factory.createGuardSafe(tsla, 9);
    }

    function test_PausedOnboarding_Refused_ExistingUntouched() public {
        vm.prank(client);
        address vault = factory.createGuardSafe(tsla, 1);

        factory.setOnboardingPaused(true);
        vm.prank(clientB);
        vm.expectRevert(GuardSafeFactory.OnboardingPaused.selector);
        factory.createGuardSafe(tsla, 1);

        // the kill-switch touches ONLY the new-client surface
        assertEq(GuardVault(vault).owner(), client, "existing safes untouched");
        assertTrue(exec.known(vault));
    }

    function test_DeadFeed_Refused() public {
        feed.setRound(int256(0), block.timestamp);
        vm.prank(client);
        vm.expectRevert(GuardSafeFactory.DeadFeed.selector);
        factory.createGuardSafe(tsla, 1);
    }

    function test_BadLadder_Refused() public {
        vm.expectRevert(GuardSafeFactory.BadParams.selector);
        factory.setRiskLevel(2, 1000, 1000, 2000, 5000, 1000, COOLDOWN, MAX_STALE); // warn == mid
    }

    // ------------------------------------------------------------- the full loop

    /// The submission story in one test: the client creates a safe (the
    /// factory emits the event), the reactive brain arms the client rule
    /// from the event BY ITSELF, and the next price event produces the
    /// batched callback that names the client's vault.
    function test_FullLoop_FactoryEventArmsBrain() public {
        engine.setGuardFactory(GUARD_CHAIN, address(factory));

        vm.prank(client);
        address vault = factory.createGuardSafe(tsla, 1);

        // simulate the delivery of the onboarding event to the brain
        // (the topic read must happen BEFORE the prank: a staticcall
        // consumes it)
        uint256 createdTopic = engine.GUARD_SAFE_CREATED_TOPIC();
        vm.prank(OMNI_SYSTEM);
        engine.react(
            IReactive.LogRecord({
                chainId: GUARD_CHAIN,
                contractAddress: address(factory),
                topic0: createdTopic,
                topic1: uint256(uint160(client)),
                topic2: uint256(uint160(vault)),
                topic3: uint256(uint160(tsla)),
                data: abi.encode(address(feed), uint8(1), PRICE, _packedLadder(), _packedOps()),
                blockNumber: 500,
                opCode: 0,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );

        assertTrue(engine.guardClientActiveOf(GUARD_CHAIN, address(feed), vault), "the brain armed the client rule");
        assertEq(engine.guardClientCountOf(GUARD_CHAIN, address(feed)), 1);

        // the price cracks the hard rung: ONE batch, the item names the client's vault
        feed.setRound(int256(80e8), block.timestamp);
        vm.prank(OMNI_SYSTEM);
        engine.react(
            IReactive.LogRecord({
                chainId: GUARD_CHAIN,
                contractAddress: address(feed),
                topic0: ANSWER_UPDATED,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: abi.encode(int256(80e8), uint256(1), uint256(block.timestamp)),
                blockNumber: 501,
                opCode: 0,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );

        GuardItem[] memory items = new GuardItem[](1);
        items[0] = GuardItem({vault: vault, kind: 2, param: 10_000, param2: 0, bound: 80e8});
        bytes memory expected = abi.encodeWithSignature(
            "guardAction(address,address,address,uint256,(address,uint8,uint256,uint256,uint256)[])",
            address(0),
            address(feed),
            tsla,
            501,
            items
        );
        bool found = false;
        uint256 n = sys.callbackCount();
        for (uint256 i = 0; i < n; i++) {
            (,,, bytes memory p, address requester) = sys.callbackRequests(i);
            if (keccak256(p) == keccak256(expected) && requester == address(engine)) {
                found = true;
                break;
            }
        }
        assertTrue(found, "the batched callback names the client's vault, hard-exit");
    }
}
