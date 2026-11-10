// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasPayer} from "../src/GasPayer.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";

/// @dev Cashier v2 (ADR-v2): feed-free tariff (ETH-native), P2 fix (the
///      reserve subscription targets the GasVault battery), idempotency, eyes+cry.
contract GasPayerTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;

    uint256 constant T_ETHLOW = uint256(keccak256("ExecutorLowEth(uint256,uint256)"));
    uint256 constant T_RESERVE = uint256(keccak256("GasReserveUpdated(uint256)"));

    OmniMockSystem sys;
    GasPayer gp;
    address executor = makeAddr("executor");
    address vault = makeAddr("vault");

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        gp = new GasPayer(executor, vault, T_ETHLOW, T_RESERVE);
        gp.init();
        vm.deal(address(gp), 10 ether);
        vm.warp(2 hours);
    }

    function _log(uint256 chainId_, address contract_, uint256 topic0_, bytes memory data_, uint256 blockNumber_)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId_,
            contractAddress: contract_,
            topic0: topic0_,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: data_,
            blockNumber: blockNumber_,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _send(IReactive.LogRecord memory log_) internal {
        vm.prank(OMNI_SYSTEM);
        gp.react(log_);
    }

    function _ethLow(uint256 balance_, uint256 threshold_, uint256 blockNumber_) internal {
        _send(_log(11155111, executor, T_ETHLOW, abi.encode(balance_, threshold_), blockNumber_));
    }

    function _dropSelector(bytes memory payload_) internal pure returns (bytes memory) {
        bytes memory args = new bytes(payload_.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload_[i + 4];
        }
        return args;
    }

    function _reserve(uint256 weiAmount, uint256 blockNumber_) internal {
        _send(_log(11155111, vault, T_RESERVE, abi.encode(weiAmount), blockNumber_));
    }

    /// P2 fix: the reserve subscription targets VAULT (the emitter),
    /// not the executor.
    function testInitSubscribesReserveOnVault() public view {
        assertEq(sys.subscriptionCount(), 2);
        (uint256 sChain, address sContract, uint256 sTopic,,,,) = sys.subscriptions(0);
        assertEq(sChain, 11155111);
        assertEq(sContract, vault);
        assertEq(sTopic, T_RESERVE);
    }

    /// Full path: tank empty → a refuelEthTank(need, margin=10%) order.
    function testFullOrderPath() public {
        _reserve(2 ether, 100);
        _ethLow(0.1 ether, 1 ether, 101);

        assertEq(sys.callbackCount(), 1);
        (uint256 cChain, address cRec, uint64 cGas, bytes memory cPayload, address cReq) = sys.callbackRequests(0);
        assertEq(cChain, 11155111);
        assertEq(cRec, executor);
        assertEq(cGas, 1_000_000);
        assertEq(cReq, address(gp));

        (, uint256 need, uint256 margin) = abi.decode(_dropSelector(cPayload), (address, uint256, uint256));
        assertEq(need, 0.9 ether, "need = threshold - balance");
        assertEq(margin, 0.09 ether, "margin 10%");

        assertEq(gp.lastRefillAt(), block.timestamp);
        assertEq(gp.reserveWei(), 2 ether);
    }

    /// Cap clamp: need never exceeds refillCapWei.
    function testNeedClampedByCap() public {
        _reserve(10 ether, 100);
        _ethLow(0 ether, 5 ether, 101);
        (,,, bytes memory cPayload,) = sys.callbackRequests(0);
        (, uint256 need,) = abi.decode(_dropSelector(cPayload), (address, uint256, uint256));
        assertEq(need, 1 ether);
    }

    /// Reserve-mirror clamp: the client only pays with what they
    /// deposited.
    function testNeedClampedByReserveMirror() public {
        _reserve(0.2 ether, 100); // reserve below need+margin
        _ethLow(0.1 ether, 1 ether, 101);
        (,,, bytes memory cPayload,) = sys.callbackRequests(0);
        (, uint256 need, uint256 margin) = abi.decode(_dropSelector(cPayload), (address, uint256, uint256));
        assertEq(need + margin, 0.2 ether, "total = reserve");
        uint256 expectedNeed = (uint256(0.2 ether) * 100) / 110;
        assertEq(need, expectedNeed, "need = total*100/marginNum");
    }

    /// Reserve unseen (empty mirror) → the order ignores the mirror (we
    /// trust the threshold event; W2 adds a hard guard).
    function testNoReserveBelowMinAlerts() public {
        _reserve(0.001 ether, 100);
        vm.expectEmit(true, true, true, true);
        emit GasPayer.NoReserve();
        _ethLow(0.1 ether, 1 ether, 101);
        assertEq(sys.callbackCount(), 0);
    }

    /// Idempotency: a duplicate of the same event (chain, block, topic)
    /// — no second order goes out.
    function testDuplicateEventSingleOrder() public {
        _reserve(2 ether, 100);
        _ethLow(0.1 ether, 1 ether, 101);
        assertEq(sys.callbackCount(), 1);
        _ethLow(0.1 ether, 1 ether, 101); // duplicate
        assertEq(sys.callbackCount(), 1, "duplicate must not re-order");
    }

    /// Cooldown: a new event inside the cooldown window is silently
    /// skipped.
    function testCooldownBlocksRapidSecondOrder() public {
        _reserve(2 ether, 100);
        _ethLow(0.1 ether, 1 ether, 101);
        vm.warp(block.timestamp + 10 minutes);
        _ethLow(0.05 ether, 1 ether, 102);
        assertEq(sys.callbackCount(), 1, "cooldown must block");
    }

    /// A different block is not a duplicate: the order goes out (after
    /// the cooldown).
    function testDifferentBlockNewOrder() public {
        _reserve(2 ether, 100);
        _ethLow(0.1 ether, 1 ether, 101);
        vm.warp(block.timestamp + 2 hours);
        _ethLow(0.1 ether, 1 ether, 202);
        assertEq(sys.callbackCount(), 2);
    }

    /// Eyes+cry: eff = reserves−debts on SYSTEM below the floor → LowGas.
    function testOwnTankCryOnLowEff() public {
        vm.deal(OMNI_SYSTEM, 1 ether);
        OmniMockSystem(payable(OMNI_SYSTEM)).depositTo{value: 0.02 ether}(address(gp)); // reserves
        OmniMockSystem(payable(OMNI_SYSTEM)).setDebt(address(gp), 0.005 ether); // debts → eff=0.015 < floor 0.05

        vm.expectEmit(true, true, true, true);
        emit GasPayer.LowGas(0.015 ether, 0.3 ether);
        _reserve(1 ether, 100);
    }

    /// The cry is edge-triggered: a second react without recovery stays
    /// silent; recovery above the target → re-arm.
    function testCryEdgeTriggeredAndRearm() public {
        vm.deal(OMNI_SYSTEM, 1 ether);
        OmniMockSystem(payable(OMNI_SYSTEM)).depositTo{value: 0.02 ether}(address(gp));
        OmniMockSystem(payable(OMNI_SYSTEM)).setDebt(address(gp), 0.005 ether);

        vm.expectEmit(true, true, true, true);
        emit GasPayer.LowGas(0.015 ether, 0.3 ether);
        _reserve(1 ether, 100);

        // no recovery — no second cry
        _reserve(1 ether, 101);

        // recovery ≥ target → re-arm
        OmniMockSystem(payable(OMNI_SYSTEM)).setDebt(address(gp), 0);
        OmniMockSystem(payable(OMNI_SYSTEM)).depositTo{value: 0.4 ether}(address(gp));
        _reserve(1 ether, 102);
        assertTrue(gp.ownAlertArmed());

        // and a new dip — the cry again
        OmniMockSystem(payable(OMNI_SYSTEM)).setDebt(address(gp), 0.41 ether);
        vm.expectEmit(true, true, true, true);
        emit GasPayer.LowGas(0.01 ether, 0.3 ether);
        _reserve(1 ether, 103);
    }

    /// Debt without reserve: eff=0 → the cry (probe lesson: debt
    /// matters more than balance).
    function testCryOnDebtWithoutReserve() public {
        OmniMockSystem(payable(OMNI_SYSTEM)).setDebt(address(gp), 0.1 ether);
        vm.expectEmit(true, true, true, true);
        emit GasPayer.LowGas(0, 0.3 ether);
        _reserve(1 ether, 100);
    }
}

/// @dev Cashier v2: owner parameters.
contract GasPayerParamsTest is Test {
    function testTariffGuards() public {
        GasPayer gp = new GasPayer(makeAddr("e"), makeAddr("v"), 1, 2);
        vm.prank(gp.owner());
        gp.setTariff(110, 1 ether, 0.005 ether, 1 hours);
        vm.prank(gp.owner());
        vm.expectRevert(GasPayer.BadParams.selector);
        gp.setTariff(99, 1 ether, 0.005 ether, 1 hours); // margin below cost is denied
        vm.prank(gp.owner());
        vm.expectRevert(GasPayer.BadParams.selector);
        gp.setOwnTank(0.3 ether, 0.1 ether); // target ≤ floor is denied
    }
}
