#!/usr/bin/env bash
# deploy-w21-fund.sh — передеплой надзорной обвязки (ADR-EXPANSION):
# склад(Fund v6, конструктор 7 аргументов) → сторож(v6, ПРАВИЛЬНЫЙ ПУТЬ
# src/Watchdog.sol — баг 09.11: деплойнулся корневой legacy-сторож
# с гвардом "VM only", ревертящий все омни-доставки) → конвертер →
# покупщик. У всех — партнёрские люки (сеттеры).
#
# Позитив-сверки после каждого деплоя (сеньор-урок: негатив-строки врут,
# геттеры доказывают): cron-топик сторожа, адрес склада, связки.
#
# Газ: БЕЗ капа (урок OOG). Environment: DEPLOYER_PRIVATE_KEY,
# .env (адреса семьи W2_RULES/W2_GASPAYER).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC_LASNA=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
OMNI=0x8888888888888888888888888888888888888888
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Sepolia callback proxy
FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434  # Lasna faucet (testnet)

T_CRON10000=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56
T_BLACKLIST=$(cast keccak 'Blacklisted(address)')
T_MAILBOX_ALERT=$(cast keccak 'AlertReceived(uint8,uint16,address,uint256,address,uint256)')
T_DOG_FED=$(cast keccak 'DogFed(address,uint256,uint256)')
T_WATCHER_LOW=$(cast keccak 'WatcherLowReserve(address,uint256,uint256)')
T_LOW_FUND=$(cast keccak 'LowFund(uint256,uint256)')
T_HORIZON=$(cast keccak 'HorizonAlert(uint256,uint256,uint256,uint8)')
T_ETH_LOW=$(cast keccak 'ExecutorLowEth(uint256,uint256)')
WATCHER_SILENCE_WINDOW=45000
CHAIN=5318007

