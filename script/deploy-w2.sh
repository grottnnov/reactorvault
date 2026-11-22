#!/usr/bin/env bash
# deploy-w2.sh — deploy the ReactorVault v2 family (ADR-v2).
#
# What it does: precompute the circular dependencies → the Sepolia trio
# (vault, executor, fuel buyer) → the Lasna trio (brain, cashier,
# converter). The depot (ReliefFund v6) and the watchdog (Watchdog v6) are
# deployed RIGHT AFTER this by script/deploy-w21-fund.sh
# — their future addresses are already baked in here by precompute
# (nonces N+3, N+4); wiring is wire-w2.sh.
#
# Circular dependencies (all broken by A@Lasna nonce precompute):
#   Executor(Sepolia) ← [brain N, cashier N+1] (valid callback senders)
#   FuelBuyer(Sepolia) ← [converter N+2, depot N+3] (immutable guards)
#   cashier(Lasna) ← executor/vault (real by its turn)
#   converter(Lasna) ← buyer (real by its turn)
#
# Live verifications: Sepolia proxy 0xAa14…3b4 (08.11 probe,
# sender-slot injection); faucet request(address) payable (simulated
# 09.11). Deployment gas: NO cap (the OOG lesson: a capped create
# burns the nonce and buries the precompute).
#
# Environment: DEPLOYER_PRIVATE_KEY (an EOA funded on both chains; the
# secrets canon — the key lives in your secret store, env is transport).
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")

PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy
FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434  # Lasna faucet (testnet)

# topic0 (keccak-verified on the spot)
T_ETH_LOW=$(cast keccak 'ExecutorLowEth(uint256,uint256)')
T_RESERVE=$(cast keccak 'GasReserveUpdated(uint256)')
T_HORIZON=$(cast keccak 'HorizonAlert(uint256,uint256,uint256,uint8)')
echo "topics: ethLow=$T_ETH_LOW reserve=$T_RESERVE horizon=$T_HORIZON"

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
bal()   { cast from-wei "$(cast balance "$1" --rpc-url "$2" 2>/dev/null)"; }
dep()   { # dep <rpc> <file:Contract|Contract> [args…] → address
  local spec="src/$2.sol:$2"; [[ "$2" == *:* ]] && spec="src/${2%%:*}.sol:${2##*:}"
  forge create "$spec" --broadcast --rpc-url "$1" --private-key "$PK" \
    ${3:+--constructor-args $3} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'
}
mustBe() { # $1=actual address $2=expected $3=name — a mismatch buries the wiring
  if [ -z "$1" ] || [ ! "$1" = "$2" ]; then
    echo "❌ $3: deployed '$1', expected $2 — STOP, wiring mismatch"; exit 1
  fi
  echo "  ✅ $3 = $2 (precompute matched)"
}

echo "== [0] budgets: A@Lasna=$(bal $A $RPC_LASNA) lREACT, A@Sepolia=$(bal $A $RPC_SEP) ETH"
[ "$(bal $A $RPC_LASNA | cut -d. -f1)" -ge 2 ] 2>/dev/null || { echo "NOT ENOUGH lREACT at A (need ≥2.2)"; exit 1; }
[ "$(python3 -c "print(1 if $(bal $A $RPC_SEP) > 0.045 else 0)")" = "1" ] || { echo "NOT ENOUGH ETH at A (need ≥0.045)"; exit 1; }

echo "== [1] precompute the A@Lasna chain (do NOT touch nonces until phase 3 ends!)"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
RULES=$(pre "$N");        echo "  brain     N    = $RULES"
GAS=$(pre "$((N+1))");    echo "  cashier   N+1  = $GAS"
CONV=$(pre "$((N+2))");   echo "  converter N+2  = $CONV"
FUND=$(pre "$((N+3))");   echo "  depot     N+3  = $FUND  (deploy-w2-fund.sh)"
DOG=$(pre "$((N+4))");    echo "  watchdog  N+4  = $DOG   (deploy-w2-fund.sh)"

echo "== [2] Sepolia: asset vault → gas vault (battery) → executor → fuel buyer"
ASSET=$(dep "$RPC_SEP" AssetVault)
[ -n "$ASSET" ] || { echo "❌ asset vault deploy failed"; exit 1; }
echo "  ✅ asset vault = $ASSET"
GASV=$(dep "$RPC_SEP" GasVault)
[ -n "$GASV" ] || { echo "❌ gas vault deploy failed"; exit 1; }
echo "  ✅ gas vault = $GASV"
EXEC=$(dep "$RPC_SEP" Executor "$RULES $PROXY $ASSET $GASV $GAS")
[ -n "$EXEC" ] || { echo "❌ executor deploy failed"; exit 1; }
echo "  ✅ executor = $EXEC"
BUYER=$(dep "$RPC_SEP" FuelConverter:FuelBuyer "$PROXY $CONV $FUND")
[ -n "$BUYER" ] || { echo "❌ buyer deploy failed"; exit 1; }
echo "  ✅ buyer = $BUYER"
cast send "$BUYER" 'setFaucet(address)' "$FAUCET" --rpc-url "$RPC_SEP" --private-key "$PK" 2>&1 | grep -m1 status
cast send "$BUYER" --value 0.02ether --rpc-url "$RPC_SEP" --private-key "$PK" 2>&1 | grep -m1 status

echo "== [3] Lasna: brain → cashier → converter (strictly in a row, A's nonce untouchable)"
mustBe "$(dep "$RPC_LASNA" RulesEngine)" "$RULES" "brain"
# ADR-EXPANSION §2: the reserve emitter is the battery (GasVault), not the asset vault
mustBe "$(dep "$RPC_LASNA" GasPayer "$EXEC $GASV $T_ETH_LOW $T_RESERVE")" "$GAS" "cashier"
mustBe "$(dep "$RPC_LASNA" FuelConverter:FuelConverter "$FUND $BUYER $T_HORIZON")" "$CONV" "converter"

echo "== [4] into .env (W2_*), next step: script/deploy-w21-fund.sh (expects nonce $((N+3)))"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
upsert W2_RULES "$RULES"; upsert W2_GASPAYER "$GAS"; upsert W2_CONVERTER "$CONV"
upsert W2_FUND "$FUND";   upsert W2_DOG "$DOG"
upsert W2_ASSETVAULT "$ASSET"; upsert W2_GASVAULT "$GASV"; upsert W2_EXECUTOR "$EXEC"; upsert W2_BUYER "$BUYER"
upsert W2_EXPECTED_NONCE "$((N+3))"
echo "  A remainder: Lasna $(bal $A $RPC_LASNA) lREACT / Sepolia $(bal $A $RPC_SEP) ETH"
