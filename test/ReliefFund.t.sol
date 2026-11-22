// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReliefFund} from "../src/ReliefFund.sol";

/**
 * @title ReliefFundTest (v3 "the owner with eyes")
 * @notice An RN-perceiving feeder: the ration gate by the dog's real
 *         balance (sated → DogFed(0, balanceAfter), hungry → a portion),
 *         the balanceAfter report event (the mirror channel), automatic
 *         receiver-reserve top-ups (itself + the mailbox — the 13-18.09
 *         death is closed), the watcher's RN patrol (a bark + a top-up /
 *         sweepExcess of the margin), revival, rvm guards, the reserve
 *         floor, owner setters.
 * @dev Mocks: SYSTEM (debts + reserves + depositTo), the dog (a payer
 *      with coverDebt), the watcher (a payer + sweepExcess with the
 *      SELF_KEEP_FLOOR floor).
 */
interface IDebtOracle {
    function debts(address) external view returns (uint256);
    function reserves(address) external view returns (uint256);
}

contract MockSystem is IDebtOracle {
    mapping(address => uint256) public debts;
    mapping(address => uint256) public reserves;

    function setDebt(address who, uint256 amount) external {
        debts[who] = amount;
    }

    function setReserve(address who, uint256 amount) external {
        reserves[who] = amount;
    }

    /// @dev depositTo: the live SYSTEM semantics — the payment clears the
    ///      recipient's DEBT (probe canon: "a transfer to the address does
    ///      NOT clear the debt — only depositTo does"), the remainder lands
    ///      in the reserve.
    function depositTo(address who) external payable {
        uint256 d = debts[who];
        uint256 burn = msg.value > d ? d : msg.value;
        debts[who] = d - burn;
        reserves[who] += msg.value - burn;
    }

    /// @dev A payment from a contract clears its debt (the system contract's semantics).
    receive() external payable {
        address payer = msg.sender;
        uint256 d = debts[payer];
        uint256 burn = msg.value > d ? d : msg.value;
        if (burn > 0) debts[payer] = d - burn;
    }
}

contract MockPayer {
    IDebtOracle public immutable system;

    constructor(IDebtOracle system_) {
        system = system_;
    }

    receive() external payable {}

    function coverDebt() external {
        uint256 d = system.debts(address(this));
        require(address(this).balance >= d, "Insufficient funds");
        (bool ok,) = payable(address(system)).call{value: d}("");
        require(ok, "Transfer failed");
    }
}

/// @dev Watcher v5.7: a payer + sweepExcess with the obligations + margin floor.
contract MockWatcher is MockPayer {
    uint256 public immutable keepFloor;

    constructor(IDebtOracle system_, uint256 keepFloor_) MockPayer(system_) {
        keepFloor = keepFloor_;
    }

    function sweepExcess(address to_) external {
        uint256 debt = system.debts(address(this));
        if (debt > 0 && address(this).balance >= debt) {
            (bool okPay,) = payable(address(system)).call{value: debt}("");
            okPay;
        }
        uint256 keep = keepFloor + system.debts(address(this));
        if (address(this).balance > keep) {
            (bool ok,) = payable(to_).call{value: address(this).balance - keep}("");
            require(ok, "sweep failed");
        }
    }
}

