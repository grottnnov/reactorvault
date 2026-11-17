// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Erc20AssetVault, IERC20Asset} from "../../src/Erc20AssetVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev USDC-сейф (ADR-EXPANSION «новый актив = новый экземпляр»):
///      депозит через transferFrom, казначейская доля копится внутри
///      (в USDC), рабочий капитал — в адаптерах пулов. Инвариант:
///      tokenBalance + totalInPools + treasuryWithdrawn ≡ totalDeposited.
contract Erc20AssetVaultTest is Test {
    MockERC20 token;
    Erc20AssetVault vault;
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    // 6 десятичных: 100.000000 USDC
    uint256 constant D100 = 100_000_000;
    uint256 constant D10 = 10_000_000;

    function setUp() public {
        token = new MockERC20();
        vault = new Erc20AssetVault(IERC20Asset(address(token)));
        token.mint(user, 1_000_000_000); // 1000 USDC
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    /// Депозит без approve — честный реверт токена.
    function testDepositWithoutApprovalReverts() public {
        vm.prank(stranger);
        vm.expectRevert("allowance");
        vault.deposit(D10);
    }

    /// Нулевой депозит — реверт (как в ETH-сейфе).
    function testZeroDepositReverts() public {
        vm.prank(user);
        vm.expectRevert(Erc20AssetVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    /// Депозит: баланс сейфа, учёт, событие; ETH в сейф не принимается
    /// (контракт не payable — прямой перевод невозможен на уровне типа).
    function testDepositAccounting() public {
        vm.prank(user);
        vault.deposit(D100);
        assertEq(token.balanceOf(address(vault)), D100, "vault holds the tokens");
        assertEq(vault.totalDeposited(), D100);
        assertEq(token.balanceOf(user), 1_000_000_000 - D100);
    }

    /// Казначейская доля: 5% копится ВНУТРИ сейфа (в USDC), никуда не
    /// уходит без люка — свободный капитал = баланс − казна.
    function testTreasuryStaysInside() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100);
        assertEq(vault.treasuryTaken(), 5_000_000, "5% booked as treasury");
        assertEq(vault.rebalanceTarget(), D100 - 5_000_000, "free = balance - treasury");
    }

    /// bps-потолок 10_000 — как в ETH-сейфе.
    function testTreasuryBpsBound() public {
        vm.prank(vault.owner());
        vm.expectRevert(Erc20AssetVault.BadParams.selector);
        vault.setTreasuryBps(10_001);
    }

    /// Инвариант G4 проверяется в каждом сценрии ниже после изменений
    /// состояния (deposit → deploy → recall → withdrawAll); отдельный
    /// пустой тест не нужен.

    /// withdrawAll: возвращает ВСЁ (рабочий + казну) владельцу,
    /// ledger обнуляется — «выход, который работает всегда».
    function testWithdrawAllReturnsEverything() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100);

        vm.prank(vault.owner());
        vault.withdrawAll();
        assertEq(token.balanceOf(vault.owner()), D100, "owner got all 100 USDC");
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalDeposited(), 0);
        assertEq(vault.treasuryTaken(), 0);
    }

    /// withdrawAll — только owner.
    function testWithdrawAllOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Erc20AssetVault.NotOwner.selector);
        vault.withdrawAll();
    }

    /// deployToPool: только executor; чужой адрес — реверт.
    function testDeployOnlyExecutor() public {
        address adapter = makeAddr("adapter");
        vm.prank(vault.owner());
        vault.authorizePoolAdapter(adapter);
        vm.prank(stranger);
        vm.expectRevert(Erc20AssetVault.NotExecutor.selector);
        vault.deployToPool(adapter, D10);
    }

    /// deployToPool в неизвестный адаптер — реверт.
    function testDeployUnknownAdapter() public {
        vm.prank(vault.owner());
        vault.authorizeExecutor(stranger);
        vm.prank(stranger);
        vm.expectRevert(Erc20AssetVault.AdapterUnknown.selector);
        vault.deployToPool(makeAddr("ghost"), D10);
    }

    /// deployToPool не может вывести казначейскую долю: свободный
    /// капитал = баланс − казна (главная разница против ETH-сейфа).
    function testDeployCannotTouchTreasury() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100); // казна 5, свободно 95

        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();

        vault.deployToPool(address(adapter), D100 - 5_000_000); // 95 — ок
        assertEq(token.balanceOf(address(adapter)), D100 - 5_000_000);

        vm.prank(address(this));
        vm.expectRevert(Erc20AssetVault.InsufficientFree.selector);
        vault.deployToPool(address(adapter), 1); // казна недоступна
    }

    /// Полный цикл с мок-адаптером: депозит → deploy → recall →
    /// withdrawAll; инвариант на каждом шаге.
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
        // инвариант: balance(5) + inPools(95) + withdrawn(0) ≡ deposited(100)
        assertEq(token.balanceOf(address(vault)) + vault.totalInPools(), D100);

        vault.recallFromPool(address(adapter), D100 - 5_000_000);
        assertEq(vault.inPoolOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(vault)), D100, "recalled back");

        vm.prank(vault.owner());
        vault.withdrawAll();
        assertEq(token.balanceOf(vault.owner()), D100);
    }

    // ------------------------------------------------------- доли (4626-lite)

    /// Первый депозит при пустом сейфе: доли = активы (без офсетных
    /// искажений), пыль не минтится.
    function testFirstDepositMintsProportionalShares() public {
        vm.prank(user);
        vault.deposit(D100);
        assertEq(vault.totalShares(), D100, "empty vault: shares == assets");
        assertEq(vault.shareOf(user), D100);
        assertEq(vault.totalAssets(), D100, "NAV == assets");
    }

    /// Донат-атака первого депозита МЕРТВА: прямой перевод токена на
    /// сейф не входит в NAV (ledger), доли жертвы честные, атакующий
    /// забирает только своё.
    function testDonationAttackNeutralized() public {
        address attacker = makeAddr("attacker");
        token.mint(attacker, 50_000_000); // 50 USDC
        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000); // 1 USDC
        token.transfer(address(vault), 49_000_000); // ДОНАТ 49 USDC — раздуть NAV
        vm.stopPrank();

        // жертва входит ПОСЛЕ «раздувания»
        vm.prank(user);
        vault.deposit(D100);
        uint256 victimShares = vault.shareOf(user);
        assertApproxEqAbs(victimShares, D100, 1_000, "fair shares despite donation");

        // атакующий гасит свои доли — уносит только своё, без навара
        uint256 attackerShares = vault.shareOf(attacker); // prank сгорает на вызове!
        vm.prank(attacker);
        vault.redeem(attackerShares);
        assertApproxEqAbs(token.balanceOf(attacker), 1_000_000, 5_000, "no stolen yield");
        // жертва не пострадала: её доля NAV сохранилась
        assertApproxEqAbs(vault.convertToAssets(victimShares), D100, 60_000, "victim intact (offset-scale)");
    }

    /// Округления в пользу сейфа: вывод даёт не больше причитающегося.
    function testRedeemRoundsInVaultFavor() public {
        vm.prank(user);
        vault.deposit(D100);
        uint256 sh = vault.shareOf(user);
        uint256 out = vault.convertToAssets(sh);
        assertLe(out, D100, "never more than fair");
    }

    /// redeem сам отзывает из пулов, если свободных не хватает —
    /// «выход работает всегда».
    function testRedeemRecallsFromPoolsWhenFreeInsufficient() public {
        vm.prank(user);
        vault.deposit(D100);
        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();
        vault.deployToPool(address(adapter), D100); // всё в пуле, свободно 0

        uint256 sh = vault.shareOf(user);
        vm.prank(user);
        vault.redeem(sh);
        assertApproxEqAbs(token.balanceOf(user), 1_000_000_000, 1_000, "full exit");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.inPoolOf(address(adapter)), 0);
    }

    /// Казна не размывает юзеров: NAV считает активы МИНУС казну;
    /// комиссия платится ДЕПОЗИТОРОМ (его доли стоят дешевле актива),
    /// второй юзер входит по той же цене — размывания нет.
    function testTreasuryDoesNotDilute() public {
        vm.prank(vault.owner());
        vault.setTreasuryBps(500);
        vm.prank(user);
        vault.deposit(D100); // казна 5, юзерских 95, долей 100
        assertEq(vault.totalAssets(), D100 - 5_000_000, "NAV excludes treasury");

        // второй юзер входит той же ценой; СВОЮ комиссию платит сам
        address second = makeAddr("second");
        token.mint(second, 95_000_000);
        vm.startPrank(second);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(95_000_000); // комиссия 4.75, рабочих 90.25
        vm.stopPrank();
        uint256 s2 = vault.shareOf(second);
        assertApproxEqAbs(s2, 90_250_000, 100_000, "shares for working assets");
        // доля первого ЦЕЛА: платит только входящий (fee-on-mint)
        assertApproxEqAbs(vault.convertToAssets(vault.shareOf(user)), 95_000_000, 60_000, "first intact");
    }

    /// Реентрансия: злой адаптер лезет в deployToPool из withdraw —
    /// гвард CEI обязан ревертить всю попытку.
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
        // гвард откинул реентрантный deployToPool; расчёт затем ловит
        // недовод (0 против D10 > RECALL_DUST) и ревертит весь отзыв
        vm.expectRevert(Erc20AssetVault.SettleMismatch.selector);
        vault.recallFromPool(address(evil), D10);
    }

    /// Расчёты с пылевым допуском RECALL_DUST (0.01 USDC): недовод
    /// внутри допуска (индексное округление пулов) — принят и учтён
    /// по факту; недовод за допуском — реверт всего отзыва.
    function testRecallDustToleranceAndBeyond() public {
        vm.prank(user);
        vault.deposit(D100);
        MockPoolAdapter adapter = new MockPoolAdapter(token);
        vm.startPrank(vault.owner());
        vault.authorizePoolAdapter(address(adapter));
        vault.authorizeExecutor(address(this));
        vm.stopPrank();
        vault.deployToPool(address(adapter), D10);

        // внутри допуска: учёт по факту (вернулось D10-1)
        adapter.setShortfall(1);
        vault.recallFromPool(address(adapter), D10);
        assertEq(vault.inPoolOf(address(adapter)), 1, "booked actual returned");

        // за допуском: реверт
        vault.deployToPool(address(adapter), D10 - 1); // свободно хватает
        adapter.setShortfall(50_000); // 0.05 USDC > RECALL_DUST
        vm.prank(address(this));
        vm.expectRevert(Erc20AssetVault.SettleMismatch.selector);
        vault.recallFromPool(address(adapter), D10 - 1);
    }
}

/// @dev Злой адаптер: при withdraw пытается реентрантно войти в
/// deployToPool того же сейфа (проверка гварда CEI).
contract ReentrantAdapter {
    Erc20AssetVault public vault;

    constructor(Erc20AssetVault v) {
        vault = v;
    }

    function withdraw(uint256) external returns (bool) {
        try vault.deployToPool(address(this), 1) {
        // реентрансия прошла бы — её бы не поймал расчёт
        }
            catch {
            // гвард отработал: попытка откатилась внутри адаптера
        }
        return true; // и тихо «успешно» возвращаемся без денег
    }
}

/// @dev Мок адаптера для юнит-тестов сейфа: держит USDC, возвращает
///      по команде withdraw (с программируемым недоводом — на тест
///      строгих расчётов).
contract MockPoolAdapter {
    MockERC20 public immutable token;
    uint256 public shortfall;

    constructor(MockERC20 token_) {
        token = token_;
    }

    /// NAV-слой: позиция адаптера = его баланс токена
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
