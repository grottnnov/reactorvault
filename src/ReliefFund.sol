// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title ReliefFund v6 — the fuel depot with a ward registry (ADR-v2, 09.11)
 * @notice A plain contract: immortal (no subscriptions), feeds ALL wards
 *         through one mechanism by the registry: eff = balance − debt
 *         (the SYSTEM's real numbers) < floor → a portion + coverDebt +
 *         a report. Directive 03.09: pay by real numbers, not by calendar
 *         and not by request — a ward's cry is only an occasion to re-check.
 * @dev v6 (09.11) vs v5.5: (1) a registry of ward records [address, floor,
 *      portion] — a new ward is a row of data, not code; (2) a single
 *      _patrolWard for everyone (dog/watcher are backward wrappers, the
 *      DogFed/WatcherLowReserve events kept for compatibility); (3) the
 *      onWardHungry entry — the fast cry chain (same guards); (4)
 *      HorizonAlert: the depot's supply horizon 30/14/7/3 days — a signal
 *      to the auto-faucet converter and to a human (an EMA of the burn rate).
 */
contract ReliefFund {
    address public immutable owner;
    address public immutable callbackSender;

    /// @notice Partners are replaceable by the owner (ADR-EXPANSION: guards
    ///         are set in stone, partners are maintenance hatches): the
    ///         rvm check uses the CURRENT dogContract (setDogContract), not
    ///         a baked-in copy — replacing the watchdog does not require a
    ///         redeploy of the depot.
    address public watcherRvm;
    address public system; // SYSTEM: debts/reserves/depositTo
    address public mailbox;
    address public watcher; // the watcher's RN address (patrol + sweep)

    /// @dev The acting dog: only its feeding tick is valid.
    address public dogContract;

    // ---------------------------------------------------------- registry
    struct Ward {
        uint256 floor; // eff below → feed
        uint256 portion; // the portion per feeding
        uint256 fedCount; // how many times fed
    }

    /// @notice The depot's wards. Keys are contract addresses on the RN.
    mapping(address => Ward) public wards;
    address[] public wardList;

    // ---------------------------------------------------------- feeding (dog legacy)
    uint256 public dogFloor = 0.15 ether;
    uint256 public ration = 0.05 ether;

    // ------------------------------------- receiver reserves (RCA 13-18.09)
    uint256 public reserveFloor = 0.3 ether;
    uint256 public reserveTarget = 1 ether;

    // ------------------------------------------------- watcher patrol
    uint256 public watcherFloor = 2 ether;
    uint256 public watcherTopUp = 1 ether;
    uint256 public watcherSweepAbove = 6 ether;

    uint256 public minReserve; // the native balance floor: below → LowFund

    uint256 public fedCount;
    uint256 public revivedCount;

    // ------------------------------------------------- horizon
    /// @notice The estimated daily burn (wei/day; calibrated by the owner
    ///         from facts: totalFed / the depot's lifetime).
    uint256 public burnRatePerDay;
    uint256 public totalFed;
    uint64 public lastFedAt;
    uint8 public horizonLevel; // 0=∞(≥30d), 1=30..14, 2=14..7, 3=7..3, 4=<3d

    event Funded(address indexed from, uint256 amount);
    event DogFed(address indexed dog, uint256 amount, uint256 balanceAfter);
    event DogSwitched(address indexed from, address indexed to);
    event Revived(address indexed target, uint256 debt, uint256 topUp);
    event ReceiverRefilled(address indexed receiver, uint256 amount);
    event WatcherLowReserve(address indexed watcher, uint256 effective, uint256 topUp);
    event LowFund(uint256 reserve, uint256 floor);
    /// @notice The unified registry-feeding report; balanceAfter is the mirror channel.
    event Fed(address indexed ward, uint256 amount, uint256 balanceAfter);
    event WardAdded(address indexed ward, uint256 floor, uint256 portion);
    event WardRemoved(address indexed ward);
    event PartnerRewired(string indexed role, address indexed from, address to);
    /// @notice The depot's supply horizon (days); levels 30/14/7/3 — a
    ///         signal to the auto-faucet (≤30d) and to a human (≤7, ≤3).
    event HorizonAlert(uint256 daysRemaining, uint256 balance, uint256 burnRatePerDay, uint8 level);

    constructor(
        address owner_,
        address callbackSender_,
        address watcherRvm_,
        address system_,
        address dogContract_,
        address mailbox_,
        address watcher_
    ) {
        owner = owner_;
        callbackSender = callbackSender_;
        watcherRvm = watcherRvm_;
        system = system_;
        dogContract = dogContract_;
        mailbox = mailbox_;
        watcher = watcher_;
        minReserve = 1 ether;
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    function reserve() public view returns (uint256) {
        return address(this).balance;
    }

    function wardCount() external view returns (uint256) {
        return wardList.length;
    }

    // ------------------------------------------------------------- registry

    function addWard(address target_, uint256 floor_, uint256 portion_) external {
        require(msg.sender == owner, "owner only");
        require(target_ != address(0), "zero ward");
        require(wards[target_].portion == 0 && wards[target_].floor == 0, "already a ward");
        wards[target_] = Ward({floor: floor_, portion: portion_, fedCount: 0});
        wardList.push(target_);
        emit WardAdded(target_, floor_, portion_);
    }

    function removeWard(address target_) external {
        require(msg.sender == owner, "owner only");
        require(wards[target_].floor != 0 || wards[target_].portion != 0, "not a ward");
        delete wards[target_];
        uint256 len = wardList.length;
        for (uint256 i = 0; i < len; i++) {
            if (wardList[i] == target_) {
                wardList[i] = wardList[len - 1];
                wardList.pop();
                break;
            }
        }
        emit WardRemoved(target_);
    }

    /// @notice Thresholds are money: every retune is announced on-chain.
    event WardPolicySet(address indexed ward, uint256 floor, uint256 portion);
    event FeedingSet(uint256 dogFloor, uint256 ration);
    event ReservePolicySet(uint256 floor, uint256 target);
    event WatcherPolicySet(uint256 floor, uint256 topUp, uint256 sweepAbove);
    event BurnRateSet(uint256 perDay);
    event MinReserveSet(uint256 minReserve);

    function setWard(address target_, uint256 floor_, uint256 portion_) external {
        require(msg.sender == owner, "owner only");
        require(
            wards[target_].floor != 0 || wards[target_].portion != 0 || target_ == dogContract || target_ == watcher,
            "not a ward"
        );
        wards[target_].floor = floor_;
        wards[target_].portion = portion_;
        emit WardPolicySet(target_, floor_, portion_);
    }

    // ---------------------------------------------------------- feeding

    /// @notice The dog's tick (a Cron10000 callback): feeding the dog +
    ///         patrolling ALL ward records + receiver top-ups + the
    ///         horizon. One paid call — all perception and all actions
    ///         (the "one recipient" canon).
    function onFeedDog(
        address rvm_,
        address dog_,
        uint256 /*amount_*/
    )
        external
    {
        require(msg.sender == callbackSender || msg.sender == watcher || msg.sender == dogContract, "sender only");
        require(rvm_ == dogContract, "active dog only");
        require(dog_ == dogContract, "active dog only");
        _patrolWard(dog_);
        fedCount += 1;
        _patrolWatcher();
        _patrolAllWards();
        _refillReceiver(mailbox);
        _refillReceiver(address(this));
        _checkLowFund();
        _checkHorizon();
    }

    /// @notice The fast cry chain (a safety net, ADR-v2): the watchdog
    ///         heard a LowGas → it calls the depot; the depot does NOT
    ///         trust the cry — it runs the unified mechanism by the real
    ///         numbers. Once.
    function onWardHungry(address rvm_, address ward_) external {
        require(msg.sender == callbackSender || msg.sender == watcher || msg.sender == dogContract, "sender only");
        require(rvm_ == watcherRvm || rvm_ == dogContract, "trusted rvm only");
        require(
            ward_ == dogContract || ward_ == watcher || wards[ward_].floor != 0 || wards[ward_].portion != 0,
            "unknown ward"
        );
        if (ward_ == watcher) {
            _patrolWatcher(); // feeding + the sweep branch
        } else {
            _patrolWard(ward_);
        }
        _checkLowFund();
        _checkHorizon();
    }

    /// @notice Reviving a target (the watcher with a DEAD dog / the dog
    ///         when the watcher dies / other wards in debt).
    function onRevive(address rvm_, address target_, uint256 topUp_) external {
        require(msg.sender == callbackSender || msg.sender == watcher || msg.sender == dogContract, "sender only");
        require(rvm_ == watcherRvm || rvm_ == dogContract, "trusted rvm only");
        uint256 debt = _debtOf(target_);
        uint256 topUp = topUp_ > address(this).balance ? address(this).balance : topUp_;
        if (topUp > 0) {
            (bool ok,) = target_.call{value: topUp}("");
            require(ok, "topup failed");
        }
        _tryCoverDebt(target_);
        revivedCount += 1;
        emit Revived(target_, debt, topUp);
        _checkLowFund();
    }

    // ------------------------------------------------------------- internals

    /// @dev The UNIFIED feeding mechanism (ADR-v2): eff = balance − debt
    ///      with real eyes; below the floor → a portion + debt clearing.
    ///      Report: Fed(ward, amount, balanceAfter); for the dog — DogFed
    ///      (v5.5 compatibility), for the watcher — WatcherLowReserve.
    function _patrolWard(address target_) private returns (uint256 fed) {
        Ward storage w = wards[target_];
        uint256 floor = w.floor;
        uint256 portion = w.portion;
        if (target_ == dogContract) {
            floor = dogFloor;
            portion = ration;
        } else if (target_ == watcher) {
            floor = watcherFloor;
            portion = watcherTopUp;
        }
        uint256 debt = _debtOf(target_);
        // Satiety = the SYSTEM reserve minus debt: a reactive ward pays for
        // its react() calls EXACTLY from there (the probe canon); the
        // native balance is a dead pocket (ticks 8090000/8100000: we fed
        // the address, the gas died).
        uint256 bal = _reservesOf(target_);
        uint256 eff = bal > debt ? bal - debt : 0;
        fed = eff < floor ? portion : 0;
        if (fed > address(this).balance) {
            fed = address(this).balance;
        }
        if (fed > 0) {
            // Feeding = depositTo: the portion lands in the ward's gas
            // pocket and clears its SYSTEM debt in the same call.
            (bool ok,) = system.call{value: fed}(abi.encodeWithSignature("depositTo(address)", target_));
            require(ok, "feed failed");
            w.fedCount += 1;
            totalFed += fed;
            lastFedAt = uint64(block.timestamp);
        }
        _tryCoverDebt(target_);
        if (target_ == dogContract) {
            emit DogFed(target_, fed, _reservesOf(target_));
        } else if (target_ == watcher) {
            if (fed > 0) {
                emit WatcherLowReserve(target_, eff, fed);
            }
        } else {
            emit Fed(target_, fed, _reservesOf(target_));
        }
    }

    /// @dev Patrolling all registry ward records (the slow chain).
    function _patrolAllWards() private {
        uint256 len = wardList.length;
        for (uint256 i = 0; i < len; i++) {
            // The registry does not feed the watchdog: its special path
            // (dogFloor/ration) in onFeedDog already did — a second pass
            // gave a double portion per patrol (live tick 8090000: the
            // depot drained to zero in one tick).
            if (wardList[i] == dogContract) {
                continue;
            }
            _patrolWard(wardList[i]);
        }
    }

    function _tryCoverDebt(address target_) internal {
        (bool ok,) = target_.call(abi.encodeWithSignature("coverDebt()"));
        // A target revert is not fatal: there may be no debt or the target
        // may lack funds — the event carries the context, LowFund will
        // signal exhaustion.
        ok; // suppress warning
    }

    /// @dev The SYSTEM receiver reserve: below floor → top up to target from the native balance.
    function _refillReceiver(address who_) private {
        uint256 res = _reservesOf(who_);
        if (res >= reserveFloor) {
            return;
        }
        uint256 amount = reserveTarget > res ? reserveTarget - res : 0;
        if (amount > address(this).balance) {
            amount = address(this).balance;
        }
        if (amount == 0) {
            return;
        }
        (bool ok,) = system.call{value: amount}(abi.encodeWithSignature("depositTo(address)", who_));
        if (ok) {
            emit ReceiverRefilled(who_, amount);
        }
        // A depositTo revert is not fatal: the next tick retries, LowFund signals.
    }

    /// @dev The watcher patrol: feeding through the unified mechanism + the sweep branch.
    function _patrolWatcher() private {
        _patrolWard(watcher);
        uint256 debt = _debtOf(watcher);
        uint256 bal = watcher.balance;
        uint256 eff = bal > debt ? bal - debt : 0;
        if (eff > watcherSweepAbove) {
            // The margin rides to the fund (sweepExcess computes the excess itself).
            (bool ok,) = watcher.call(abi.encodeWithSignature("sweepExcess(address)", address(this)));
            ok; // not fatal
        }
    }

    function _debtOf(address target_) internal view returns (uint256) {
        (bool ok, bytes memory ret) = system.staticcall(abi.encodeWithSignature("debts(address)", target_));
        return (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
    }

    function _reservesOf(address target_) internal view returns (uint256) {
        (bool ok, bytes memory ret) = system.staticcall(abi.encodeWithSignature("reserves(address)", target_));
        return (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
    }

    function _checkLowFund() internal {
        if (address(this).balance < minReserve) {
            emit LowFund(address(this).balance, minReserve);
        }
    }

    /// @dev The supply horizon: days = balance / daily burn. Levels
    ///      30/14/7/3: a transition emits HorizonAlert — the auto-faucet
    ///      trigger (≤30d) and the human one (≤7/≤3). Burn=0 → the
    ///      horizon is ∞.
    function _checkHorizon() internal {
        uint256 days_ = type(uint256).max;
        if (burnRatePerDay > 0) {
            days_ = address(this).balance / burnRatePerDay;
        }
        uint8 level = 0;
        if (days_ < 3) {
            level = 4;
        } else if (days_ < 7) {
            level = 3;
        } else if (days_ < 14) {
            level = 2;
        } else if (days_ < 30) {
            level = 1;
        }
        if (level != horizonLevel) {
            horizonLevel = level;
            emit HorizonAlert(days_, address(this).balance, burnRatePerDay, level);
        } else if (level >= 1) {
            // The 11.11 deadlock: with a stuck level the depot stayed
            // silent — a one-off faucet revert killed the auto-faucet
            // forever. While the level holds, the signal repeats every
            // tick; the converter kills duplicates (cooldown), not the
            // depot.
            emit HorizonAlert(days_, address(this).balance, burnRatePerDay, level);
        }
    }

    /// @notice Burn-rate calibration by the owner (from facts: totalFed / time).
    function setBurnRate(uint256 perDay_) external {
        require(msg.sender == owner, "owner only");
        burnRatePerDay = perDay_;
        emit BurnRateSet(perDay_);
    }

    // ------------------------------------------------------------------ owner

    function setMinReserve(uint256 minReserve_) external {
        require(msg.sender == owner, "owner only");
        minReserve = minReserve_;
        emit MinReserveSet(minReserve_);
    }

    function setDogContract(address dogContract_) external {
        require(msg.sender == owner, "owner only");
        emit DogSwitched(dogContract, dogContract_);
        emit PartnerRewired("dog", dogContract, dogContract_);
        dogContract = dogContract_;
    }

    /// @notice Partner hatches (ADR-EXPANSION: guards are set in stone,
    ///         partners are replaceable): change an address without a
    ///         redeploy of the depot. The zero address is forbidden;
    ///         every change emits an event.
    function setWatcherRvm(address watcherRvm_) external {
        require(msg.sender == owner, "owner only");
        require(watcherRvm_ != address(0), "zero address");
        emit PartnerRewired("watcherRvm", watcherRvm, watcherRvm_);
        watcherRvm = watcherRvm_;
    }

    function setSystem(address system_) external {
        require(msg.sender == owner, "owner only");
        require(system_ != address(0), "zero address");
        emit PartnerRewired("system", system, system_);
        system = system_;
    }

    function setMailbox(address mailbox_) external {
        require(msg.sender == owner, "owner only");
        require(mailbox_ != address(0), "zero address");
        emit PartnerRewired("mailbox", mailbox, mailbox_);
        mailbox = mailbox_;
    }

    function setWatcher(address watcher_) external {
        require(msg.sender == owner, "owner only");
        require(watcher_ != address(0), "zero address");
        emit PartnerRewired("watcher", watcher, watcher_);
        watcher = watcher_;
    }

    function setFeeding(uint256 dogFloor_, uint256 ration_) external {
        require(msg.sender == owner, "owner only");
        dogFloor = dogFloor_;
        ration = ration_;
        emit FeedingSet(dogFloor_, ration_);
    }

    function setReservePolicy(uint256 floor_, uint256 target_) external {
        require(msg.sender == owner, "owner only");
        reserveFloor = floor_;
        reserveTarget = target_;
        emit ReservePolicySet(floor_, target_);
    }

    function setWatcherPolicy(uint256 floor_, uint256 topUp_, uint256 sweepAbove_) external {
        require(msg.sender == owner, "owner only");
        watcherFloor = floor_;
        watcherTopUp = topUp_;
        watcherSweepAbove = sweepAbove_;
        emit WatcherPolicySet(floor_, topUp_, sweepAbove_);
    }

    /// @notice Conservating/moving leftovers (stand migrations).
    function withdraw(address to_, uint256 amount_) external {
        require(msg.sender == owner, "owner only");
        (bool ok,) = to_.call{value: amount_}("");
        require(ok, "withdraw failed");
    }
}
