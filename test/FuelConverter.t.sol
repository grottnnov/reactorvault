// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FuelConverter, FuelBuyer, IFuelSource} from "../src/FuelConverter.sol";
import {OmniMockSystem} from "./mocks/OmniMockSystem.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";

/// @dev Auto-faucet (ADR-v2): the depot's HorizonAlert → a fuel
///      purchase order. FuelBuyer: delivery guards and a balance clamp.
///      FuelConverter: level gate, per-block idempotency, cooldown.
contract MockFaucet is IFuelSource {
    uint256 public received;
    address public lastRecipient;
    bool public broken;

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function request(address recipient) external payable {
        require(!broken, "faucet down");
        received += msg.value;
        lastRecipient = recipient;
    }
}

contract FuelConverterTest is Test {
    address internal constant OMNI_SYSTEM = 0x8888888888888888888888888888888888888888;
    /// @dev The live Sepolia callback proxy (verified by the 08.11
    ///      probe) — imitates the real callback deliverer in
    ///      testLiveDeliveryFromProxy.
    address internal constant SEPOLIA_PROXY = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    uint256 constant T_HORIZON = uint256(keccak256("HorizonAlert(uint256,uint256,uint256,uint8)"));
    uint256 constant T_FUNDED = uint256(keccak256("Funded(address,uint256)"));
    /// @dev The live faucet payer on Lasna: Funded(block 8 490 015,
    ///      16.11, payout 2.0 lREACT for a 0.02 ETH purchase — rate 1:100).
    address internal constant FAUCET_RVM = 0x5cBC52A390E69D9193996AeBFB53F7b97DB6cf51;

    OmniMockSystem sys;
    FuelConverter converter;
    FuelBuyer buyer;
    MockFaucet faucet;
    address fund = makeAddr("fund");

    function setUp() public {
        OmniMockSystem impl = new OmniMockSystem();
        vm.etch(OMNI_SYSTEM, address(impl).code);
        sys = OmniMockSystem(payable(OMNI_SYSTEM));

        // The converter<->buyer circular dependency is broken by
        // precompute — the order mirrors the live deploy 1:1: the
        // buyer's future address -> converter (it needs the address)
        // -> buyer (the converter is already real, goes into immutable).
        address buyerAddr = _create1(address(this), vm.getNonce(address(this)) + 1);
        converter = new FuelConverter(5318007, 11155111, fund, buyerAddr, T_HORIZON, T_FUNDED, FAUCET_RVM);
        buyer = new FuelBuyer(IPayable(payable(SEPOLIA_PROXY)), address(converter), fund);
        faucet = new MockFaucet();

        assertEq(address(buyer), buyerAddr, "precompute must match live deploy order");

        vm.startPrank(buyer.owner());
        buyer.setFaucet(faucet);
        vm.stopPrank();

        converter.init();
        vm.deal(address(buyer), 1 ether);
        vm.warp(2 hours);
    }

    /// @dev The address of a future CREATE deployment (nonce < 0x80):
    ///      the keccak(rlp([deployer, nonce])) formula — a replacement
    ///      for vm.computeAddress, absent from this forge-std version.
    function _create1(address deployer_, uint256 nonce_) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer_, uint8(nonce_))))));
    }

    function _horizon(uint8 level, uint256 blockNumber_) internal {
        vm.prank(OMNI_SYSTEM);
        converter.react(
            IReactive.LogRecord({
                chainId: 11155111,
                contractAddress: fund,
                topic0: T_HORIZON,
                topic1: 0,
                topic2: 0,
                topic3: 0,
                data: abi.encode(uint256(15), 3 ether, 0.2 ether, level),
                blockNumber: blockNumber_,
                opCode: 0,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
    }

    function _buyCallback(uint256 blockNumber_) internal {
        vm.prank(SEPOLIA_PROXY);
        buyer.buyFuel{value: 0}(address(converter), blockNumber_);
    }

    /// @dev A live Funded delivery: the faucet pays (topic1) to the depot.
    function _funded(address payer, uint256 amount, uint256 blockNumber_) internal {
        vm.prank(OMNI_SYSTEM);
        converter.react(
            IReactive.LogRecord({
                chainId: 5318007,
                contractAddress: fund,
                topic0: T_FUNDED,
                topic1: uint256(uint160(payer)),
                topic2: 0,
                topic3: 0,
                data: abi.encode(amount),
                blockNumber: blockNumber_,
                opCode: 0,
                blockHash: 0,
                txHash: 0,
                logIndex: 0
            })
        );
    }

    /// Init: TWO subscriptions to the depot — the horizon AND the
    /// payout telemetry. Both live on Lasna (5318007); a subscription
    /// in chain 11155111 would listen to a nonexistent emitter (a live
    /// trap caught during W2 deploy prep — the Sepolia-emitter
    /// premortem of ADR-PURCHASE-SAFETY).
    function testInitSubscribes() public view {
        assertEq(sys.subscriptionCount(), 2);
        (uint256 sChain, address sContract, uint256 sTopic0,,,,) = sys.subscriptions(0);
        assertEq(sChain, 5318007, "fund lives on Lasna, not Sepolia");
        assertEq(sContract, fund);
        assertEq(sTopic0, T_HORIZON);
        (sChain, sContract, sTopic0,,,,) = sys.subscriptions(1);
        assertEq(sChain, 5318007, "Funded is emitted on Lasna, not the destination chain");
        assertEq(sContract, fund);
        assertEq(sTopic0, T_FUNDED);
    }

    /// Full path: a level-1 escalation → order → callback → the faucet
    /// received ETH, the recipient is the depot.
    function testFullBuyPath() public {
        _horizon(1, 100);
        assertEq(sys.callbackCount(), 1);
        (uint256 cChain, address cRec, uint64 cGas, bytes memory cPayload, address cReq) = sys.callbackRequests(0);
        assertEq(cChain, 11155111);
        assertEq(cRec, address(buyer));
        assertEq(cReq, address(converter));

        // Execution — as a live callback: the deliverer is the proxy,
        // the sender slot is network-injected as the converter.
        vm.prank(SEPOLIA_PROXY);
        buyer.buyFuel(address(converter), 100);

        assertEq(faucet.received(), 0.02 ether);
        assertEq(faucet.lastRecipient(), fund);
        assertEq(buyer.buysCount(), 1);
        assertEq(buyer.totalSpentWei(), 0.02 ether);
    }

    /// Level 0 (stock > 30 days) — no order.
    function testLevelZeroNoOrder() public {
        _horizon(0, 100);
        assertEq(sys.callbackCount(), 0);
    }

    /// Idempotency: a duplicate escalation of the same block — one order.
    function testDuplicateBlockSingleOrder() public {
        _horizon(1, 100);
        _horizon(1, 100);
        assertEq(sys.callbackCount(), 1);
    }

    /// Cooldown: a new escalation of a different block inside the
    /// window — stay silent.
    function testCooldownBlocks() public {
        _horizon(1, 100);
        vm.warp(block.timestamp + 1 hours);
        _horizon(2, 200);
        assertEq(sys.callbackCount(), 1, "cooldown");

        vm.warp(block.timestamp + 12 hours);
        _horizon(2, 300);
        assertEq(sys.callbackCount(), 2);
    }

    /// Incident 11.11 (live W2.1): the faucet reverted once at the
    /// delivery moment — the whole buy rolled back, and with the depot
    /// silent at a latched level the autocrow died forever. Contract
    /// floor: a transient faucet failure must self-heal — the repeated
    /// alert (the depot re-emits while the level holds) + the converter
    /// cooldown produce a second order that succeeds.
    function testTransientFaucetFailureSelfHeals() public {
        faucet.setBroken(true);
        _horizon(1, 100);
        assertEq(sys.callbackCount(), 1);

        // The delivery arrived; the buy reverted entirely (state rolled
        // back — buysCount never moved, exactly the live picture).
        vm.prank(SEPOLIA_PROXY);
        vm.expectRevert("faucet down");
        buyer.buyFuel(address(converter), 100);
        assertEq(buyer.buysCount(), 0);

        // The alert repeats after the cooldown window (boundary: the
        // guard is inclusive — `ts <= last + cd` — so exactly 12h is
        // still silent); the faucet has recovered; the retry buys.
        vm.warp(block.timestamp + 12 hours + 1 seconds);
        faucet.setBroken(false);
        _horizon(1, 400);
        assertEq(sys.callbackCount(), 2, "second order after cooldown");
        vm.prank(SEPOLIA_PROXY);
        buyer.buyFuel(address(converter), 400);
        assertEq(buyer.buysCount(), 1);
        assertEq(faucet.received(), 0.02 ether);
    }

    /// FuelBuyer: live-delivery guards — the proxy only (msg.sender)
    /// AND the converter only (the injected sender slot).
    function testBuyerDeliveryGuards() public {
        // Right deliverer, wrong sender slot
        vm.prank(SEPOLIA_PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xdead), address(converter))
        );
        buyer.buyFuel(address(0xdead), 1);

        // Right sender slot, but the call does not come from the proxy
        // (directly from the converter)
        vm.prank(address(converter));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(converter), SEPOLIA_PROXY));
        buyer.buyFuel(address(converter), 1);
    }

    /// FuelBuyer: balance clamp; an empty tank is an honest revert.
    function testBuyerClampAndEmpty() public {
        vm.deal(address(buyer), 0.005 ether); // below buyAmount
        vm.prank(SEPOLIA_PROXY);
        buyer.buyFuel(address(converter), 1);
        assertEq(faucet.received(), 0.005 ether, "clamped to balance");

        vm.deal(address(buyer), 0);
        vm.prank(SEPOLIA_PROXY);
        vm.expectRevert(FuelBuyer.BuyFailed.selector);
        buyer.buyFuel(address(converter), 2);
    }

    /// Live callback delivery (the 08.11 probe canon): the callback
    /// arrives FROM THE PROXY (msg.sender = the Sepolia proxy), the
    /// network replaces the first payload slot with the source — the
    /// converter. This test caught the W2 deploy trap: a
    /// msg.sender==converter guard rejected live callbacks.
    function testLiveDeliveryFromProxy() public {
        _horizon(1, 100);
        assertEq(sys.callbackCount(), 1);

        vm.prank(SEPOLIA_PROXY);
        buyer.buyFuel(address(converter), 100);
        assertEq(faucet.received(), 0.02 ether);
        assertEq(buyer.buysCount(), 1);
    }

    /// Incident #16 (13.11): ACTION_GAS_LIMIT must survive the proxy's
    /// gas haircut — the proxy withholds ~200k of the ordered limit, and
    /// the live buyFuel call needs 260 850 (fork measurement against
    /// the real faucet; a mock would understate it). 300k caused a
    /// silent OOG: a "successful" delivery, a diagnostic proxy event,
    /// buys=0, the delivery fee paid. Invariant: what reaches the call
    /// (order − 200k) ≥ live need × 1.4.
    function testActionGasLimitSurvivesProxyHaircut() public {
        uint256 liveBuyFuelGas = 260_850; // fork-measured 13.11
        assertGe(
            converter.ACTION_GAS_LIMIT() - 200_000,
            liveBuyFuelGas * 14 / 10,
            "order must leave >=1.4x the live buyFuel need after the ~200k proxy retention"
        );
    }

    /// Incident #16 lesson: a retired converter must stop both ordering
    /// and paying — deactivate() unsubscribes BOTH topics (no further
    /// react calls = no minimum-shot fees) and in-flight deliveries
    /// are ignored.
    function testDeactivateStopsOrdersAndSubscription() public {
        uint256 subsBefore = sys.subscriptionCount();
        _horizon(4, 300); // orders once, lastOrderAt set
        assertEq(sys.callbackCount(), 1);

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(FuelConverter.NotOwner.selector);
        converter.deactivate();

        vm.prank(converter.owner());
        converter.deactivate();
        assertFalse(converter.active());
        assertEq(sys.subscriptionCount(), subsBefore - 2, "both subscriptions removed");

        // even a delivered log must not order anything
        uint256 cb = sys.callbackCount();
        _horizon(4, 900);
        assertEq(sys.callbackCount(), cb, "inactive converter ignores deliveries");
    }

    /// ADR-EXPANSION: the converter and the buyer are replaceable
    /// partners; changing the converter's depot rewires the
    /// HorizonAlert subscription.
    function testPartnersRewire() public {
        uint256 before = sys.subscriptionCount();
        address newFund = makeAddr("newFund");

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(FuelConverter.NotOwner.selector);
        converter.setFund(newFund);

        vm.startPrank(converter.owner());
        vm.expectRevert(FuelConverter.ZeroAddress.selector);
        converter.setBuyer(address(0));
        converter.setFund(newFund);
        address newBuyerAddr = makeAddr("newBuyer");
        converter.setBuyer(newBuyerAddr);
        vm.stopPrank();

        assertEq(converter.fund(), newFund);
        assertEq(converter.buyer(), newBuyerAddr);
        assertEq(sys.subscriptionCount(), before, "rewire: -old +new, BOTH topics move with the fund");

        // the buyer: the fuel recipient is replaceable
        vm.startPrank(buyer.owner());
        vm.expectRevert(FuelBuyer.ZeroAddress.selector);
        buyer.setFund(address(0));
        buyer.setFund(newFund);
        vm.stopPrank();
        assertEq(buyer.fund(), newFund);
    }

    // ------------------------------------------------ ADR-PURCHASE-SAFETY B2

    /// Runbook stop (G1.7): the buyer's pause() — the purchase reverts,
    /// the money is untouched; unpause() puts the circuit back in service.
    function testPauseBlocksBuyAndResumes() public {
        _horizon(1, 100);
        assertEq(sys.callbackCount(), 1);

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(FuelBuyer.NotOwner.selector);
        buyer.pause();

        vm.prank(buyer.owner());
        buyer.pause();
        assertTrue(buyer.paused());
        vm.prank(SEPOLIA_PROXY);
        vm.expectRevert(FuelBuyer.Paused.selector);
        buyer.buyFuel(address(converter), 100);

        vm.prank(buyer.owner());
        buyer.unpause();
        assertFalse(buyer.paused());
        vm.prank(SEPOLIA_PROXY);
        buyer.buyFuel(address(converter), 100);
        assertEq(buyer.buysCount(), 1);
        assertEq(faucet.received(), 0.02 ether);
    }

    /// Rate stop: a faucet payout of 0.9 at the 1.0 minimum → BadRate +
    /// orders stopped; the next alert does NOT order;
    /// reactivation — the owner hatch only, after investigation.
    function testBadRateStopsOrdersAndHatchRevives() public {
        _horizon(1, 100);
        assertEq(sys.callbackCount(), 1);

        vm.expectEmit(true, true, true, true, address(converter));
        emit FuelConverter.BadRate(0.9 ether, 1 ether);
        _funded(FAUCET_RVM, 0.9 ether, 150);
        assertTrue(converter.rateStopped(), "below minimum -> stopped");

        // an alert after the cooldown — silent (a bad rate is not transient)
        vm.warp(block.timestamp + 12 hours + 1 seconds);
        _horizon(1, 200);
        assertEq(sys.callbackCount(), 1, "no orders while rate-stopped");

        // the hatch — owner only
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(FuelConverter.NotOwner.selector);
        converter.clearRateStop();

        vm.prank(converter.owner());
        converter.clearRateStop();
        assertFalse(converter.rateStopped());
        _horizon(1, 300);
        assertEq(sys.callbackCount(), 2, "orders resume after the hatch");
    }

    /// A second bad payout after the stop does NOT re-emit BadRate
    /// (the stop latches until the hatch — "re-enabling is the owner
    /// hatch, after investigation").
    function testBadRateStickyUntilHatch() public {
        _funded(FAUCET_RVM, 0.9 ether, 100);
        assertTrue(converter.rateStopped());

        vm.recordLogs();
        _funded(FAUCET_RVM, 0.5 ether, 200);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; i++) {
            assertNotEq(
                entries[i].topics[0], keccak256("BadRate(uint256,uint256)"), "no duplicate BadRate while stopped"
            );
        }
        assertTrue(converter.rateStopped());
    }

    /// The "sender = faucet" filter: Funded from a stranger address —
    /// ignored (no telemetry, no stop even on a small payout).
    function testFundedFromStrangerIgnored() public {
        address stranger = makeAddr("stranger");
        _funded(stranger, 0.001 ether, 100);
        assertEq(converter.payouts(), 0, "stranger payout ignored");
        assertEq(converter.rateEma(), 0);
        assertFalse(converter.rateStopped(), "a stranger cannot stop the circuit");

        _horizon(1, 200);
        assertEq(sys.callbackCount(), 1, "orders still flow");
    }

    /// Telemetry: the live 16.11 payout (2.0 per purchase) lands in
    /// the EMA; a second payout is averaged in; the decision
    /// (orders) is unchanged.
    function testRateEmaTelemetry() public {
        _funded(FAUCET_RVM, 2.0 ether, 100);
        assertEq(converter.payouts(), 1);
        assertEq(converter.rateEma(), 2.0 ether);

        _funded(FAUCET_RVM, 3.0 ether, 200);
        assertEq(converter.payouts(), 2);
        assertEq(converter.rateEma(), 2.5 ether, "running mean");
        assertFalse(converter.rateStopped(), "healthy payouts never stop");
    }

    /// The minimum boundary: exactly 1.0 is still a healthy payout (strict <).
    function testBoundaryPayoutAtMinimumIsHealthy() public {
        _funded(FAUCET_RVM, 1.0 ether, 100);
        assertFalse(converter.rateStopped(), "exactly the minimum is acceptable");
    }
}

