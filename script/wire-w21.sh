#!/usr/bin/env bash
# wire-w21.sh — wiring новой пятёрки БЕЗ повторных доливов живым
# (склад/сторож/конвертер/покупщик настроены 09.11 и не трогаются,
# кроме: новые подопечные в реестре, подписки на их крики, снятие
# старых подопечных). Environment: DEPLOYER_PRIVATE_KEY.
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY (from ~/.secrets)}

RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}

T_DEPOSITED=$(cast keccak 'Deposited(address,uint256,uint256)')

sendL() { cast send "$1" "${@:2}" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', r['status'])"; }
sendS() { cast send "$1" "${@:2}" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', r['status'])"; }

echo "== [1] Lasna: подписки новой семьи"
sendL "$W2_RULES" 'initialize(address,uint256,uint256,address,uint256,uint64)' "$W2_ASSETVAULT" 11155111 "$T_DEPOSITED" "$W2_EXECUTOR" 11155111 3600
sendL "$W2_GASPAYER" 'init()'
sendL "$W2_DOG" 'subscribeWardCry(address)' "$W2_RULES"
sendL "$W2_DOG" 'subscribeWardCry(address)' "$W2_GASPAYER"

echo "== [2] реестр склада: снять старых, добавить новых"
if [ -n "${W2_RULES_OLD:-}" ]; then sendL "$W2_FUND" 'removeWard(address)' "$W2_RULES_OLD"; fi
if [ -n "${W2_GASPAYER_OLD:-}" ]; then sendL "$W2_FUND" 'removeWard(address)' "$W2_GASPAYER_OLD"; fi
sendL "$W2_FUND" 'addWard(address,uint256,uint256)' "$W2_RULES" 0.05ether 0.1ether
sendL "$W2_FUND" 'addWard(address,uint256,uint256)' "$W2_GASPAYER" 0.1ether 0.2ether

echo "== [3] Lasna: баки НОВЫХ (depositTo на SYSTEM)"
OMNI=0x8888888888888888888888888888888888888888
sendL "$OMNI" 'depositTo(address)' "$W2_RULES" --value 0.1ether
sendL "$OMNI" 'depositTo(address)' "$W2_GASPAYER" --value 0.2ether

echo "== [4] Sepolia: сейф → батарея, исполнителям"
sendS "$W2_ASSETVAULT" 'setGasVault(address)' "$W2_GASVAULT"
sendS "$W2_ASSETVAULT" 'setTreasuryBps(uint32)' 500
sendS "$W2_ASSETVAULT" 'authorizeExecutor(address)' "$W2_EXECUTOR"
sendS "$W2_GASVAULT" 'authorizeExecutor(address)' "$W2_EXECUTOR"

echo "== [5] статус"
for X in "brain     $W2_RULES" "cashier   $W2_GASPAYER"; do
  set -- $X; B=$(cast balance "$2" --rpc-url "$RPC_LASNA" 2>/dev/null)
  R=$(cast call 0x8888888888888888888888888888888888888888 'reserves(address)(uint256)' "$2" --rpc-url "$RPC_LASNA" 2>/dev/null | head -1)
  echo "  $1 bal=$(cast from-wei $B) reserve=$R"
done
echo "  asset=$W2_ASSETVAULT battery=$W2_GASVAULT executor=$W2_EXECUTOR (Sepolia)"
echo "  depot wards=$(cast call $W2_FUND 'wardCount()(uint256)' --rpc-url $RPC_LASNA 2>/dev/null)"
echo "next: живой цикл — deposit 0.01 ETH в сейф + depositFuel 0.01 в батарею"
