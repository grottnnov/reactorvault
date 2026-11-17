#!/usr/bin/env bash
# fix-adapters-acl-1711.sh — инцидент #19: передеплой обоих адаптеров пулов
# с onlyVault-гвардом (immutable assetVault; паттерн Uniswap v4
# onlyPoolManager / Yearn onlyVault), перенос whitelist и опустошение
# старых адаптеров штатным путём.
#
# Шаги (все tx от A, газ БЕЗ капа — урок OOG):
#   [1] деплой AavePoolAdapter(vault, pool, weth)   — Sepolia
#   [2] деплой MorphoPoolAdapter(vault, morpho, mp, irm) — mp снят со
#       СТАРОГО адаптера живьём (антидрейф), marketId обязан совпасть
#   [3] vault.authorizePoolAdapter ×2 (owner=A)
#   [4] executor.setPools(новая пара) (owner=A)
#   [5] vault.withdrawAll() — отзывает 0.0019 из старого Morpho к A,
#       ledger сбрасывается (totalDeposited=0)
#   [6] vault.deposit{0.0019} от A — свежий рабочий капитал (5% → батарея)
#   [7] .env: старые → *_OLD, upsert новые; позитив-сверки геттерами
#
# После: следующий тик исполнителя сам разложит свободный капитал по новым
# пулам (rebalance: deployToPool лучшего). Старые адаптеры пусты
# (principal=0 → withdraw ревертится AbovePrincipal) — безвредны.
#
# ФАКТ выполнения 17.11: [1]-[3],[6]-[8] из скрипта; [4] setPools и [5]
# withdrawAll упали на баге кавычек sendS (два адреса одним аргументом —
# cast send не парсил) и были повторены вручную той же сессией:
# setPools tx 0x07af6ac0…, withdrawAll tx 0x175fd753…, redeposit 0.002
# tx 0x2a9ecd57… (строка ниже исправлена пост-фактум, для повторного
# использования). Итог сверен геттерами: poolA/poolB=новые, старые
# пусты (principal=0), totalDeposited=0.002.
#
# Environment: DEPLOYER_PRIVATE_KEY, .env (W2_ASSETVAULT, W2_EXECUTOR,
# W2_AAVE_ADAPTER, W2_MORPHO_ADAPTER, W2_ORACLE).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
[ "$A" = "0xF696ae41aAb9A8979F18086d70d5e6A9Bf9FF53a" ] || { echo "❌ ключ не A ($A) — STOP"; exit 1; }

VAULT=${W2_ASSETVAULT:?W2_ASSETVAULT in .env}
EXEC=${W2_EXECUTOR:?W2_EXECUTOR in .env}
AAVE_OLD=${W2_AAVE_ADAPTER:?W2_AAVE_ADAPTER in .env}
MORPHO_OLD=${W2_MORPHO_ADAPTER:?W2_MORPHO_ADAPTER in .env}

MORPHO=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
AAVE_POOL=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
IRM=0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c
WETH=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c

sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
dep()   { local spec="src/$2.sol:$2"; [[ "$2" == *:* ]] && spec="src/${2%%:*}.sol:${2##*:}"
  forge create "$spec" --broadcast --rpc-url "$RPC_SEP" --private-key "$PK" \
    ${3:+--constructor-args $3} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }

echo "== [0] живое до: A=$(cast from-wei "$(cast balance $A --rpc-url $RPC_SEP)") ETH"
MID_OLD=$(cast call "$MORPHO_OLD" 'marketId()(bytes32)' --rpc-url "$RPC_SEP")
MP="($WETH,$WETH,$W2_ORACLE,$IRM,915000000000000000)"
echo "  старый marketId = $MID_OLD"
IN_OLD=$(cast call "$VAULT" "inPoolOf(address)(uint256)" "$MORPHO_OLD" --rpc-url "$RPC_SEP" | awk '{print $1}')
echo "  inPoolOf(старый morpho) = $IN_OLD wei"

