#!/usr/bin/env bash
# deploy-w3.sh — W3: the pay-on-delivery family (ADR-GAS-ARCHITECTURE).
#
# What is new vs W2.2:
#   Sepolia: NEW GasVault — the FUND (no client pocket, no depositFuel;
#            earned/spent counters, buyer pulls its purchase funds);
#            NEW AssetVault (accrued fees, fee cap, settlement buffer,
#            NO treasuryBps — entry is free); NEW Executor v3 (no
#            cashier guard pair, no refuelEthTank; per-action billing +
#            margin sweep above the tank target); the executor tank is
#            SEEDED once at deploy (provisioning, not a hatch).
#   Lasna:   NEW brain (RulesEngine, unchanged code — the family
#            redeploy), NEW depot. NO CASHIER anywhere: the old one
#            stays conserved on-chain, silent by construction (no
#            events from the old family).
#   The old generation is NOT touched: its contracts keep running
#   untouched; money leaves via the old safe's exit when migrating.
#
# REHEARSAL FIRST: without RUN_LIVE=1 the script only READS (nonces,
# balances, precomputes) and echoes every state-changing command —
# the live run is a separate decision (premortem first, 27–28.11).
#
# The dependency circle: precompute Lasna N (brain), N+1 (depot) — the
# brain address goes into the Executor constructor (Sepolia, deployed
# EARLIER); the depot is self-sufficient (the watchdog is live).
# Tuple args: (a,b,c,d,e) without spaces — dep() does not tear them.
# Gas: NO cap (the OOG lesson). Positive checks after each step.
# Environment: DEPLOYER_PRIVATE_KEY (live only), .env (DOG/CONVERTER/
# BUYER addresses — live partners, not redeployed).
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
RUN_LIVE=${RUN_LIVE:-0}
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy
OMNI=0x8888888888888888888888888888888888888888

# Live partners (not redeployed)
DOG=${W2_DOG:?W2_DOG in .env}
CONV=${W2_CONVERTER:?W2_CONVERTER in .env}
BUYER=${W2_BUYER:?W2_BUYER in .env}

# W3 provisioning values (CALIBRATION 25–26.11: clean-window sensor;
# these are deploy-time provisioning, retuned via setters with events)
TANK_SEED=${W3_TANK_SEED:-0.05ether}

# Sepolia DeFi (INSTRUCTIONS 11.11, fork tests cross-checked live)
MORPHO=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
AAVE_POOL=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
IRM=0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c
WETH=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c
LLTV=915000000000000000

if [ "$RUN_LIVE" = "1" ]; then
  echo "== LIVE RUN =="
else
  echo "== REHEARSAL (RUN_LIVE unset): reads execute (real deployer address), sends are ECHOED =="
fi
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")

send()  { if [ "$RUN_LIVE" = 1 ]; then cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; \
          else echo "  [dry] cast send $* (lasna)" >&2; fi; }
sendS() { if [ "$RUN_LIVE" = 1 ]; then cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; \
          else echo "  [dry] cast send $* (sepolia)" >&2; fi; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
bal()   { cast from-wei "$(cast balance "$1" --rpc-url "$2" 2>/dev/null)"; }
dep()   { local spec="src/$2.sol:$2"; [[ "$2" == *:* ]] && spec="src/${2%%:*}.sol:${2##*:}"
  if [ "$RUN_LIVE" = 1 ]; then forge create "$spec" --broadcast --rpc-url "$1" --private-key "$PK" \
    ${3:+--constructor-args $3} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}';
  else echo "  [dry] forge create $spec ${3:+--constructor-args $3}" >&2; echo "0xdry"; fi; }
depW()  { if [ "$RUN_LIVE" = 1 ]; then forge create "src/$1" --broadcast --rpc-url "$RPC_LASNA" --private-key "$PK" \
    ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; \
          else echo "  [dry] forge create src/$1 ${2:+--constructor-args $2} (lasna)" >&2; echo "0xdry"; fi; }
mustBe() { if [ "$RUN_LIVE" = 1 ]; then
             [ "$1" = "$2" ] && echo "  ✅ $3 = $2 (precompute matched)" || { echo "❌ $3: '$1' ≠ '$2' — STOP"; exit 1; }
           else echo "  [dry] would verify $3 precompute = $2"; fi; }

echo "== [0] budgets: A@Lasna=$(bal $A $RPC_LASNA) lREACT (need >0.4), A@Sepolia=$(bal $A $RPC_SEP) ETH (need >0.03: deploys + tank seed)"
if [ "$RUN_LIVE" = 1 ]; then
  [ "$(python3 -c "print(1 if $(bal $A $RPC_LASNA) > 0.4 else 0)")" = "1" ] || { echo "NOT ENOUGH lREACT"; exit 1; }
  [ "$(python3 -c "print(1 if $(bal $A $RPC_SEP) > 0.03 else 0)")" = "1" ] || { echo "NOT ENOUGH ETH"; exit 1; }
