#!/usr/bin/env bash
# wire-w3.sh — wiring the W3 pay-on-delivery family + the money
# migration + tariff provisioning.
#
# Critical spots (vs wire-w22):
#   - NO cashier anywhere: no cashier init, no cashier ward, no cashier
#     cry subscription, no cashier tank. The old cashier stays
#     conserved on-chain, silent by construction.
#   - Tariffs ARE MONEY (ADR-GAS): fee cap, settlement buffer, fee
#     per action and tank target are set with events. CALIBRATION:
#     the 25–26.11 clean-window sensor run retunes them via setters —
#     the values below are deploy-time provisioning, not measurements.
#   - The settlement buffer is set AFTER the demo deposit (the setter
#     guards free >= buffer — an empty safe cannot promise a buffer).
#   - The old safe migration uses the OLD generation's exit
#     (withdrawAll exists there by design; the NEW family has none).
#   - The watchdog migration: pause → setReliefFund → resume (the gap
#     is seconds; a tick caught inside is lost — accepted, 11.11).
#
# REHEARSAL FIRST: without RUN_LIVE=1 every send is echoed, not sent.
# Environment: DEPLOYER_PRIVATE_KEY (live only), .env (W3_* from
# deploy-w3.sh, live partners DOG/CONVERTER/BUYER).
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
RUN_LIVE=${RUN_LIVE:-0}
OMNI=0x8888888888888888888888888888888888888888
CRON_EMITTER=0x0000000000000000000000000000000000fffFfF
CHAIN_LASNA=5318007

RULES=${W3_RULES:?W3_RULES}; FUND=${W3_FUND:?W3_FUND}
ASSET=${W3_ASSETVAULT:?W3_ASSETVAULT}; EXEC=${W3_EXECUTOR:?W3_EXECUTOR}
FUNDVAULT=${W3_GASVAULT:?W3_GASVAULT}
AAVE_AD=${W3_AAVE_ADAPTER:?}; MORPHO_AD=${W3_MORPHO_ADAPTER:?}
DOG=${W2_DOG:?}; CONV=${W2_CONVERTER:?}; BUYER=${W2_BUYER:?}
ASSET_OLD=${W2_ASSETVAULT_OLD:-${W2_ASSETVAULT:-}}

# Tariff provisioning — RETUNE after the 25–26.11 clean-window
# calibration (every change is announced on-chain by the setters):
FEE_CAP=${W3_FEE_CAP:-0.05ether}          # per-charge auto-refusal ceiling
BUFFER=${W3_BUFFER:-0.01ether}            # settlement cash kept free
FEE_PER_ACTION=${W3_FEE_PER_ACTION:-0.002ether}  # gas-unit based, measured
TANK_TARGET=${W3_TANK_TARGET:-0.02ether}  # above it — margin to the fund
BUY_CAP=${W3_BUY_CAP:-0.02ether}          # per-purchase pull ceiling
DEMO_DEPOSIT=${W3_DEMO_DEPOSIT:-0.008ether}

T_DEPOSITED=$(cast keccak 'Deposited(address,uint256,uint256)')
T_CRON10000=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56

if [ "$RUN_LIVE" = 1 ]; then PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}; fi
send()  { if [ "$RUN_LIVE" = 1 ]; then cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; \
          else echo "  [dry] cast send $* (lasna)"; fi; }
sendS() { if [ "$RUN_LIVE" = 1 ]; then cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; \
          else echo "  [dry] cast send $* (sepolia)"; fi; }

echo "== [1] Sepolia: safe + fund + executor configuration (NO treasuryBps — entry is free)"
sendS "$ASSET" 'setGasVault(address)' "$FUNDVAULT"
sendS "$ASSET" 'authorizeExecutor(address)' "$EXEC"
sendS "$ASSET" 'authorizePoolAdapter(address)' "$AAVE_AD"
sendS "$ASSET" 'authorizePoolAdapter(address)' "$MORPHO_AD"
sendS "$ASSET" 'setFeeCap(uint256)' "$FEE_CAP"
sendS "$FUNDVAULT" 'authorizeExecutor(address)' "$EXEC"
sendS "$FUNDVAULT" 'authorizeBuyer(address,uint256)' "$BUYER" "$BUY_CAP"
sendS "$EXEC" 'setFeeTariff(uint256,uint256)' "$FEE_PER_ACTION" "$TANK_TARGET"