echo "== [1] новый AavePoolAdapter(vault…)"
AAVE_NEW=$(dep "$RPC_SEP" "adapters/AavePoolAdapter:AavePoolAdapter" "$VAULT $AAVE_POOL $WETH")
[ -n "$AAVE_NEW" ] || { echo "❌ aave deploy failed"; exit 1; }
echo "  ✅ $AAVE_NEW"

echo "== [2] новый MorphoPoolAdapter(vault…)"
MORPHO_NEW=$(dep "$RPC_SEP" "adapters/MorphoPoolAdapter:MorphoPoolAdapter" "$VAULT $MORPHO $MP $IRM")
[ -n "$MORPHO_NEW" ] || { echo "❌ morpho deploy failed"; exit 1; }
echo "  ✅ $MORPHO_NEW"
MID_NEW=$(cast call "$MORPHO_NEW" 'marketId()(bytes32)' --rpc-url "$RPC_SEP")
[ "$MID_NEW" = "$MID_OLD" ] && echo "  ✅ marketId совпал (тот же рынок)" || { echo "❌ marketId дрейфнул: $MID_NEW — STOP"; exit 1; }
GV=$(cast call "$MORPHO_NEW" 'assetVault()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')
[ "$(echo $GV | tr '[:upper:]' '[:lower:]')" = "$(echo $VAULT | tr '[:upper:]' '[:lower:]')" ] && echo "  ✅ assetVault = сейф" || { echo "❌ assetVault ≠ сейф — STOP"; exit 1; }

echo "== [3] сейф: whitelist новых адаптеров"
sendS "$VAULT" 'authorizePoolAdapter(address)' "$AAVE_NEW"
sendS "$VAULT" 'authorizePoolAdapter(address)' "$MORPHO_NEW"

echo "== [4] исполнитель: setPools(новая пара)"
sendS "$EXEC" 'setPools(address,address)' "$AAVE_NEW" "$MORPHO_NEW"

echo "== [5] withdrawAll: опустошить старые (0.0019 → A, ledger reset)"
sendS "$VAULT" 'withdrawAll()'

echo "== [6] redeposit рабочего капитала"
sendS "$VAULT" 'deposit()' --value 1900000000000000

echo "== [7] .env: старые → *_OLD, upsert новые"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
save_old() { local v; v=$(grep -oP "^$1=\K.*" .env 2>/dev/null); [ -n "$v" ] && upsert "$1_OLD" "$v"; return 0; }
save_old W2_AAVE_ADAPTER;  upsert W2_AAVE_ADAPTER "$AAVE_NEW"
save_old W2_MORPHO_ADAPTER; upsert W2_MORPHO_ADAPTER "$MORPHO_NEW"

echo "== [8] позитив-сверки"
echo "  poolA = $(cast call "$EXEC" 'poolA()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  poolB = $(cast call "$EXEC" 'poolB()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  isPoolAdapter(newAave) = $(cast call "$VAULT" "isPoolAdapter(address)(bool)" "$AAVE_NEW" --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  isPoolAdapter(newMorpho) = $(cast call "$VAULT" "isPoolAdapter(address)(bool)" "$MORPHO_NEW" --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  inPoolOf(old morpho) = $(cast call "$VAULT" "inPoolOf(address)(uint256)" "$MORPHO_OLD" --rpc-url "$RPC_SEP" | awk '{print $1}') (ожидание 0)"
echo "  старый morpho principal = $(cast call "$MORPHO_OLD" 'principal()(uint256)' --rpc-url "$RPC_SEP" | awk '{print $1}') (ожидание 0)"
echo "  totalDeposited = $(cast call "$VAULT" 'totalDeposited()' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  A = $(cast from-wei "$(cast balance $A --rpc-url $RPC_SEP)") ETH"
echo "ГОТОВО. Следующий тик исполнителя разложит капитал по новым пулам."
