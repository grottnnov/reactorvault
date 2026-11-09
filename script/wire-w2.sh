#!/usr/bin/env bash
# wire-w2.sh — bring the W2 stand to life: subscriptions, the depot's
# ward registry, tanks (depositTo on SYSTEM — NOT a plain transfer:
# only depositTo clears the debt, the 08.11 probe lesson), vault
# pockets. Run after deploy-w2.sh and the depot/watchdog deploy
# deploy-w2-fund.sh (addresses live in reactorvault/.env).
#
# Stand decisions (ADR-v2 + W2 calibration):
#   - the brain listens to the vault's Deposited (rare, live, cheap:
#     the "deposit → summon the executor" reaction; the Aave pool at
#     2620/8h would burn ~130 lREACT/day in reactive gas — deferred
#     to the G7 measurement);
#   - cries: the watchdog is subscribed to the brain and the cashier
#     (subscribeWardCry) — a zero-idle-cost safety circuit;
#   - registry: brain/cashier/converter (the watchdog is fed by the
#     first line of onFeedDog via dogFloor/ration — NOT a registry
#     ward);
#   - the depot's watcher policy is off (no watcher), the reserve
#     policy tightened: depot callback delivery is cheap (the probe
#     measured ~0.017/tick);
#   - depot burnRate = 0 until a live burn measurement (horizon and
#     the auto-faucet get enabled deliberately after calibration).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
OMNI=0x8888888888888888888888888888888888888888
set -a; source .env; set +a
PK=$LASNA_PARITY_A_PRIVATE_KEY

T_DEPOSITED=$(cast keccak 'Deposited(address,uint256,uint256,uint256)')

sendL() { cast send "$1" "${@:2}" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', r['status'])"; }
sendS() { cast send "$1" "${@:2}" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', r['status'])"; }

echo "== [1] Lasna subscriptions"
sendL "$W2_RULES" 'initialize(address,uint256,address,uint64)' "$W2_VAULT" "$T_DEPOSITED" "$W2_EXECUTOR" 3600
sendL "$W2_GASPAYER" 'init()'
sendL "$W2_CONVERTER" 'init()'
sendL "$W2_DOG" 'init()'
sendL "$W2_DOG" 'subscribeWardCry(address)' "$W2_RULES"
sendL "$W2_DOG" 'subscribeWardCry(address)' "$W2_GASPAYER"

echo "== [2] depot registry + policies"
sendL "$W2_FUND" 'setWatcherPolicy(uint256,uint256,uint256)' 0 0 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
sendL "$W2_FUND" 'setReservePolicy(uint256,uint256)' 0.05ether 0.3ether
sendL "$W2_FUND" 'setFeeding(uint256,uint256)' 0.1ether 0.1ether
sendL "$W2_FUND" 'addWard(address,uint256,uint256)' "$W2_RULES" 0.05ether 0.1ether
sendL "$W2_FUND" 'addWard(address,uint256,uint256)' "$W2_GASPAYER" 0.1ether 0.2ether
sendL "$W2_FUND" 'addWard(address,uint256,uint256)' "$W2_CONVERTER" 0.05ether 0.1ether

echo "== [3] Lasna tanks (depositTo on SYSTEM) + the depot's stock"
sysL() { cast send "$OMNI" 'depositTo(address)' "$2" --value "$3" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('  depositTo $1', r['status'])"; }
sysL "brain     $W2_RULES      0.1ether" "$W2_RULES" 0.1ether
sysL "cashier   $W2_GASPAYER   0.2ether" "$W2_GASPAYER" 0.2ether
sysL "watchdog  $W2_DOG        0.15ether" "$W2_DOG" 0.15ether
sysL "converter $W2_CONVERTER  0.1ether" "$W2_CONVERTER" 0.1ether
sysL "depot(rx) $W2_FUND       0.15ether" "$W2_FUND" 0.15ether
sendL "$W2_FUND" --value 0.6ether
echo "  transfer to depot 0.6 (feeding stock)"

echo "== [4] Sepolia: vault pockets (reserve 20%, treasury 5%, cap 0.05 ETH)"
sendS "$W2_VAULT" 'setParams(uint32,uint32,uint256)' 2000 500 0.05ether

echo "== [5] W2 stand status"
for X in "brain     $W2_RULES" "cashier   $W2_GASPAYER" "converter $W2_CONVERTER" "depot     $W2_FUND" "watchdog  $W2_DOG"; do
  set -- $X; B=$(cast balance "$2" --rpc-url "$RPC_LASNA" 2>/dev/null)
  D=$(cast call "$OMNI" 'debts(address)(uint256)' "$2" --rpc-url "$RPC_LASNA" 2>/dev/null | head -1)
  echo "  $1 $2 bal=$(cast from-wei $B) debt=$D"
done
echo "  vault     $W2_VAULT (Sepolia), executor $W2_EXECUTOR, buyer $W2_BUYER"
echo "  depot: ward records = $(cast call "$W2_FUND" 'wardCount()(uint256)' --rpc-url "$RPC_LASNA" 2>/dev/null)"
echo "next: a live auto-faucet probe + the end-to-end demo (see HANDOFF/evidence)"
