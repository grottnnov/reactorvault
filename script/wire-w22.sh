#!/usr/bin/env bash
# wire-w22.sh — wiring the W2.2 family + the money migration + fix
# verification.
#
# Critical spots:
#   - the watchdog's migration to the new depot: pause → setReliefFund
#     → resume (the pause/resume gap is seconds; a tick caught inside
#     is lost — accepted);
#   - THE WATCHDOG INTO THE FEEDING REGISTRY (floor 0.15 / ration
#     0.08, the 11.11 tick measurement ~0.05 lREACT/tick with a stack
#     of echo events) — the W2.1 sag fix (ward (0,0) silently watched
#     the tank starve);
#   - the alarm-clock rule: the brain subscribes to the cron emitter
#     0x…fffFfF (the old brain could not — hence the redeploy), the
#     cooldown is DAILY: the 11.11 measurement — one rebalance shot ≈
#     0.018 lREACT, 8/day would burn 0.144/day; a day = 0.02/day
#     (cross-check with the economics);
#   - the converter/buyer re-link to the new depot via setters (the
#     converter's setFund moves the HorizonAlert subscription itself).
#
# Environment: DEPLOYER_PRIVATE_KEY, .env (new addresses from deploy-w22.sh).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
OMNI=0x8888888888888888888888888888888888888888
CRON_EMITTER=0x0000000000000000000000000000000000fffFfF
CHAIN_LASNA=5318007

RULES=${W2_RULES:?}; GAS=${W2_GASPAYER:?}; FUND=${W2_FUND:?}
ASSET=${W2_ASSETVAULT:?}; EXEC=${W2_EXECUTOR:?}
AAVE_AD=${W2_AAVE_ADAPTER:?}; MORPHO_AD=${W2_MORPHO_ADAPTER:?}
GASVAULT=${W2_GASVAULT:?}; DOG=${W2_DOG:?}; CONV=${W2_CONVERTER:?}; BUYER=${W2_BUYER:?}
ASSET_OLD=${W2_ASSETVAULT_OLD:-}

T_DEPOSITED=$(cast keccak 'Deposited(address,uint256,uint256)')
T_CRON10000=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56
DEMO_DEPOSIT=${W22_DEMO_DEPOSIT:-0.008ether}

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }

echo "== [1] Sepolia: safe (the battery is the old live one) → executor → pools"
sendS "$ASSET" 'setGasVault(address)' "$GASVAULT"
sendS "$ASSET" 'setTreasuryBps(uint32)' 500
sendS "$ASSET" 'authorizeExecutor(address)' "$EXEC"
sendS "$ASSET" 'authorizePoolAdapter(address)' "$AAVE_AD"
sendS "$ASSET" 'authorizePoolAdapter(address)' "$MORPHO_AD"
sendS "$GASVAULT" 'authorizeExecutor(address)' "$EXEC"
sendS "$EXEC" 'setPools(address,address)' "$AAVE_AD" "$MORPHO_AD"

echo "== [2] Sepolia: old safe migration + the demo deposit"
if [ -n "$ASSET_OLD" ]; then sendS "$ASSET_OLD" 'withdrawAll()'; fi
sendS "$ASSET" 'deposit()' --value "$DEMO_DEPOSIT"

echo "== [3] Lasna: brain — the deposit rule + the alarm-clock rule (DAILY)"
send "$RULES" 'initialize(address,uint256,uint256,address,uint256,uint64)' "$ASSET" 11155111 "$T_DEPOSITED" "$EXEC" 11155111 3600
send "$RULES" 'setRule(uint256,uint256,bool,uint64)' "$CHAIN_LASNA" "$T_CRON10000" true 86400
send "$RULES" 'subscribe(uint256,address,uint256)' "$CHAIN_LASNA" "$CRON_EMITTER" "$T_CRON10000"

echo "== [4] Lasna: cashier init (the executor's cry) + depot"
send "$GAS" 'init()'
send "$FUND" 'addWard(address,uint256,uint256)' "$RULES" 0.05ether 0.1ether
send "$FUND" 'addWard(address,uint256,uint256)' "$GAS" 0.1ether 0.2ether
echo "  -- the 11.11 fix: the watchdog into the feeding registry (was (0,0) — silent to death)"
send "$FUND" 'addWard(address,uint256,uint256)' "$DOG" 0.15ether 0.08ether
send "$FUND" 'setBurnRate(uint256)' 0.35ether
echo "  -- the depot seed 0.25 lREACT"
send "$FUND" --value 0.25ether

echo "== [5] Lasna: the watchdog's migration to the new depot (pause→set→resume)"
send "$DOG" 'pause()'
send "$DOG" 'setReliefFund(address)' "$FUND"
send "$DOG" 'resume()'
send "$DOG" 'subscribeWardCry(address)' "$RULES"
send "$DOG" 'subscribeWardCry(address)' "$GAS"

echo "== [6] converter (Lasna) / buyer (Sepolia) → the new depot"
send "$CONV" 'setFund(address)' "$FUND"
send "$CONV" 'setTrigger(uint8,uint64)' 2 86400
sendS "$BUYER" 'setFund(address)' "$FUND"

echo "== [7] Lasna: tanks (brain 0.05, cashier 0.1)"
send "$OMNI" 'depositTo(address)' "$RULES" --value 0.05ether
send "$OMNI" 'depositTo(address)' "$GAS" --value 0.1ether

echo "== [8] positive checks (getters)"
echo "  executor pools: A=$(cast call "$EXEC" 'poolA()(address)' --rpc-url "$RPC_SEP") B=$(cast call "$EXEC" 'poolB()(address)' --rpc-url "$RPC_SEP")"
echo "  vault battery: $(cast call "$ASSET" 'gasVault()(address)' --rpc-url "$RPC_SEP")"
echo "  depot wardCount: $(cast call "$FUND" 'wardCount()(uint256)' --rpc-url "$RPC_LASNA")"
echo "  depot wards(dog) [expect 0.1e18/0.03e18/0]: $(cast call "$FUND" 'wards(address)' "$DOG" --rpc-url "$RPC_LASNA" | tr '\n' ' ')"
echo "  depot burnRate: $(cast call "$FUND" 'burnRatePerDay()(uint256)' --rpc-url "$RPC_LASNA")"
echo "  dog reliefFund [expect the new depot]: $(cast call "$DOG" 'reliefFund()(address)' --rpc-url "$RPC_LASNA")"
echo "  converter fund: $(cast call "$CONV" 'fund()(address)' --rpc-url "$RPC_LASNA")"
echo "  buyer fund: $(cast call "$BUYER" 'fund()(address)' --rpc-url "$RPC_SEP")"
echo "  tanks: rules=$(cast call "$OMNI" 'reserves(address)(uint256)' "$RULES" --rpc-url "$RPC_LASNA" | awk '{print $1}') cashier=$(cast call "$OMNI" 'reserves(address)(uint256)' "$GAS" --rpc-url "$RPC_LASNA" | awk '{print $1}')"
echo "  depot bal: $(cast from-wei "$(cast balance "$FUND" --rpc-url "$RPC_LASNA")")"
echo "  vault demo deposit: $(cast call "$ASSET" 'totalDeposited()(uint256)' --rpc-url "$RPC_SEP")"

echo "== [9] remainder: A@Lasna $(cast from-wei "$(cast balance "$A" --rpc-url "$RPC_LASNA")") / A@Sepolia $(cast from-wei "$(cast balance "$A" --rpc-url "$RPC_SEP")")"
echo "next: script/lever-w22.sh (operator leverage, with ETH ≥ ~0.025), then a live tick — evidence/w22-*.md"
