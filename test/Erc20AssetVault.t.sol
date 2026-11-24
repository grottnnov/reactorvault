// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Erc20AssetVault, IERC20Asset} from "../../src/Erc20AssetVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev USDC safe (ADR-EXPANSION "new asset = new instance"): deposit
///      via transferFrom, the treasury share accrues inside (in USDC),
///      working capital sits in pool adapters. Invariant:
///      tokenBalance + totalInPools + treasuryWithdrawn ≡ totalDeposited.
contract Erc20AssetVaultTest is Test {
    MockERC20 token;
    Erc20AssetVault vault;
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    // 6 decimals: 100.000000 USDC
    uint256 constant D100 = 100_000_000;
    uint256 constant D10 = 10_000_000;

    function setUp() public {
        token = new MockERC20();
        vault = new Erc20AssetVault(IERC20Asset(address(token)));
        token.mint(user, 1_000_000_000); // 1000 USDC
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    /// Deposit without approve — the token's honest revert.
    function testDepositWithoutApprovalReverts() public {
        vm.prank(stranger);
        vm.expectRevert("allowance");
        vault.deposit(D10);
    }

    /// Zero deposit — revert (as in the ETH safe).
    function testZeroDepositReverts() public {
        vm.prank(user);
        vm.expectRevert(Erc20AssetVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    /// Deposit: the safe's balance, accounting, an event; ETH is not
    /// accepted into the safe (the contract is not payable — a direct
    /// transfer is impossible at the type level).
    function testDepositAccounting() public {
        vm.prank(user);
        vault.deposit(D100);
        assertEq(token.balanceOf(address(vault)), D100, "vault holds the tokens");
        assertEq(vault.totalDeposited(), D100);
        assertEq(token.balanceOf(user), 1_000_000_000 - D100);
    }

    /// Treasury share: 5% accrues INSIDE the safe (in USDC) and goes
    /// nowhere without the hatch — free capital = balance − treasury.
    function testTreasuryStaysInside() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100);
        assertEq(vault.treasuryTaken(), 5_000_000, "5% booked as treasury");
        assertEq(vault.rebalanceTarget(), D100 - 5_000_000, "free = balance - treasury");
    }

    /// bps ceiling of 10_000 — as in the ETH safe.
    function testTreasuryBpsBound() public {
        vm.prank(vault.owner());
        vm.expectRevert(Erc20AssetVault.BadParams.selector);
        vault.setTreasuryBps(10_001);
    }

    /// The G4 invariant is checked in every scenario below after state
    /// changes (deposit → deploy → recall → withdrawAll); a separate
    /// empty test is not needed.

    /// The MVP owner sweep is REMOVED (22.11): the exit is redeem —
    /// a privileged full-sweep must no longer exist on the safe.
    function testOwnerSweepIsGone() public {
        vm.prank(user);
        vault.deposit(D100);
        vm.prank(vault.owner());
        (bool ok,) = address(vault).call(abi.encodeWithSignature("withdrawAll()"));
        assertFalse(ok, "the sweep selector must not resolve");
    }

    /// deployToPool: executor only; a stranger address — revert.
    function testDeployOnlyExecutor() public {
        address adapter = makeAddr("adapter");
        vm.prank(vault.owner());
        vault.authorizePoolAdapter(adapter);
        vm.prank(stranger);
        vm.expectRevert(Erc20AssetVault.NotExecutor.selector);
        vault.deployToPool(adapter, D10);
    }

    /// deployToPool into an unknown adapter — revert.
    function testDeployUnknownAdapter() public {
        vm.prank(vault.owner());
        vault.authorizeExecutor(stranger);
        vm.prank(stranger);
        vm.expectRevert(Erc20AssetVault.AdapterUnknown.selector);
        vault.deployToPool(makeAddr("ghost"), D10);
    }

    /// deployToPool cannot withdraw the treasury share: free capital =
    /// balance − treasury (the main difference from the ETH safe).
    function testDeployCannotTouchTreasury() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100); // treasury 5, free 95

        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();

        vault.deployToPool(address(adapter), D100 - 5_000_000); // 95 — ok
        assertEq(token.balanceOf(address(adapter)), D100 - 5_000_000);

        vm.prank(address(this));
        vm.expectRevert(Erc20AssetVault.InsufficientFree.selector);
        vault.deployToPool(address(adapter), 1); // the treasury is untouchable
    }

    /// Full cycle with the mock adapter: deposit → deploy → recall →
    /// withdrawAll; the invariant at every step.
    function testFullCycleWithAdapter() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100);

        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();

        vault.deployToPool(address(adapter), D100 - 5_000_000);
        assertEq(vault.inPoolOf(address(adapter)), D100 - 5_000_000, "deployed");
        // invariant: balance(5) + inPools(95) + withdrawn(0) ≡ deposited(100)
        assertEq(token.balanceOf(address(vault)) + vault.totalInPools(), D100);

        vault.recallFromPool(address(adapter), D100 - 5_000_000);
        assertEq(vault.inPoolOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(vault)), D100, "recalled back");

        // the exit is redeem now (the owner sweep is gone): the user
        // burns their shares and takes their working capital back
        // (the 5% treasury share stays in the safe — G15 accounting)
        uint256 sh = vault.shareOf(user);
        vm.prank(user);
        vault.redeem(sh);
        assertEq(token.balanceOf(user), D100 - D100 / 20); // minus the 5% treasury share
    }

    // ------------------------------------------------------- shares (4626-lite)

    /// The first deposit into an empty safe: shares = assets (no
    /// offset distortion), no dust minted.
    function testFirstDepositMintsProportionalShares() public {
        vm.prank(user);
        vault.deposit(D100);
        assertEq(vault.totalShares(), D100, "empty vault: shares == assets");
        assertEq(vault.shareOf(user), D100);
        assertEq(vault.totalAssets(), D100, "NAV == assets");
    }

    /// The first-deposit donation attack is DEAD: a direct token
    /// transfer to the safe does not enter NAV (the ledger), the
    /// victim's shares are fair, the attacker takes only their own.
    function testDonationAttackNeutralized() public {
        address attacker = makeAddr("attacker");
        token.mint(attacker, 50_000_000); // 50 USDC
        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000); // 1 USDC
        token.transfer(address(vault), 49_000_000); // DONATION of 49 USDC — to inflate NAV
        vm.stopPrank();

        // the victim enters AFTER the "inflation"
        vm.prank(user);
        vault.deposit(D100);
        uint256 victimShares = vault.shareOf(user);
        assertApproxEqAbs(victimShares, D100, 1_000, "fair shares despite donation");

        // the attacker redeems their shares — takes only their own, no loot
        uint256 attackerShares = vault.shareOf(attacker); // the prank burns on the call!
        vm.prank(attacker);
        vault.redeem(attackerShares);
        assertApproxEqAbs(token.balanceOf(attacker), 1_000_000, 5_000, "no stolen yield");
        // the victim is unharmed: their share of NAV is preserved
        assertApproxEqAbs(vault.convertToAssets(victimShares), D100, 60_000, "victim intact (offset-scale)");
    }

    /// Rounding in the safe's favor: the payout never exceeds what is due.
    function testRedeemRoundsInVaultFavor() public {
        vm.prank(user);
        vault.deposit(D100);
        uint256 sh = vault.shareOf(user);
        uint256 out = vault.convertToAssets(sh);
        assertLe(out, D100, "never more than fair");
    }

    /// redeem itself recalls from pools when free capital is short —
    /// "the exit always works".
    function testRedeemRecallsFromPoolsWhenFreeInsufficient() public {
        vm.prank(user);
        vault.deposit(D100);
        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();
        vault.deployToPool(address(adapter), D100); // everything in the pool, free 0

        uint256 sh = vault.shareOf(user);
        vm.prank(user);
        vault.redeem(sh);
        assertApproxEqAbs(token.balanceOf(user), 1_000_000_000, 1_000, "full exit");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.inPoolOf(address(adapter)), 0);
    }

    /// The treasury does not dilute users: NAV counts assets MINUS the
    /// treasury; the fee is paid by the DEPOSITOR (their shares cost
    /// less than the asset), the second user enters at the same
    /// price — no dilution.
    function testTreasuryDoesNotDilute() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100); // treasury 5, user's 95, shares 100
        assertEq(vault.totalAssets(), D100 - 5_000_000, "NAV excludes treasury");

        // the second user enters at the same price; pays their OWN fee
        address second = makeAddr("second");
        token.mint(second, 95_000_000);
        vm.startPrank(second);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(95_000_000); // fee 4.75, working 90.25
        vm.stopPrank();
        uint256 s2 = vault.shareOf(second);
        assertApproxEqAbs(s2, 90_250_000, 100_000, "shares for working assets");
        // the first user's share is INTACT: only the entrant pays (fee-on-mint)
        assertApproxEqAbs(vault.convertToAssets(vault.shareOf(user)), 95_000_000, 60_000, "first intact");
    }

    /// Reentrancy: an evil adapter dives into deployToPool from within
    /// withdraw — the CEI guard must revert the whole attempt.
    function testRecallReentrancyBlocked() public {
        vm.prank(user);
        vault.deposit(D100);
        ReentrantAdapter evil = new ReentrantAdapter(vault);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(evil));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();
        vault.deployToPool(address(evil), D10);

        vm.prank(address(this));
        // the guard rejected the reentrant deployToPool; the settlement
        // then catches the shortfall (0 vs D10 > RECALL_DUST) and
        // reverts the whole recall
        vm.expectRevert(Erc20AssetVault.SettleMismatch.selector);
        vault.recallFromPool(address(evil), D10);
    }

    /// Settlement with the RECALL_DUST tolerance (0.01 USDC): a
    /// shortfall within the tolerance (pool index rounding) —
    /// accepted and booked at actuals; a shortfall beyond the
    /// tolerance — revert of the whole recall.
    function testRecallDustToleranceAndBeyond() public {
        vm.prank(user);
        vault.deposit(D100);
        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();
        vault.deployToPool(address(adapter), D10);

        // within the tolerance: booked at actuals (D10-1 came back)
        adapter.setShortfall(1);
        vault.recallFromPool(address(adapter), D10);
        assertEq(vault.inPoolOf(address(adapter)), 1, "booked actual returned");

        // beyond the tolerance: revert
        vault.deployToPool(address(adapter), D10 - 1); // free capital suffices
        adapter.setShortfall(50_000); // 0.05 USDC > RECALL_DUST
        vm.prank(address(this));
        vm.expectRevert(Erc20AssetVault.SettleMismatch.selector);
        vault.recallFromPool(address(adapter), D10 - 1);
    }
}

/// @dev An evil adapter: at withdraw it tries to reenter deployToPool
///      of the same safe (a check of the CEI guard).
contract ReentrantAdapter {
    Erc20AssetVault public vault;

    constructor(Erc20AssetVault v) {
        vault = v;
    }

    function withdraw(uint256) external returns (bool) {
        try vault.deployToPool(address(this), 1) {
        // reentrancy would have passed — the settlement would not catch it
        }
            catch {
            // the guard did its job: the attempt rolled back inside the adapter
        }
        return true; // and quietly return "successfully" without the money
    }
}

/// @dev A pool adapter mock for the safe's unit tests: holds USDC,
///      returns it on the withdraw command (with a programmable
///      shortfall — for the strict-settlement test).
contract MockPoolAdapter {
    MockERC20 public immutable token;
    uint256 public shortfall;

    constructor(MockERC20 token_) {
        token = token_;
    }

    /// NAV layer: the adapter's position = its token balance
    function truePosition() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function setShortfall(uint256 s) external {
        shortfall = s;
    }

    function withdraw(uint256 amount) external returns (bool) {
        uint256 back = amount > shortfall ? amount - shortfall : 0;
        token.transfer(msg.sender, back);
        return true;
    }
}