send()  { cast send "$@" --rpc-url "$RPC_LASNA" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', r['status'])"; }
sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', r['status'])"; }
pre()   { cast compute-address "$A" --nonce "$1" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $NF}'; }
depW()  { forge create "src/$1" --broadcast --rpc-url "$RPC_LASNA" --private-key "$PK" \
            ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
depS()  { forge create "src/$1" --broadcast --rpc-url "$RPC_SEP" --private-key "$PK" \
            ${2:+--constructor-args $2} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }
mustBe() { [ "$1" = "$2" ] && echo "  ✅ $3 = $2" || { echo "❌ $3: '$1' ≠ '$2' — STOP"; exit 1; }; }
chkL()  { local got; got=$(cast call "$1" "$2" --rpc-url "$RPC_LASNA" 2>/dev/null | awk '{print $1}'); \
          got=$(python3 -c "print('$got'.lower().strip('[]'))"); local want=$(python3 -c "print('$3'.lower())"); \
          [ "$got" = "$want" ] && echo "  ✅ posit: $2" || { echo "❌ posit: $2 → '$got' ≠ '$want' — STOP"; exit 1; }; }

echo "== [0] precompute A@Lasna: склад N, сторож N+1, конвертер N+2"
N=$(cast nonce "$A" --rpc-url "$RPC_LASNA")
FUND21=$(pre "$N");      echo "  fund      N   = $FUND21"
DOG21=$(pre "$((N+1))"); echo "  dog       N+1 = $DOG21"
CONV21=$(pre "$((N+2))");echo "  converter N+2 = $CONV21"

echo "== [1] Sepolia: покупщик (конвертер=precompute, склад=precompute)"
BUYER21=$(depS "FuelConverter.sol:FuelBuyer" "$PROXY $CONV21 $FUND21")
[ -n "$BUYER21" ] || { echo "❌ buyer deploy failed"; exit 1; }
echo "  ✅ buyer = $BUYER21"

echo "== [2] Lasna: склад → сторож(v6, правильный путь) → конвертер"
# Fund v6 (ADR-EXPANSION: 7 аргументов — dogRvm упразднён, гвард по dogContract)
F=$(depW "ReliefFund.sol:ReliefFund" "$A $OMNI 0x0000000000000000000000000000000000000000 $OMNI $DOG21 $FUND21 $FUND21")
mustBe "$F" "$FUND21" "fund"
D=$(depW "Watchdog.sol:Watchdog" "$CHAIN $WATCHER_SILENCE_WINDOW $FUND21 $FUND21 $FUND21 $T_CRON10000 $T_BLACKLIST $T_MAILBOX_ALERT $T_DOG_FED $T_WATCHER_LOW $T_LOW_FUND")
mustBe "$D" "$DOG21" "dog (v6 path)"

echo "== [3] позитив-сверки (урок 09.11: в байт-коде должен быть ОЖИДАЕМЫЙ контракт)"
CRON_DEC=$(python3 -c "print(int('$T_CRON10000',16))")
chkL "$DOG21" 'cron10000Topic()(uint256)' "$CRON_DEC"
chkL "$DOG21" 'reliefFund()(address)' "$FUND21"
chkL "$DOG21" 'mailbox()(address)' "$FUND21"

C=$(forge create "src/FuelConverter.sol:FuelConverter" --broadcast --rpc-url "$RPC_LASNA" --private-key "$PK" --constructor-args "$FUND21 $BUYER21 $T_HORIZON" 2>C=$(depS "FuelConverter.sol:FuelConverter" "$FUND21 $BUYER21 $T_HORIZON")1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}')
mustBe "$C" "$CONV21" "converter"
chkL "$CONV21" 'fund()(address)' "$FUND21"
chkL "$CONV21" 'buyer()(address)' "$BUYER21"

echo "== [4] wiring: подписки, реестр, политики"
send "$DOG21" 'init()'
send "$DOG21" 'subscribeWardCry(address)' "$W2_RULES"
send "$DOG21" 'subscribeWardCry(address)' "$W2_GASPAYER"
send "$CONV21" 'init()'
send "$FUND21" 'setWatcherPolicy(uint256,uint256,uint256)' 0 0 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
send "$FUND21" 'setReservePolicy(uint256,uint256)' 0.05ether 0.3ether
send "$FUND21" 'setFeeding(uint256,uint256)' 0.1ether 0.1ether
send "$FUND21" 'setBurnRate(uint256)' 0.05ether
send "$FUND21" 'addWard(address,uint256,uint256)' "$W2_RULES" 0.05ether 0.1ether
send "$FUND21" 'addWard(address,uint256,uint256)' "$W2_GASPAYER" 0.1ether 0.2ether
send "$FUND21" 'addWard(address,uint256,uint256)' "$CONV21" 0.05ether 0.1ether
if [ -n "${W2_CONVERTER:-}" ]; then send "$FUND21" 'removeWard(address)' "$W2_CONVERTER"; fi

echo "== [5] баки (depositTo на SYSTEM) + покупщик"
send "$OMNI" 'depositTo(address)' "$DOG21" --value 0.15ether
send "$OMNI" 'depositTo(address)' "$CONV21" --value 0.1ether
send "$OMNI" 'depositTo(address)' "$FUND21" --value 0.15ether
send "$FUND21" --value 0.6ether
sendS "$BUYER21" 'setFaucet(address)' "$FAUCET"
sendS "$BUYER21" --value 0.02ether

echo "== [6] .env: старое → *_OLD, новое на место"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
sv() { local v; v=$(grep -oP "^$1=\K.*" .env 2>/dev/null); [ -n "$v" ] && upsert "$1_OLD" "$v"; return 0; }
sv W2_FUND; sv W2_DOG; sv W2_CONVERTER; sv W2_BUYER
upsert W2_FUND "$FUND21"; upsert W2_DOG "$DOG21"; upsert W2_CONVERTER "$CONV21"; upsert W2_BUYER "$BUYER21"
echo "done. next: живой крон-тик ≈ на границе 8020000; проверить fedCount/HorizonAlert/конвертер"
