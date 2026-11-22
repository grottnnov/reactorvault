#!/usr/bin/env bash
# deploy-w21.sh — redeploy the five after the split (ADR-EXPANSION).
#
# What it does: Lasna [brain, cashier] + Sepolia [AssetVault, GasVault,
# Executor]. Depot/watchdog/converter/buyer are LIVE since 09.11, not
# touched. Old addresses are saved in .env as *_OLD before the upsert.
# The dependency circle: precompute Lasna N (brain), N+1 (cashier) —
# their future addresses go into the Executor constructor (Sepolia);
# the cashier gets the executor's REAL address (deployed before it on
# Sepolia).
#
# Gas: NO cap (the 2.5M OOG lesson). Environment: DEPLOYER_PRIVATE_KEY.
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy

T_ETH_LOW=$(cast keccak 'ExecutorLowEth(uint256,uint256)')
T_RESERVE=$(cast keccak 'GasReserveUpdated(uint256)')

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
bal()   { cast from-wei "$(cast balance "$1" --rpc-url "$2" 2>/dev/null)"; }
dep()   { local spec="src/$2.sol:$2"; [[ "$2" == *:* ]] && spec="src/${2%%:*}.sol:${2##*:}"
  forge create "$spec" --broadcast --rpc-url "$1" --private-key "$PK" \
    ${3:+--constructor-args $3} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
mustBe() { [ "$1" = "$2" ] && echo "  ✅ $3 = $2 (precompute matched)" || { echo "❌ $3: '$1' ≠ '$2' — STOP"; exit 1; }; }

echo "== [0] budgets: A@Lasna=$(bal $A $RPC_LASNA) lREACT, A@Sepolia=$(bal $A $RPC_SEP) ETH"
[ "$(python3 -c "print(1 if $(bal $A $RPC_LASNA) > 0.4 else 0)")" = "1" ] || { echo "NOT ENOUGH lREACT (need >0.4: 2 deploys + tanks)"; exit 1; }
[ "$(python3 -c "print(1 if $(bal $A $RPC_SEP) > 0.045 else 0)")" = "1" ] || { echo "NOT ENOUGH ETH (need >0.045)"; exit 1; }

echo "== [1] precompute A@Lasna (nonce chain: brain N, cashier N+1)"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
RULES21=$(pre "$N");      echo "  brain   N   = $RULES21"
GAS21=$(pre "$((N+1))");  echo "  cashier N+1 = $GAS21"

echo "== [2] Sepolia: asset vault → battery → executor"
ASSET21=$(dep "$RPC_SEP" AssetVault)
[ -n "$ASSET21" ] || { echo "❌ asset vault deploy failed"; exit 1; }
echo "  ✅ asset vault = $ASSET21"
GASV21=$(dep "$RPC_SEP" GasVault)
[ -n "$GASV21" ] || { echo "❌ gas vault deploy failed"; exit 1; }
echo "  ✅ battery = $GASV21"
EXEC21=$(dep "$RPC_SEP" Executor "$RULES21 $PROXY $ASSET21 $GASV21 $GAS21")
[ -n "$EXEC21" ] || { echo "❌ executor deploy failed"; exit 1; }
echo "  ✅ executor = $EXEC21"

echo "== [3] Lasna: brain → cashier (strictly in a row, A@Lasna nonce untouchable)"
mustBe "$(dep "$RPC_LASNA" RulesEngine)" "$RULES21" "brain"
mustBe "$(dep "$RPC_LASNA" GasPayer "$EXEC21 $GASV21 $T_ETH_LOW $T_RESERVE")" "$GAS21" "cashier"

echo "== [4] .env: save the old as *_OLD, upsert the new"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
save_old() { local v; v=$(grep -oP "^$1=\K.*" .env 2>/dev/null); [ -n "$v" ] && upsert "$1_OLD" "$v"; return 0; }
save_old W2_RULES; save_old W2_GASPAYER; save_old W2_EXECUTOR
upsert W2_RULES "$RULES21"; upsert W2_GASPAYER "$GAS21"; upsert W2_EXECUTOR "$EXEC21"
upsert W2_ASSETVAULT "$ASSET21"; upsert W2_GASVAULT "$GASV21"
echo "  done. next: script/wire-w21.sh"

echo "== [5] remainder: A@Lasna $(bal $A $RPC_LASNA) lREACT / Sepolia $(bal $A $RPC_SEP) ETH"
