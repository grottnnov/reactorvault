#!/usr/bin/env bash
# deploy-pair-v3-1711.sh — ADR-PURCHASE-SAFETY B2: redeploy the
# auto-faucet pair (converter v3 with the rate stop + buyer v2 with
# the pause).
#
# WINDOW GUARD: run ONLY after the old buyer's buys=3 and BEFORE the
# old pair's cooldown ends (~12:40 UTC 18.11): the old converter sits
# silent in cooldown, the new one takes the baton, a duplicate order
# is excluded. The script itself checks buysCount>=3 and exits if it
# is early.
#
# Steps (all tx from A; gas with NO cap — the OOG lesson #16):
#   [0] guards: buys>=3, budgets, precompute Lasna N -> converter v3
#   [1] Sepolia: buyer v2 (constructor = the FUTURE converter address) →
#       setFaucet(live faucet) → till 0.04 ETH (source: 0.02/purchase,
#       measured 16.11, one purchase/24h → 2 days; the L1 top-up norm)
#   [2] Lasna: converter v3 (the buyer's actual address) → verify the
#       precompute 1:1 (nonces — not a single extra tx!)
#   [3] init() both subscriptions + setTrigger(2, 86400) — the level
#       canon
#   [4] deactivate() the OLD converter (0x315D…fcDb) — unsubscribes
#       both topics; its reserve leftovers (~0.10 lREACT) get frozen (L6)
#   [5] depot: removeWard(old converter) + addWard(new, 0.05/0.1)
#       — migration checklist #18: feeding moves TOGETHER with the link
#   [6] .env: old pair → W2_CONVERTER_V2_RETIRED/W2_BUYER_V2_RETIRED,
#       new → W2_CONVERTER/W2_BUYER; the sensor; positive checks
#
# EXECUTION FACT 17.11 (15:18-15:40 UTC): buys=3 confirmed live (tick
# 8 580 001 → order 8 580 002 → purchase → faucet payout 2.0 in 4
# blocks). Deviations from the script: (a) A@Lasna lacked the lREACT
# for deploy gas (0.15 < ~0.5; the node answered "storage out of
# gas") — a faucet self-refuel of 0.01 ETH → +1.05 lREACT (tx
# 0x2e184d9f…); (b) the step [1] till failed on 'deposit()' (no such
# function — a transfer); (c) steps [2]-[5] were done manually in the
# same session (an anvil fork confirmed the gas diagnosis). The
# converter's starting reserve 0.1 lREACT (depositTo from A) — the
# sensor GREEN. Outcome: conv3 0x63ae…2A15 (precompute 1:1), buyer3
# 0xAD9a…EA88, till 0.04, subscriptions ×2 (MCP: proven), the old
# pair retired, the ward registry moved over.
#
# Environment: DEPLOYER_PRIVATE_KEY, .env (W2_FUND, W2_CONVERTER,
# W2_BUYER).
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
[ "$A" = "0xF696ae41aAb9A8979F18086d70d5e6A9Bf9FF53a" ] || { echo "❌ key is not A ($A) — STOP"; exit 1; }

FUND=${W2_FUND:?W2_FUND in .env}
CONV_OLD=${W2_CONVERTER:?W2_CONVERTER in .env}
BUY_OLD=${W2_BUYER:?W2_BUYER in .env}

PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy
FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434   # live faucet (Sepolia)
FAUCET_RVM=0x5cbc52a390e69d9193996aebfb53f7b97db6cf51 # the faucet's Lasna payer (measured 16.11)
T_HORIZON=$(cast keccak 'HorizonAlert(uint256,uint256,uint256,uint8)')
T_FUNDED=$(cast keccak 'Funded(address,uint256)')

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys
import sys as s
try:
  r=json.load(s.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])
except Exception as e: print('  ❌ tx FAILED (see above)'); s.exit(1)"; }
sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys
import sys as s
try:
  r=json.load(s.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])
