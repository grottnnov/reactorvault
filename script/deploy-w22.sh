#!/usr/bin/env bash
# deploy-w22.sh — W2.2: the Rebalance pools (ADR-v2 + ADR-EXPANSION) +
# the fix family.
#
# What is new vs W2.1:
#   Sepolia: OneToOneOracle → OWN Morpho market WETH/WETH (1:1, LLTV 91.5%)
#            → AavePoolAdapter + MorphoPoolAdapter → AssetVault (NEW,
#            the battery is the OLD live one) → Executor (pools go via
#            setPools at wiring).
#   Lasna:   RulesEngine (NEW: the owner-subscribe() hatch — the old brain
#            could not add subscriptions, see RulesEngine@ef44f46), GasPayer
#            v2.1 (setExecutor moves the cry subscription along), Fund v6.x
#            (re-emits HorizonAlert while the level holds — the 11.11
#            auto-faucet deadlock).
#   Watchdog/converter/buyer are LIVE, re-linked via setters
#            (wire-w22.sh: pause→setReliefFund→resume, setFund×2).
#
# The dependency circle: precompute Lasna N (brain), N+1 (cashier), N+2
# (depot) — the brain and the cashier go into the Executor constructor
# (Sepolia, deployed EARLIER than them); the depot is self-sufficient
# (the watchdog is live).
# Tuple args: (a,b,c,d,e) without spaces — dep() does not tear them
# (verified with cast calldata).
#
# Gas: NO cap (the OOG lesson). Positive checks after each step.
# Environment: DEPLOYER_PRIVATE_KEY, .env (DOG/GASVAULT addresses — live).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy
OMNI=0x8888888888888888888888888888888888888888

# Live partners (not redeployed)
DOG=${W2_DOG:?W2_DOG in .env}
GASVAULT=${W2_GASVAULT:?W2_GASVAULT in .env}

# Sepolia DeFi (INSTRUCTIONS 11.11, fork tests cross-checked live)
MORPHO=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
AAVE_POOL=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
IRM=0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c
WETH=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c
LLTV=915000000000000000