fi

echo "== [1] precompute A@Lasna: brain N, depot N+1 (NO cashier in the family)"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
RULES23=$(pre "$N");      echo "  brain   N   = $RULES23"
FUND23=$(pre "$((N+1))"); echo "  depot   N+1 = $FUND23"

echo "== [2] Sepolia: oracle → Morpho market → adapters → safe → FUND → executor v3"
ORACLE=$(dep "$RPC_SEP" OneToOneOracle)
[ "$ORACLE" != "0xdry" ] && [ -n "$ORACLE" ] || { [ "$RUN_LIVE" = 1 ] && { echo "❌ oracle deploy failed"; exit 1; }; }
echo "  ✅ oracle = $ORACLE"

MP="($WETH,$WETH,$ORACLE,$IRM,$LLTV)"
echo "  createMarket $MP …"
sendS "$MORPHO" 'createMarket((address,address,address,address,uint256))' "$MP"

AAVE_AD=$(dep "$RPC_SEP" "adapters/AavePoolAdapter:AavePoolAdapter" "$AAVE_POOL $WETH")
echo "  ✅ aave adapter = $AAVE_AD"
MORPHO_AD=$(dep "$RPC_SEP" "adapters/MorphoPoolAdapter:MorphoPoolAdapter" "$MORPHO $MP $IRM")
echo "  ✅ morpho adapter = $MORPHO_AD"

ASSET23=$(dep "$RPC_SEP" AssetVault)
echo "  ✅ asset vault = $ASSET23"
FUNDVAULT23=$(dep "$RPC_SEP" GasVault)
echo "  ✅ fund (GasVault) = $FUNDVAULT23"
EXEC23=$(dep "$RPC_SEP" Executor "$RULES23 $PROXY $ASSET23 $FUNDVAULT23")   # 4 args: NO cashier sender
echo "  ✅ executor v3 = $EXEC23"

echo "== [2b] tank seed (one-time provisioning, ADR-GAS): $TANK_SEED → executor"
sendS "$EXEC23" --value "$TANK_SEED"

echo "== [3] Lasna: brain → depot (strictly in a row; nonce untouchable)"
mustBe "$(dep "$RPC_LASNA" RulesEngine)" "$RULES23" "brain"
mustBe "$(depW "ReliefFund.sol:ReliefFund" "$A $OMNI 0x0000000000000000000000000000000000000000 $OMNI $DOG $FUND23 $FUND23")" "$FUND23" "depot"

echo "== [4] positive checks (getters, not deploy strings)"
if [ "$RUN_LIVE" = 1 ]; then
  echo "  morpho market.lastUpdate (expect >0):"
  MID=$(cast call "$MORPHO_AD" 'marketId()(bytes32)' --rpc-url "$RPC_SEP")
  cast call "$MORPHO" 'market(bytes32)((uint128,uint128,uint128,uint128,uint128))' "$MID" --rpc-url "$RPC_SEP" | head -2
  echo "  executor fee tariff:"; cast call "$EXEC23" 'feePerActionWei()(uint256)' --rpc-url "$RPC_SEP"
  echo "  fund counters (expect zeros):"; cast call "$FUNDVAULT23" 'earned()(uint256)' --rpc-url "$RPC_SEP"
  echo "  brain owner:"; cast call "$RULES23" 'owner()(address)' --rpc-url "$RPC_LASNA"
  echo "  depot dogContract:"; cast call "$FUND23" 'dogContract()(address)' --rpc-url "$RPC_LASNA"
else
  echo "  [dry] getters skipped (contracts not deployed in rehearsal)"
fi

echo "== [5] .env: old → *_OLD, upsert W3_*"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
save_old() { local v; v=$(grep -oP "^$1=\K.*" .env 2>/dev/null); [ -n "$v" ] && upsert "$1_OLD" "$v"; return 0; }
for k in W2_RULES W2_FUND W2_ASSETVAULT W2_EXECUTOR W2_GASVAULT; do save_old "$k"; done
if [ "$RUN_LIVE" = 1 ]; then
  upsert W3_RULES "$RULES23"; upsert W3_FUND "$FUND23"
  upsert W3_ASSETVAULT "$ASSET23"; upsert W3_EXECUTOR "$EXEC23"; upsert W3_GASVAULT "$FUNDVAULT23"
  upsert W3_ORACLE "$ORACLE"; upsert W3_AAVE_ADAPTER "$AAVE_AD"; upsert W3_MORPHO_ADAPTER "$MORPHO_AD"
  echo "  done. next: script/wire-w3.sh"
else
  echo "  [dry] .env untouched in rehearsal"
fi

echo "== [6] remainder: A@Lasna $(bal $A $RPC_LASNA) lREACT / Sepolia $(bal $A $RPC_SEP) ETH"