/// @dev Incident #15 class (morning check 13.11): the buyer is a callback
///      recipient — a dust debt to the callback proxy silently pauses all
///      fuel deliveries to it, and plain ETH top-ups do NOT clear it.
///      The buyer must expose the _coverDebt() hatch like the Executor.
contract FuelBuyerDebtTest is Test {
    MockCallbackProxy proxy;

    function setUp() public {
        proxy = new MockCallbackProxy();
    }

    function _deployBuyer() internal returns (FuelBuyer) {
        address converter = makeAddr("converter");
        address fund = makeAddr("fund");
        return new FuelBuyer(IPayable(payable(address(proxy))), converter, fund);
    }

    /// RED before the fix: no coverDebt() hatch — a funded buyer with a
    /// dust debt stays paused forever (the class that killed the 12.11
    /// executor).
    function testCoverDebtClearsProxyDebtAndLiftsPause() public {
        FuelBuyer buyer = _deployBuyer();
        proxy.setDebt(address(buyer), 82_000_000_000 wei);
        vm.deal(address(buyer), 0.02 ether);

        assertGt(proxy.debt(address(buyer)), 0, "precondition: in debt");
        assertGt(address(buyer).balance, proxy.debt(address(buyer)), "precondition: funded");

        // Anyone may call: the payment only ever goes to the proxy for
        // our own debt — not a privileged action.
        vm.prank(makeAddr("anyone"));
        buyer.coverDebt();

        assertEq(proxy.debt(address(buyer)), 0, "debt cleared - deliveries resume");
        assertEq(address(buyer).balance, 0.02 ether - 82_000_000_000 wei);
    }
}