echo "== [2] Sepolia: old safe migration → demo deposit → buffer (free >= buffer by then)"
if [ -n "$ASSET_OLD" ] && [ "$ASSET_OLD" != "$ASSET" ]; then
  echo "  -- old generation exit (its withdrawAll, by design; the new family has none)"
  sendS "$ASSET_OLD" 'withdrawAll()'
fi
sendS "$ASSET" 'deposit()' --value "$DEMO_DEPOSIT"
sendS "$ASSET" 'setBufferWei(uint256)' "$BUFFER"

echo "== [3] Lasna: brain — the deposit rule + the alarm-clock rule (DAILY)"
send "$RULES" 'initialize(address,uint256,uint256,address,uint256,uint64)' "$ASSET" 11155111 "$T_DEPOSITED" "$EXEC" 11155111 3600
send "$RULES" 'setRule(uint256,uint256,bool,uint64)' "$CHAIN_LASNA" "$T_CRON10000" true 86400
send "$RULES" 'subscribe(uint256,address,uint256)' "$CHAIN_LASNA" "$CRON_EMITTER" "$T_CRON10000"

echo "== [4] Lasna: depot wards — brain + dog (NO cashier ward)"
send "$FUND" 'addWard(address,uint256,uint256)' "$RULES" 0.05ether 0.1ether
send "$FUND" 'addWard(address,uint256,uint256)' "$DOG" 0.15ether 0.08ether
send "$FUND" 'setBurnRate(uint256)' 0.35ether
echo "  -- the depot seed 0.25 lREACT"
send "$FUND" --value 0.25ether

echo "== [5] Lasna: the watchdog's migration to the new depot (pause→set→resume)"
send "$DOG" 'pause()'
send "$DOG" 'setReliefFund(address)' "$FUND"
send "$DOG" 'resume()'
send "$DOG" 'subscribeWardCry(address)' "$RULES"

echo "== [6] converter (Lasna) / buyer (Sepolia) → the new depot"
send "$CONV" 'setFund(address)' "$FUND"
send "$CONV" 'setTrigger(uint8,uint64)' 2 86400
sendS "$BUYER" 'setFund(address)' "$FUND"

echo "== [7] Lasna tank: the brain only (NO cashier tank)"
send "$OMNI" 'depositTo(address)' "$RULES" --value 0.05ether

echo "== [8] positive checks (getters)"
if [ "$RUN_LIVE" = 1 ]; then
  echo "  vault fee params: cap=$(cast call "$ASSET" 'feeCapWei()(uint256)' --rpc-url "$RPC_SEP") buffer=$(cast call "$ASSET" 'bufferWei()(uint256)' --rpc-url "$RPC_SEP")"
  echo "  executor tariff: fee=$(cast call "$EXEC" 'feePerActionWei()(uint256)' --rpc-url "$RPC_SEP") target=$(cast call "$EXEC" 'tankTargetWei()(uint256)' --rpc-url "$RPC_SEP")"
  echo "  fund buyer: $(cast call "$FUNDVAULT" 'buyer()(address)' --rpc-url "$RPC_SEP") cap=$(cast call "$FUNDVAULT" 'buyCapWei()(uint256)' --rpc-url "$RPC_SEP")"
  echo "  accruedFees (expect 0): $(cast call "$ASSET" 'accruedFees()(uint256)' --rpc-url "$RPC_SEP")"
  echo "  depot wardCount: $(cast call "$FUND" 'wardCount()(uint256)' --rpc-url "$RPC_LASNA")"
  echo "  dog reliefFund [expect the new depot]: $(cast call "$DOG" 'reliefFund()(address)' --rpc-url "$RPC_LASNA")"
  echo "  converter fund: $(cast call "$CONV" 'fund()(address)' --rpc-url "$RPC_LASNA")"
  echo "  buyer fund: $(cast call "$BUYER" 'fund()(address)' --rpc-url "$RPC_SEP")"
  echo "  brain tank: $(cast call "$OMNI" 'reserves(address)(uint256)' "$RULES" --rpc-url "$RPC_LASNA" | awk '{print $1}')"
  echo "  demo deposit: $(cast call "$ASSET" 'totalDeposited()(uint256)' --rpc-url "$RPC_SEP")"
else
  echo "  [dry] getters skipped (nothing wired in rehearsal)"
fi

echo "== [9] live loop proof: watch a rebalance land (react → callback → billing)"
echo "  cast call $EXEC 'rebalanceCount()' before/after the next cron tick;"
echo "  accrued fees on the safe must grow by feePerActionWei per served tick."
echo "next: tariffs retune (25–26.11 calibration) → evidence/w3-deploy.md"
