#!/usr/bin/env bash
# lever-w22.sh — демо-плечо оператора (W2.2 шаг 3): оператор САМ даёт
# рынку ликвидность как заимодавец (бутстрап — форк-тест 11.11: сейф
# никогда не придёт в пустой рынок, а заём без ликвидности невозможен),
# затем залог и заём. Заём поднимает ставку >1%/год → следующий
# будильник переводит капитал сейфа Aave → Morpho.
#
# Суммы env-настраиваемы: при ETH ≥ ~0.025defaults хватает; при нехватке
# скрипт откажется ДО траты нонсов. Environment: DEPLOYER_PRIVATE_KEY, .env.
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")

MORPHO=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
IRM=0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c
WETH=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c
ORACLE=${W2_ORACLE:?}; MORPHO_AD=${W2_MORPHO_ADAPTER:?}
LLTV=915000000000000000

LEND=${W22_LEVER_LEND:-0.010}
COLL=${W22_LEVER_COLLATERAL:-0.012}
BORROW=${W22_LEVER_BORROW:-0.008}
LEND_W=$(cast to-wei "$LEND"); COLL_W=$(cast to-wei "$COLL"); BORROW_W=$(cast to-wei "$BORROW")
WRAP_W=$((LEND_W + COLL_W))

sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }

BAL=$(cast balance "$A" --rpc-url "$RPC_SEP")
NEED=$((WRAP_W + 1500000000000000))
echo "== A@Sepolia=$(cast from-wei $BAL) ETH, нужно ~$(cast from-wei $NEED)"
[ "$(python3 -c "print(1 if $BAL > $NEED else 0)")" = "1" ] || { echo "NOT ENOUGH ETH — задай W22_LEVER_* меньше или пополни A"; exit 1; }

MP="($WETH,$WETH,$ORACLE,$IRM,$LLTV)"
echo "== [1] WETH wrap($LEND+$COLL) → approve Morpho"
sendS "$WETH" 'deposit()' --value "$WRAP_W"
sendS "$WETH" 'approve(address,uint256)' "$MORPHO" "$(python3 -c 'print(2**256-1)')"

echo "== [2] ликвидность заимодавца → залог → заём"
sendS "$MORPHO" 'supply((address,address,address,address,uint256),uint256,uint256,address,bytes)' "$MP" "$LEND_W" 0 "$A" 0x
sendS "$MORPHO" 'supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)' "$MP" "$COLL_W" "$A" 0x
sendS "$MORPHO" 'borrow((address,address,address,address,uint256),uint256,uint256,address,address)' "$MP" "$BORROW_W" 0 "$A" "$A"

echo "== [3] позитив-сверка: ставка рынка >1%/год (плечо работает)"
RATE=$(cast call "$MORPHO_AD" 'supplyRatePerYear()(uint256)' --rpc-url "$RPC_SEP")
echo "  supplyRatePerYear = $RATE (ожидаю > 10000000000000000)"
[ "$(python3 -c "print(1 if int('$RATE') > 10**16 else 0)")" = "1" ] && echo "  ✅ lever live" || echo "  ❌ ставка не поднялась — разбирать (utilization?)"