contract ReliefFundTest is Test {
    ReliefFund internal fund;
    MockSystem internal system = new MockSystem();
    MockPayer internal dog;
    MockWatcher internal watcher;

    address internal systemAddr = makeAddr("systemAddr"); // callbackSender (prank)
    address internal watcherRvm = makeAddr("watcherRvm");
    address internal dogRvm = makeAddr("dogRvm");
    address internal mailbox = makeAddr("mailbox");
    address internal attacker = makeAddr("attacker");

    receive() external payable {} // for the withdraw test

    function setUp() public {
        dog = new MockPayer(system);
        watcher = new MockWatcher(system, 1 ether); // SELF_KEEP_FLOOR
        fund = new ReliefFund(
            address(this), systemAddr, watcherRvm, address(system), address(dog), mailbox, address(watcher)
        );
        vm.deal(address(fund), 3 ether);
        // A quiet background for "clean" cases: the watcher is normal
        // (2 ≤ eff ≤ 6 — the patrol is silent), receiver reserves are
        // healthy (no top-ups). Specific tests override point by point.
        vm.deal(address(watcher), 4 ether);
        system.setReserve(address(watcher), 4 ether); // satiety = the reserve (the 11.11 pocket fix)
        system.setReserve(mailbox, 0.5 ether);
        system.setReserve(address(fund), 0.5 ether);
    }

    // ------------------------------------------------------------ feeding: the reality gate

    /// @dev Hungry (real balance 0 < 0.15) — gets a portion, the debt is
    ///      cleared with its own money. The event carries the real
    ///      post-feeding balance.
    function test_HungryDogGetsRationAndDebtCovered() public {
        system.setDebt(address(dog), 0.02 ether);

        vm.prank(systemAddr);
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.DogFed(address(dog), 0.05 ether, 0.03 ether); // 0 + portion − debt
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);

        assertEq(system.reserves(address(dog)), 0.03 ether, "ration in, debt out (reserve pocket)");
        assertEq(system.debts(address(dog)), 0 ether, "debt cleared");
        assertEq(fund.fedCount(), 1, "feeding counted");
    }

    /// @dev Sated (balance ≥ 0.15) — portion 0: we do not burn the
    ///      receiver fee for nothing, but the report event goes out —
    ///      the dog's mirror calibrates (v4.5).
    function test_FedDogGetsZeroButReported() public {
        system.setReserve(address(dog), 1 ether);
        uint256 before = system.reserves(address(dog));

        vm.prank(systemAddr);
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.DogFed(address(dog), 0, 1 ether);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);

        assertEq(system.reserves(address(dog)), before, "sated dog: no transfer");
        assertEq(fund.fedCount(), 1, "request still counted (pulse)");
    }

    /// @dev The debt is subtracted from the "bowl": bal 0.2, debt 0.1 → eff 0.1 < 0.15 → feed.
    function test_DebtReducesEffectiveBalance() public {
        system.setReserve(address(dog), 0.2 ether);
        system.setDebt(address(dog), 0.1 ether);

        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);

        // portion 0.05: depositTo clears the debt first (0.1 → 0.05), 0 into the reserve
        // eff was computed by the reserve: 0.2 − 0.1 = 0.1 < 0.15 → feed
        assertEq(system.reserves(address(dog)), 0.2 ether, "feed consumed by debt");
        assertEq(system.debts(address(dog)), 0.05 ether, "debt counted as hunger");
    }

    /// @dev An emptying fund cuts the portion to what remains (no revert — the delivery is already paid for).
    function test_RationCappedAtFundBalance() public {
        vm.deal(address(fund), 0.03 ether); // less than the portion
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(address(dog)), 0.03 ether, "capped at what fund has");
    }

    /// @dev Double feeding (live tick 8090000, 11.11): the watchdog in the
    ///      registry + the special branch = DogFed twice per patrol, the
    ///      double portion drained the depot to zero in one tick. The
    ///      canon: the special path (dogFloor/ration) is the single source
    ///      of truth for the watchdog; the registry patrol SKIPS it (a
    ///      registry record for the dog is dead weight).
    function test_DogInRegistryFedExactlyOnce() public {
        fund.addWard(address(dog), 0.2 ether, 0.07 ether); // as in the live W2.2 wiring

        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);

        assertEq(system.reserves(address(dog)), 0.05 ether, "exactly one ration, not two");
    }

    function test_RevertWhen_FeedFromStrangerRvm() public {
        vm.prank(systemAddr);
        // ADR-EXPANSION: the guard checks the rvm slot against the CURRENT dogContract
        vm.expectRevert(bytes("active dog only"));
        fund.onFeedDog(attacker, address(dog), 0.05 ether);
    }

    // ------------------------------------------------------------ receiver-reserve top-ups

    /// @dev RCA 13-18.09: an empty receiver reserve = a blacklist. The
    ///      mailbox reserve below the floor → the fund tops it up to the
    ///      target from its own native balance.
    function test_MailboxReceiverRefilled() public {
        system.setReserve(mailbox, 0.1 ether); // below the 0.3 floor
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(mailbox), 1 ether, "mailbox topped to target");
        assertGt(address(fund).balance, 0, "paid from native");
    }

    /// @dev Its own reserve is topped up too (no waiting for a manual depositTo).
    function test_OwnReceiverRefilled() public {
        system.setReserve(address(fund), 0.2 ether);
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(address(fund)), 1 ether, "own reserve topped");
    }

    /// @dev Healthy reserves are left alone (the delivery is paid for, no gas burned).
    function test_HealthyReceiversUntouched() public {
        system.setReserve(mailbox, 0.5 ether);
        system.setReserve(address(fund), 0.5 ether);
        uint256 fundBefore = address(fund).balance;
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(mailbox), 0.5 ether, "mailbox untouched");
        assertEq(system.reserves(address(fund)), 0.5 ether, "own untouched");
        assertEq(address(fund).balance, fundBefore - 0.05 ether, "only ration spent");
    }

    // ------------------------------------------------------------ the watcher's RN patrol

    /// @dev The watcher empties (eff < 2) → the WatcherLowReserve event
    ///      (the dog barks) + a 1.0 top-up from the fund. Event order:
    ///      DogFed → WatcherLowReserve.
    function test_WatcherLowReserveToppedUpAndSignalled() public {
        system.setReserve(address(watcher), 0); // eff 0 < the floor 2
        vm.prank(systemAddr);
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.DogFed(address(dog), 0.05 ether, 0.05 ether);
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.WatcherLowReserve(address(watcher), 0, 1 ether);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(address(watcher)), 1 ether, "watcher topped up");
    }

    /// @dev The margin: the watcher is rich (eff > 6) → the fund calls
    ///      sweepExcess, the excess above the floor rides to the fund
    ///      (real RN math).
    function test_WatcherSweepsExcessToFund() public {
        system.setReserve(address(watcher), 8 ether); // eff 8 > 6 → sweep
        vm.deal(address(watcher), 8 ether); // the native balance — the sweep subject
        uint256 fundBefore = address(fund).balance;
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        // 8 − 1 (floor) = 7 rides in; minus the dog's 0.05 portion from the fund
        assertEq(address(watcher).balance, 1 ether, "watcher keeps floor");
        assertEq(address(fund).balance, fundBefore - 0.05 ether + 7 ether, "margin swept in");
    }

    /// @dev The watcher is normal (2 ≤ eff ≤ 6) — nobody is touched.
    function test_WatcherMidrangeQuiet() public {
        system.setReserve(address(watcher), 4 ether);
        uint256 fundBefore = address(fund).balance;
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(address(watcher)), 4 ether, "no topup, no sweep");
        assertEq(address(fund).balance, fundBefore - 0.05 ether, "only ration spent");
    }

    // -------------------------------------------------- the acting dog (v2)

    /// @dev RCA 18.09: the old dog keeps ticking and asking for rations
    ///      after the switch — the fund pays only the acting one (the
    ///      address from the payload).
    function test_RevertWhen_FeedRetiredDog() public {
        MockPayer oldDog = new MockPayer(system);
        vm.prank(systemAddr);
        vm.expectRevert(bytes("active dog only"));
        fund.onFeedDog(address(oldDog), address(oldDog), 0.05 ether);
    }

    /// @dev Replacing the dog — one owner command, no fund replacement.
    function test_SetDogContractSwitchesFeeding() public {
        MockPayer newDog = new MockPayer(system);
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.DogSwitched(address(dog), address(newDog));
        fund.setDogContract(address(newDog));

        uint256 before = system.reserves(address(newDog));
        vm.prank(systemAddr);
        fund.onFeedDog(address(newDog), address(newDog), 0.05 ether);
        assertEq(system.reserves(address(newDog)), before + 0.05 ether, "new dog is fed");

        vm.prank(systemAddr);
        vm.expectRevert(bytes("active dog only"));
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
    }

    function test_RevertWhen_SetDogNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("owner only"));
        fund.setDogContract(attacker);
    }

    // ------------------------------------------------------------ owner policies

    function test_SetFeedingUpdatesGate() public {
        fund.setFeeding(0.5 ether, 0.2 ether);
        system.setReserve(address(dog), 0.3 ether); // eff 0.3 < the new 0.5 floor → feed
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(system.reserves(address(dog)), 0.5 ether, "new ration applied");
    }

    function test_RevertWhen_SetFeedingNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("owner only"));
        fund.setFeeding(1 ether, 1 ether);
    }

    function test_RevertWhen_SetReservePolicyNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("owner only"));
        fund.setReservePolicy(0, 0);
    }

    function test_RevertWhen_SetWatcherPolicyNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("owner only"));
        fund.setWatcherPolicy(0, 0, 0);
    }

    // ------------------------------------------------------------ revival

    function test_ReviveTopsUpAndCoversDebt() public {
        system.setDebt(address(watcher), 0.03 ether);
        uint256 watcherBefore = address(watcher).balance;

        vm.prank(systemAddr);
        fund.onRevive(watcherRvm, address(watcher), 0.3 ether);

        assertEq(address(watcher).balance, watcherBefore + 0.3 ether - 0.03 ether, "top-up in, debt out");
        assertEq(fund.revivedCount(), 1, "revival counted");
    }

    function test_ReviveCallableByDogRvmToo() public {
        vm.prank(systemAddr);
        fund.onRevive(address(dog), address(watcher), 0.1 ether);
        assertEq(fund.revivedCount(), 1, "dog may wake the fund");
    }

    function test_RevertWhen_ReviveFromStrangerRvm() public {
        vm.prank(systemAddr);
        vm.expectRevert(bytes("trusted rvm only"));
        fund.onRevive(attacker, address(watcher), 0.1 ether);
    }

    function test_RevertWhen_SenderNotSystem() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("sender only"));
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
    }

    // ------------------------------------------------------------ the reserve floor

    function test_LowFundEmitsWhenBelowFloor() public {
        fund.setMinReserve(2.96 ether); // after the 0.05 portion 2.95 remains < the floor
        vm.prank(systemAddr);
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.DogFed(address(dog), 0.05 ether, 0.05 ether);
        vm.expectEmit(false, false, false, true, address(fund));
        emit ReliefFund.LowFund(2.95 ether, 2.96 ether);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
        assertEq(address(fund).balance, 2.95 ether, "only ration spent");
    }

    function test_FundReceivesEthAndCounts() public {
        vm.expectEmit(true, true, true, true, address(fund));
        emit ReliefFund.Funded(address(this), 1 ether);
        (bool ok,) = address(fund).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ------------------------------------------------------------ owner

    function test_WithdrawOnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("owner only"));
        fund.withdraw(attacker, 1 ether);

        uint256 before = address(this).balance;
        fund.withdraw(address(this), 1 ether);
        assertEq(address(this).balance, before + 1 ether, "owner withdrew");
    }

    // ------------------------------------------- partner hatches (ADR-EXPANSION)

    /// @dev Replacing the watchdog does NOT require a redeploy of the
    ///      depot: the guard checks the rvm slot against the current
    ///      dogContract (setDogContract).
    function test_NewDogRvmPassesGuardAfterSwitch() public {
        MockPayer newDog = new MockPayer(system);
        fund.setDogContract(address(newDog));

        // the old dog is rejected by the guard, the new one passes and is fed
        vm.prank(systemAddr);
        vm.expectRevert(bytes("active dog only"));
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);

        uint256 before = system.reserves(address(newDog));
        vm.prank(systemAddr);
        fund.onFeedDog(address(newDog), address(newDog), 0.05 ether);
        assertEq(system.reserves(address(newDog)), before + 0.05 ether, "new dog fed, no redeploy");
    }

    /// @dev Partner setters: owner-only, zero-revert, an event, an effect.
    function test_PartnerSetters() public {
        address newWatcherRvm = makeAddr("newWatcherRvm");
        address newMailbox = makeAddr("newMailbox");
        address newWatcher = makeAddr("newWatcher");

        vm.prank(attacker);
        vm.expectRevert(bytes("owner only"));
        fund.setWatcherRvm(newWatcherRvm);

        vm.expectRevert(bytes("zero address"));
        fund.setMailbox(address(0));

        fund.setWatcherRvm(newWatcherRvm);
        fund.setMailbox(newMailbox);
        fund.setWatcher(newWatcher);
        assertEq(fund.watcherRvm(), newWatcherRvm);
        assertEq(fund.mailbox(), newMailbox);
        assertEq(fund.watcher(), newWatcher);

        // effect: the new watcherRvm passes the onWardHungry guard
        address wardP = makeAddr("wardP");
        fund.addWard(wardP, 0.05 ether, 0.1 ether);
        vm.prank(systemAddr);
        fund.onWardHungry(newWatcherRvm, wardP);
    }
}

