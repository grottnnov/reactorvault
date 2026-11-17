#!/usr/bin/env bash
# deploy-pair-v3-1711.sh — ADR-PURCHASE-SAFETY B2: передеплой пары
# автокрана (конвертер v3 со стоп-курсом + покупщик v2 с паузой).
#
# ГВАРД ОКНА: запускать ТОЛЬКО после buys=3 старого покупщика и ДО конца
# cooldown старой пары (~12:40 UTC 18.11): старый конвертер в cooldown
# молчит, новый принимает эстафету, дубль-заказа исключён. Скрипт сам
# проверяет buysCount>=3 и выходит, если рано.
#
# Шаги (все tx от A; газ БЕЗ капа — урок OOG #16):
#   [0] гварды: buys>=3, бюджеты, precompute Lasna N -> конвертер v3
#   [1] Sepolia: покупщик v2 (конструктор = БУДУЩИЙ адрес конвертера) →
#       setFaucet(живой кран) → касса 0.04 ETH (источник: 0.02/покупку
#       замер 16.11, покупка/24ч → 2 суток; L1-норма доливки)
#   [2] Lasna: конвертер v3 (фактический адрес покупщика) → сверка
#       precompute 1:1 (нонсы — ни одного лишнего tx!)
#   [3] init() обеих подписок + setTrigger(2, 86400) — канон уровня
#   [4] deactivate() СТАРОГО конвертера (0x315D…fcDb) — отписка обеих
#       тем; остатки его резерва (~0.10 lREACT) замораживаются (L6)
#   [5] склад: removeWard(старый конвертер) + addWard(новый, 0.05/0.1)
#       — чек-лист миграции #18: кормление переезжает ВМЕСТЕ со связью
#   [6] .env: старая пара → W2_CONVERTER_V2_RETIRED/W2_BUYER_V2_RETIRED,
#       новые → W2_CONVERTER/W2_BUYER; сенсор; позитив-сверки
#
# ФАКТ выполнения 17.11 (15:18-15:40 UTC): buys=3 подтверждён живьём
# (тик 8 580 001 → заказ 8 580 002 → покупка → выплата крана 2.0 за
# 4 блока). Отклонения от скрипта: (а) у A@Lasna не хватило lREACT на
# газ деплоя (0.15 < ~0.5; узел отвечал «storage out of gas») —
# самозаправка краном 0.01 ETH → +1.05 lREACT (tx 0x2e184d9f…);
# (б) шаг [1] касса падал на 'deposit()' (нет такой функции — перевод);
# (в) шаги [2]-[5] выполнены вручную той же сессией (форк-anvil
# подтвердил диагноз газа). Стартовый резерв конвертера 0.1 lREACT
# (depositTo от A) — сенсор GREEN. Итог: conv3 0x63ae…2A15
# (precompute 1:1), buyer3 0xAD9a…EA88, касса 0.04, подписки ×2
# (MCP: proven), старая пара retired, ward-реестр переведён.
#
# Environment: DEPLOYER_PRIVATE_KEY, .env (W2_FUND, W2_CONVERTER,
# W2_BUYER).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
[ "$A" = "0xF696ae41aAb9A8979F18086d70d5e6A9Bf9FF53a" ] || { echo "❌ ключ не A ($A) — STOP"; exit 1; }

FUND=${W2_FUND:?W2_FUND in .env}
CONV_OLD=${W2_CONVERTER:?W2_CONVERTER in .env}
BUY_OLD=${W2_BUYER:?W2_BUYER in .env}

PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy
FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434   # живой кран (Sepolia)
FAUCET_RVM=0x5cbc52a390e69d9193996aebfb53f7b97db6cf51 # Lasna-плательщик крана (замер 16.11)
T_HORIZON=$(cast keccak 'HorizonAlert(uint256,uint256,uint256,uint8)')
T_FUNDED=$(cast keccak 'Funded(address,uint256)')

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys
import sys as s
try:
  r=json.load(s.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])
except Exception as e: print('  ❌ tx FAILED (см. выше)'); s.exit(1)"; }
sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys
import sys as s
try:
  r=json.load(s.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])