except Exception as e: print('  ❌ tx FAILED (see above)'); s.exit(1)"; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
depL()  { forge create "$1" --broadcast --rpc-url "$RPC_LASNA" --private-key "$PK" \
            ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
depS()  { forge create "$1" --broadcast --rpc-url "$RPC_SEP" --private-key "$PK" \
            ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
bal()   { cast from-wei "$(cast balance "$1" --rpc-url "$2" 2>/dev/null)"; }

echo "== [0] window guards and budgets"
BUYS=$(cast call "$BUY_OLD" 'buysCount()(uint256)' --rpc-url "$RPC_SEP" | awk '{print $1}')
[ "${BUYS:-0}" -ge 3 ] || { echo "❌ buysCount=$BUYS < 3 — the window has not opened yet. STOP"; exit 1; }
echo "  ✅ old buyer buysCount=$BUYS"
echo "  A@Sepolia=$(bal $A $RPC_SEP) ETH (need ≥0.045), A@Lasna=$(bal $A $RPC_LASNA) lREACT (need ≥0.6 for deploy gas)"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
CONV3=$(pre "$N"); echo "  precompute converter v3 (Lasna N=$N) = $CONV3"

echo "== [1] Sepolia: buyer v2 + faucet + till 0.04"
BUY3=$(depS "src/FuelConverter.sol:FuelBuyer" "$PROXY $CONV3 $FUND")
[ -n "$BUY3" ] || { echo "❌ buyer deploy failed"; exit 1; }
echo "  ✅ buyer of the v3 pair = $BUY3"
sendS "$BUY3" 'setFaucet(address)' "$FAUCET"
# till = a transfer to the buyer's receive() (it has NO deposit() — fix of 17.11)
sendS "$BUY3" --value 40000000000000000

echo "== [2] Lasna: converter v3 (nonces: not a single tx between precompute and deploy)"
CONV_REAL=$(depL "src/FuelConverter.sol:FuelConverter" "$FUND $BUY3 $T_HORIZON $T_FUNDED $FAUCET_RVM")
[ -n "$CONV_REAL" ] || { echo "❌ converter deploy failed"; exit 1; }
[ "$CONV_REAL" = "$CONV3" ] && echo "  ✅ precompute matched 1:1" || { echo "❌ nonce drift: $CONV_REAL ≠ $CONV3 — STOP"; exit 1; }

echo "== [3] arming: init (both subscriptions) + setTrigger(2, 86400)"
send "$CONV_REAL" 'init()'
send "$CONV_REAL" 'setTrigger(uint8,uint64)' "2 86400"

echo "== [4] retire the old pair: deactivate the converter (its cooldown until ~12:40 UTC 18.11)"
send "$CONV_OLD" 'deactivate()'

echo "== [5] depot: feeding moves (checklist #18)"
send "$FUND" 'removeWard(address)' "$CONV_OLD"
send "$FUND" 'addWard(address,uint256,uint256)' "$CONV_REAL 50000000000000000 100000000000000000"

echo "== [6] .env: old pair → *_V2_RETIRED, new ones in place"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
upsert W2_CONVERTER_V2_RETIRED "$CONV_OLD"
upsert W2_BUYER_V2_RETIRED "$BUY_OLD"
upsert W2_CONVERTER "$CONV_REAL"
upsert W2_BUYER "$BUY3"

echo "== [7] positive checks"
echo "  conv3.buyer = $(cast call "$CONV_REAL" 'buyer()(address)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.fund  = $(cast call "$CONV_REAL" 'fund()(address)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.active= $(cast call "$CONV_REAL" 'active()(bool)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.rateStopped = $(cast call "$CONV_REAL" 'rateStopped()(bool)' --rpc-url "$RPC_LASNA" | awk '{print $1}') (expect false)"
echo "  conv3.MIN_PAYOUT = $(cast call "$CONV_REAL" 'MIN_PAYOUT_PER_BUY()(uint256)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  conv3.triggerLevel/cooldown = $(cast call "$CONV_REAL" 'triggerLevel()(uint8)' --rpc-url "$RPC_LASNA" | awk '{print $1}') / $(cast call "$CONV_REAL" 'cooldown()(uint64)' --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  buyer3.faucet = $(cast call "$BUY3" 'faucet()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  buyer3.paused = $(cast call "$BUY3" 'paused()(bool)' --rpc-url "$RPC_SEP" | awk '{print $1}') (expect false)"
echo "  buyer3.till = $(bal $BUY3 $RPC_SEP) ETH"
echo "  old conv.active = $(cast call "$CONV_OLD" 'active()(bool)' --rpc-url "$RPC_LASNA" | awk '{print $1}') (expect false)"
echo "  depot wardCount = $(cast call "$FUND" 'wardCount()(uint256)' --rpc-url "$RPC_LASNA" | awk '{print $1}') (expect 3)"
echo "  A@Sepolia = $(bal $A $RPC_SEP) ETH"
echo "DONE. The next level ≥2 alarm will go to the new pair; the cron sensor will pick it up."