T_ETH_LOW=$(cast keccak 'ExecutorLowEth(uint256,uint256)')
T_RESERVE=$(cast keccak 'GasReserveUpdated(uint256)')

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
bal()   { cast from-wei "$(cast balance "$1" --rpc-url "$2" 2>/dev/null)"; }
dep()   { local spec="src/$2.sol:$2"; [[ "$2" == *:* ]] && spec="src/${2%%:*}.sol:${2##*:}"
  forge create "$spec" --broadcast --rpc-url "$1" --private-key "$PK" \
    ${3:+--constructor-args $3} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
depW()  { forge create "src/$1" --broadcast --rpc-url "$RPC_LASNA" --private-key "$PK" \
    ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
mustBe() { [ "$1" = "$2" ] && echo "  ✅ $3 = $2 (precompute matched)" || { echo "❌ $3: '$1' ≠ '$2' — STOP"; exit 1; }; }

echo "== [0] budgets: A@Lasna=$(bal $A $RPC_LASNA) lREACT (need >0.45), A@Sepolia=$(bal $A $RPC_SEP) ETH (need >0.022)"
[ "$(python3 -c "print(1 if $(bal $A $RPC_LASNA) > 0.45 else 0)")" = "1" ] || { echo "NOT ENOUGH lREACT"; exit 1; }
[ "$(python3 -c "print(1 if $(bal $A $RPC_SEP) > 0.022 else 0)")" = "1" ] || { echo "NOT ENOUGH ETH"; exit 1; }

echo "== [1] precompute A@Lasna: brain N, cashier N+1, depot N+2"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
RULES22=$(pre "$N");      echo "  brain   N   = $RULES22"
GAS22=$(pre "$((N+1))");  echo "  cashier N+1 = $GAS22"
FUND22=$(pre "$((N+2))"); echo "  depot   N+2 = $FUND22"

echo "== [2] Sepolia: oracle → Morpho market → adapters → safe → executor"
ORACLE=$(dep "$RPC_SEP" OneToOneOracle)
[ -n "$ORACLE" ] || { echo "❌ oracle deploy failed"; exit 1; }
echo "  ✅ oracle = $ORACLE"

MP="($WETH,$WETH,$ORACLE,$IRM,$LLTV)"
echo "  createMarket $MP …"
sendS "$MORPHO" 'createMarket((address,address,address,address,uint256))' "$MP"

AAVE_AD=$(dep "$RPC_SEP" "adapters/AavePoolAdapter:AavePoolAdapter" "$AAVE_POOL $WETH")
[ -n "$AAVE_AD" ] || { echo "❌ aave adapter failed"; exit 1; }
echo "  ✅ aave adapter = $AAVE_AD"
MORPHO_AD=$(dep "$RPC_SEP" "adapters/MorphoPoolAdapter:MorphoPoolAdapter" "$MORPHO $MP $IRM")
[ -n "$MORPHO_AD" ] || { echo "❌ morpho adapter failed"; exit 1; }
echo "  ✅ morpho adapter = $MORPHO_AD"

ASSET22=$(dep "$RPC_SEP" AssetVault)
[ -n "$ASSET22" ] || { echo "❌ asset vault deploy failed"; exit 1; }
echo "  ✅ asset vault = $ASSET22"
EXEC22=$(dep "$RPC_SEP" Executor "$RULES22 $PROXY $ASSET22 $GASVAULT $GAS22")
[ -n "$EXEC22" ] || { echo "❌ executor deploy failed"; exit 1; }
echo "  ✅ executor = $EXEC22"

echo "== [3] Lasna: brain → cashier → depot (strictly in a row; nonce untouchable)"
mustBe "$(dep "$RPC_LASNA" RulesEngine)" "$RULES22" "brain"
mustBe "$(dep "$RPC_LASNA" GasPayer "$EXEC22 $GASVAULT $T_ETH_LOW $T_RESERVE")" "$GAS22" "cashier"
mustBe "$(depW "ReliefFund.sol:ReliefFund" "$A $OMNI 0x0000000000000000000000000000000000000000 $OMNI $DOG $FUND22 $FUND22")" "$FUND22" "depot (latch-fixed)"

echo "== [4] positive checks (getters, not deploy strings)"
echo "  morpho market.lastUpdate (expect >0):"
MID=$(cast call "$MORPHO_AD" 'marketId()(bytes32)' --rpc-url "$RPC_SEP")
cast call "$MORPHO" 'market(bytes32)((uint128,uint128,uint128,uint128,uint128))' "$MID" --rpc-url "$RPC_SEP" | head -2
echo "  executor pools (before setPools — zeros):"; cast call "$EXEC22" 'poolA()(address)' --rpc-url "$RPC_SEP"
echo "  brain owner:"; cast call "$RULES22" 'owner()(address)' --rpc-url "$RPC_LASNA"
echo "  depot dogContract:"; cast call "$FUND22" 'dogContract()(address)' --rpc-url "$RPC_LASNA"

echo "== [5] .env: old → *_OLD, upsert new"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
save_old() { local v; v=$(grep -oP "^$1=\K.*" .env 2>/dev/null); [ -n "$v" ] && upsert "$1_OLD" "$v"; return 0; }
for k in W2_RULES W2_GASPAYER W2_FUND W2_ASSETVAULT W2_EXECUTOR; do save_old "$k"; done
upsert W2_RULES "$RULES22"; upsert W2_GASPAYER "$GAS22"; upsert W2_FUND "$FUND22"
upsert W2_ASSETVAULT "$ASSET22"; upsert W2_EXECUTOR "$EXEC22"
upsert W2_ORACLE "$ORACLE"; upsert W2_AAVE_ADAPTER "$AAVE_AD"; upsert W2_MORPHO_ADAPTER "$MORPHO_AD"
upsert W2_MARKET_ID "0x${MID#0x}"
echo "  done. next: script/wire-w22.sh"

echo "== [6] remainder: A@Lasna $(bal $A $RPC_LASNA) lREACT / Sepolia $(bal $A $RPC_SEP) ETH"