/// @dev v6 (ADR-v2): the ward registry, the onWardHungry fast chain, the
///      supply horizon. The v5 mocks are reused.
contract ReliefFundWardTest is Test {
    ReliefFund internal fund;
    MockSystem internal system = new MockSystem();
    MockPayer internal dog;
    MockWatcher internal watcher;
    MockPayer internal wardA; // cashier/brain — an ordinary ward

    address internal systemAddr = makeAddr("systemAddr");
    address internal watcherRvm = makeAddr("watcherRvm");
    address internal dogRvm = makeAddr("dogRvm");
    address internal mailbox = makeAddr("mailbox");

    function setUp() public {
        dog = new MockPayer(system);
        watcher = new MockWatcher(system, 1 ether);
        wardA = new MockPayer(system);
        fund = new ReliefFund(
            address(this), systemAddr, watcherRvm, address(system), address(dog), mailbox, address(watcher)
        );
        vm.deal(address(fund), 3 ether);
        vm.deal(address(watcher), 4 ether); // a quiet background
        system.setReserve(address(watcher), 4 ether); // satiety = the reserve (the 11.11 pocket fix)
        system.setReserve(mailbox, 0.5 ether);
        system.setReserve(address(fund), 0.5 ether);
        fund.addWard(address(wardA), 0.5 ether, 0.2 ether); // floor 0.5, portion 0.2
    }

    function _tick() internal {
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether);
    }

    /// The registry: adding, no duplicates, patrolling in the tick.
    function test_WardAddedAndPatrolled() public {
        assertEq(fund.wardCount(), 1);
        vm.expectRevert("already a ward");
        fund.addWard(address(wardA), 0.5 ether, 0.2 ether);

        vm.expectEmit(true, true, true, true);
        emit ReliefFund.Fed(address(wardA), 0.2 ether, 0.2 ether);
        _tick(); // wardA is hungry (reserve 0 < 0.5) → a portion
        assertEq(system.reserves(address(wardA)), 0.2 ether);

        // still hungry (0.2 < 0.5) → a second portion; feedings are counted
        _tick();
        assertEq(system.reserves(address(wardA)), 0.4 ether);
        (,, uint256 wardFedCount) = fund.wards(address(wardA));
        assertEq(wardFedCount, 2);

        // sated (0.6 ≥ 0.5) — a report with a zero portion
        system.setReserve(address(wardA), 0.6 ether);
        _tick();
        assertEq(system.reserves(address(wardA)), 0.6 ether);
    }

    /// The debt lowers eff: balance 0.4 with debt 0.2 → eff 0.2 < 0.5 → feed.
    function test_WardDebtReducesEff() public {
        system.setReserve(address(wardA), 0.4 ether);
        system.setDebt(address(wardA), 0.2 ether);
        _tick();
        // eff = 0.4 − 0.2 = 0.2 < 0.5 → portion 0.2: depositTo clears the debt
        assertEq(system.reserves(address(wardA)), 0.4 ether);
        assertEq(system.debts(address(wardA)), 0);
    }

    /// The fast chain: wardA's cry (from a trusted rvm) → the same mechanics.
    function test_OnWardHungryFeeds() public {
        vm.expectEmit(true, true, true, true);
        emit ReliefFund.Fed(address(wardA), 0.2 ether, 0.2 ether);
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));
        assertEq(system.reserves(address(wardA)), 0.2 ether);
    }

    /// The cry is not trusted: a sated ward — portion 0 (the real numbers decide).
    function test_OnWardHungryIgnoresFalseCry() public {
        system.setReserve(address(wardA), 1 ether); // sated
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));
        assertEq(system.reserves(address(wardA)), 1 ether);
    }

    function test_OnWardHungryGuards() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("sender only");
        fund.onWardHungry(address(dog), address(wardA));

        vm.prank(systemAddr);
        vm.expectRevert("trusted rvm only");
        fund.onWardHungry(makeAddr("fakeRvm"), address(wardA));

        vm.prank(systemAddr);
        vm.expectRevert("unknown ward");
        fund.onWardHungry(address(dog), makeAddr("nobody"));
    }

    /// The dog and the watcher are also available to the fast chain (their cries are enough).
    function test_OnWardHungryAcceptsDogAndWatcher() public {
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(dog)); // a hungry dog → a portion
        assertEq(system.reserves(address(dog)), 0.05 ether);
    }

    /// Removing a ward — silence in the patrols.
    /// @dev The pocket fix (live tick 8100000, 11.11): the patrol fed with
    ///      a NATIVE transfer, but a reactive ward pays for its react()
    ///      calls from the SYSTEM reserve — the fed amount paid no gas
    ///      (probe canon: a transfer to the address does NOT clear the
    ///      debt, only depositTo does). Feeding = depositTo into SYSTEM:
    ///      the reserve grows, the debt is cleared in the same call.
    function test_WardFeedLandsInSystemReserve() public {
        vm.prank(systemAddr);
        fund.onFeedDog(address(dog), address(dog), 0.05 ether); // hungry wardA: eff 0 < 0.5

        assertGt(system.reserves(address(wardA)), 0, "portion must land in the SYSTEM reserve");
        assertEq(address(wardA).balance, 0, "native pocket is wrong for reactive wards");
    }

    function test_WardRemoved() public {
        fund.removeWard(address(wardA));
        assertEq(fund.wardCount(), 0);
        _tick();
        assertEq(system.reserves(address(wardA)), 0);
        vm.expectRevert("not a ward");
        fund.removeWard(address(wardA));
    }

    /// The horizon: levels are recomputed, events on transitions.
    function test_HorizonEscalation() public {
        // a clean background: everyone is sated (reserves) — the tick spends nothing
        system.setReserve(address(dog), 1 ether);
        system.setReserve(address(wardA), 1 ether);

        fund.setBurnRate(0.1 ether); // 3 / 0.1 = 30 days → level 0 (30 is not < 30)
        _tick();
        assertEq(fund.horizonLevel(), 0);

        fund.setBurnRate(0.2 ether); // 3 / 0.2 = 15 days → level 1
        vm.expectEmit(true, true, true, true);
        emit ReliefFund.HorizonAlert(15, 3 ether, 0.2 ether, 1);
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));
        assertEq(fund.horizonLevel(), 1);

        vm.deal(address(fund), 1 ether); // vm.deal overwrites: 1 / 0.2 = 5 days → level 3
        vm.expectEmit(true, true, true, true);
        emit ReliefFund.HorizonAlert(5, 1 ether, 0.2 ether, 3);
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));
        assertEq(fund.horizonLevel(), 3);
    }

    /// No burn rate set → the horizon is ∞, no alerts.
    function test_HorizonInfinityWithoutRate() public {
        _tick();
        assertEq(fund.horizonLevel(), 0);
        assertEq(fund.burnRatePerDay(), 0);
    }

    /// The 11.11 deadlock (W2.1): a level stuck ≥1 without a change → the
    /// depot stayed silent, the converter did not repeat the order, a
    /// one-off faucet revert killed the auto-faucet forever. While the
    /// level holds, the signal repeats every tick — the converter kills
    /// duplicates (cooldown), not the depot.
    function test_HorizonRepeatsWhileLevelHolds() public {
        system.setReserve(address(dog), 1 ether);
        system.setReserve(address(wardA), 1 ether);

        fund.setBurnRate(0.2 ether); // 3 / 0.2 = 15 days → level 1
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));
        assertEq(fund.horizonLevel(), 1);

        // tick 2: the level unchanged — the signal again (the repeat cadence)
        vm.expectEmit(true, true, true, true);
        emit ReliefFund.HorizonAlert(15, 3 ether, 0.2 ether, 1);
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));

        // tick 3: again — without a level change
        vm.expectEmit(true, true, true, true);
        emit ReliefFund.HorizonAlert(15, 3 ether, 0.2 ether, 1);
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));

        // recovered: the transition to 0 is emitted (as before), then — silence
        vm.deal(address(fund), 30 ether); // 30 / 0.2 = 150 days → level 0
        vm.expectEmit(true, true, true, true);
        emit ReliefFund.HorizonAlert(150, 30 ether, 0.2 ether, 0);
        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA));
        assertEq(fund.horizonLevel(), 0);

        vm.prank(systemAddr);
        fund.onWardHungry(address(dog), address(wardA)); // healthy — silent
        assertEq(fund.horizonLevel(), 0);
    }
}
