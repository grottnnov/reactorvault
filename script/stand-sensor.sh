#!/usr/bin/env bash
# Stand sensor (W2.2, Lasna+Sepolia) — сессия стартует с этого отчёта.
# Правила (INCIDENTS.md, класс К8): getLogs ТОЛЬКО с явными числовыми
# диапазонами (latest молча пуст); диагностика «тает без событий» = трейс.
# Выход: sensor-report.txt рядом, код 0 = GREEN, 1 = RED.

set -u
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
RPC_L=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_S=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
OMNI=0x8888888888888888888888888888888888888888
REPORT=sensor-report.txt
. ./.env 2>/dev/null || true
RULES=${W2_RULES:?W2_RULES}; GAS=${W2_GASPAYER:?}; DOG=${W2_DOG:?}
FUND=${W2_FUND:?}; CONV=${W2_CONVERTER:?}; EXEC=${W2_EXECUTOR:?}; BUYER=${W2_BUYER:?}
RED=0
note() { printf '%s\n' "$*" >> "$REPORT"; }
alarm() { note "RED: $*"; RED=1; }
wei()  { python3 -c "print(f'{$1/1e18:.4f}')"; }

: > "$REPORT"
note "=== ReactorVault stand sensor: $(date -u '+%F %T') UTC ==="

BLK=$(cast block-number --rpc-url "$RPC_L")
note "lasna block: $BLK"

# --- газовые карманы реактивных: резерв, долг, сытость ---
for pair in "brain $RULES" "cashier $GAS" "dog $DOG" "converter $CONV" "depot $FUND"; do
  set -- $pair
  R=$(cast call "$OMNI" 'reserves(address)(uint256)' "$2" --rpc-url "$RPC_L" 2>/dev/null | awk '{print $1}')
  D=$(cast call "$OMNI" 'debts(address)(uint256)' "$2" --rpc-url "$RPC_L" 2>/dev/null | awk '{print $1}')
  R=${R:-0}; D=${D:-0}
  EFF=$(( R > D ? R - D : 0 ))
  note "$1: reserve=$(wei "$R") debt=$(wei "$D") eff=$(wei "$EFF")"
  [ "$D" -gt 0 ] && alarm "$1 в долге $(wei "$D") — доставка его колбеков стоит (К1)"
  [ "$1" != depot ] && [ "$EFF" -lt 50000000000000000 ] && alarm "$1 eff < 0.05 — голодный карман"
done

# --- склад: натив (кормит патруль), горизонт, счётчики ---
NF=$(cast balance "$FUND" --rpc-url "$RPC_L" 2>/dev/null || echo 0)
note "depot native (патрульный котёл): $(cast from-wei "$NF")"
[ "$(cast from-wei "$NF" | python3 -c 'import sys;print(1 if float(sys.stdin.read())<0.02 else 0)')" = 1 ] \
  && alarm "натив склада < 0.02 — патруль не сможет кормить (К1, инцидент #11)"
note "depot horizonLevel=$(cast call "$FUND" 'horizonLevel()(uint8)' --rpc-url "$RPC_L" 2>/dev/null | awk '{print $1}') fedCount=$(cast call "$FUND" 'fedCount()(uint256)' --rpc-url "$RPC_L" 2>/dev/null | awk '{print $1}')"

# --- патруль жив? события склада за последние 2 тика (явный диапазон!) ---
T0=$(( BLK / 10000 * 10000 - 10000 ))
EV=$(cast logs --from-block "$T0" --to-block "$BLK" --address "$FUND" --rpc-url "$RPC_L" --json 2>/dev/null \
     | python3 -c "import json,sys;d=json.load(sys.stdin);d=d.get('logs',d.get('result',[])) if isinstance(d,dict) else d;print(len(d))")
note "depot events за 2 тика (блоки $T0..$BLK): ${EV:-0}"
[ "${EV:-0}" -eq 0 ] && alarm "патруль молчал 2 тика — реакции стоп или склад пуст (трейс по правилу К8→К5)"

# --- Sepolia: результаты колбеков (очередь К7) ---
note "executor: rebalanceCount=$(cast call "$EXEC" 'rebalanceCount()(uint256)' --rpc-url "$RPC_S" 2>/dev/null | awk '{print $1}') tankedEth=$(cast call "$EXEC" 'totalTankedEth()(uint256)' --rpc-url "$RPC_S" 2>/dev/null | awk '{print $1}') ETHbal=$(cast from-wei "$(cast balance "$EXEC" --rpc-url "$RPC_S" 2>/dev/null || echo 0)")"
note "buyer: buysCount=$(cast call "$BUYER" 'buysCount()(uint256)' --rpc-url "$RPC_S" 2>/dev/null | awk '{print $1}')"

# --- кошельки оператора ---
note "A@Lasna: $(cast from-wei "$(cast balance 0xF696ae41aAb9A8979F18086d70d5e6A9Bf9FF53a --rpc-url "$RPC_L" 2>/dev/null || echo 0)") lREACT / A@Sepolia: $(cast from-wei "$(cast balance 0xF696ae41aAb9A8979F18086d70d5e6A9Bf9FF53a --rpc-url "$RPC_S" 2>/dev/null || echo 0)") ETH"

note "=== ${RED:+RED — см. RED-строки выше}${RED:-GREEN} ==="
cat "$REPORT"
exit "$RED"