except Exception as e: print('  ❌ tx FAILED (см. выше)'); s.exit(1)"; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
depL()  { forge create "$1" --broadcast --rpc-url "$RPC_LASNA" --private-key "$PK" \
            ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
depS()  { forge create "$1" --broadcast --rpc-url "$RPC_SEP" --private-key "$PK" \
            ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
bal()   { cast from-wei "$(cast balance "$1" --rpc-url "$2" 2>/dev/null)"; }

echo "== [0] гварды окна и бюджеты"
BUYS=$(cast call "$BUY_OLD" 'buysCount()(uint256)' --rpc-url "$RPC_SEP" | awk '{print $1}')
[ "${BUYS:-0}" -ge 3 ] || { echo "❌ buysCount=$BUYS < 3 — окно ещё не открылось. STOP"; exit 1; }
echo "  ✅ старый покупщик buysCount=$BUYS"
echo "  A@Sepolia=$(bal $A $RPC_SEP) ETH (нужно ≥0.045), A@Lasna=$(bal $A $RPC_LASNA) lREACT (нужно ≥0.6 на газ деплоя)"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
CONV3=$(pre "$N"); echo "  precompute конвертер v3 (Lasna N=$N) = $CONV3"

echo "== [1] Sepolia: покупщик v2 + кран + касса 0.04"
BUY3=$(depS "src/FuelConverter.sol:FuelBuyer" "$PROXY $CONV3 $FUND")
[ -n "$BUY3" ] || { echo "❌ buyer deploy failed"; exit 1; }
echo "  ✅ покупщик v3-пары = $BUY3"
sendS "$BUY3" 'setFaucet(address)' "$FAUCET"
# касса = перевод на receive() покупщика (deposit() у него НЕТ — правка 17.11)
sendS "$BUY3" --value 40000000000000000

echo "== [2] Lasna: конвертер v3 (нонсы: между precompute и деплоем ни одного tx)"
CONV_REAL=$(depL "src/FuelConverter.sol:FuelConverter" "$FUND $BUY3 $T_HORIZON $T_FUNDED $FAUCET_RVM")
[ -n "$CONV_REAL" ] || { echo "❌ converter deploy failed"; exit 1; }
[ "$CONV_REAL" = "$CONV3" ] && echo "  ✅ precompute совпал 1:1" || { echo "❌ дрейф нонсов: $CONV_REAL ≠ $CONV3 — STOP"; exit 1; }

echo "== [3] взвод: init (обе подписки) + setTrigger(2, 86400)"
send "$CONV_REAL" 'init()'
send "$CONV_REAL" 'setTrigger(uint8,uint64)' "2 86400"

echo "== [4] retire старой пары: deactivate конвертера (его cooldown до ~12:40 UTC 18.11)"
send "$CONV_OLD" 'deactivate()'

echo "== [5] склад: кормление переезжает (чек-лист #18)"
send "$FUND" 'removeWard(address)' "$CONV_OLD"
send "$FUND" 'addWard(address,uint256,uint256)' "$CONV_REAL 50000000000000000 100000000000000000"

echo "== [6] .env: старая пара → *_V2_RETIRED, новые на место"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
upsert W2_CONVERTER_V2_RETIRED "$CONV_OLD"
upsert W2_BUYER_V2_RETIRED "$BUY_OLD"
upsert W2_CONVERTER "$CONV_REAL"
upsert W2_BUYER "$BUY3"

echo "== [7] позитив-сверки"
echo "  conv3.buyer = $(cast call "$CONV_REAL" 'buyer()(address)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.fund  = $(cast call "$CONV_REAL" 'fund()(address)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.active= $(cast call "$CONV_REAL" 'active()(bool)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.rateStopped = $(cast call "$CONV_REAL" 'rateStopped()(bool)' --rpc-url "$RPC_LASNA" | awk '{print $1}') (ожидание false)"
echo "  conv3.MIN_PAYOUT = $(cast call "$CONV_REAL" 'MIN_PAYOUT_PER_BUY()(uint256)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.triggerLevel/cooldown = $(cast call "$CONV_REAL" 'triggerLevel()(uint8)' --rpc-url "$RPC_LASNA" | awk '{print $1}') / $(cast call "$CONV_REAL" 'cooldown()(uint64)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  buyer3.faucet = $(cast call "$BUY3" 'faucet()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  buyer3.paused = $(cast call "$BUY3" 'paused()(bool)' --rpc-url "$RPC_SEP" | awk '{print $1}') (ожидание false)"
echo "  buyer3.касса = $(bal $BUY3 $RPC_SEP) ETH"
echo "  старый conv.active = $(cast call "$CONV_OLD" 'active()(bool)' --rpc-url "$RPC_LASNA" | awk '{print $1}') (ожидание false)"
echo "  wardCount склада = $(cast call "$FUND" 'wardCount()(uint256)' --rpc-url "$RPC_LASNA" | awk '{print $1}') (ожидание 3)"
echo "  A@Sepolia = $(bal $A $RPC_SEP) ETH"
echo "ГОТОВО. Следующая тревога уровня ≥2 уйдёт на новую пару; сенсор в cron подхватит."
