#!/usr/bin/env bash
# fix-adapters-acl-1711.sh — incident #19: redeploy both pool adapters
# with the onlyVault guard (immutable assetVault; the Uniswap v4
# onlyPoolManager / Yearn onlyVault pattern), move the whitelist and
# drain the old adapters the regular way.
#
# Steps (all tx from A, gas with NO cap — the OOG lesson):
#   [1] deploy AavePoolAdapter(vault, pool, weth)   — Sepolia
#   [2] deploy MorphoPoolAdapter(vault, morpho, mp, irm) — mp taken
#       from the OLD adapter live (anti-drift), marketId must match
#   [3] vault.authorizePoolAdapter ×2 (owner=A)
#   [4] executor.setPools(new pair) (owner=A)
#   [5] vault.withdrawAll() — pulls 0.0019 from the old Morpho back
#       to A, the ledger resets (totalDeposited=0)
#   [6] vault.deposit{0.0019} from A — fresh working capital (5% →
#       the battery)
#   [7] .env: old → *_OLD, upsert new; positive checks via getters
#
# After: the executor's next tick spreads the free capital across the
# new pools on its own (rebalance: deployToPool of the best). The old
# adapters are empty (principal=0 → withdraw reverts AbovePrincipal)
# — harmless.
#
# EXECUTION FACT 17.11: [1]-[3],[6]-[8] from the script; [4] setPools
# and [5] withdrawAll fell to a sendS quoting bug (two addresses as a
# single argument — cast send would not parse it) and were repeated
# manually in the same session: setPools tx 0x07af6ac0…, withdrawAll
# tx 0x175fd753…, redeposit 0.002 tx 0x2a9ecd57… (the line below is
# fixed post factum, for reuse). The outcome verified by getters:
# poolA/poolB=new, the old ones empty (principal=0),
# totalDeposited=0.002.
#
# Environment: DEPLOYER_PRIVATE_KEY, .env (W2_ASSETVAULT, W2_EXECUTOR,
# W2_AAVE_ADAPTER, W2_MORPHO_ADAPTER, W2_ORACLE).
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

set -a; source .env; set +a
RPC_SEP=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PK=${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}
A=$(cast wallet address "$PK")
[ "$A" = "0xF696ae41aAb9A8979F18086d70d5e6A9Bf9FF53a" ] || { echo "❌ key is not A ($A) — STOP"; exit 1; }

VAULT=${W2_ASSETVAULT:?W2_ASSETVAULT in .env}
EXEC=${W2_EXECUTOR:?W2_EXECUTOR in .env}
AAVE_OLD=${W2_AAVE_ADAPTER:?W2_AAVE_ADAPTER in .env}
MORPHO_OLD=${W2_MORPHO_ADAPTER:?W2_MORPHO_ADAPTER in .env}

MORPHO=0xd011EE229E7459ba1ddd22631eF7bF528d424A14
AAVE_POOL=0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
IRM=0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c
WETH=0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c

sendS() { cast send "$@" --rpc-url "$RPC_SEP" --private-key "$PK" --json 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'][:18]+'…', 'status', r['status'])"; }
dep()   { local spec="src/$2.sol:$2"; [[ "$2" == *:* ]] && spec="src/${2%%:*}.sol:${2##*:}"
  forge create "$spec" --broadcast --rpc-url "$RPC_SEP" --private-key "$PK" \
    ${3:+--constructor-args $3} 2>&1 | grep -aoE 'Deployed to: 0x[0-9a-fA-F]{40}' | awk '{print $3}'; }

echo "== [0] live before: A=$(cast from-wei "$(cast balance $A --rpc-url $RPC_SEP)") ETH"
MID_OLD=$(cast call "$MORPHO_OLD" 'marketId()(bytes32)' --rpc-url "$RPC_SEP")
MP="($WETH,$WETH,$W2_ORACLE,$IRM,915000000000000000)"
echo "  old marketId = $MID_OLD"
IN_OLD=$(cast call "$VAULT" "inPoolOf(address)(uint256)" "$MORPHO_OLD" --rpc-url "$RPC_SEP" | awk '{print $1}')
echo "  inPoolOf(old morpho) = $IN_OLD wei"

echo "== [1] new AavePoolAdapter(vault…)"
AAVE_NEW=$(dep "$RPC_SEP" "adapters/AavePoolAdapter:AavePoolAdapter" "$VAULT $AAVE_POOL $WETH")
[ -n "$AAVE_NEW" ] || { echo "❌ aave deploy failed"; exit 1; }
echo "  ✅ $AAVE_NEW"

echo "== [2] new MorphoPoolAdapter(vault…)"
MORPHO_NEW=$(dep "$RPC_SEP" "adapters/MorphoPoolAdapter:MorphoPoolAdapter" "$VAULT $MORPHO $MP $IRM")
[ -n "$MORPHO_NEW" ] || { echo "❌ morpho deploy failed"; exit 1; }
echo "  ✅ $MORPHO_NEW"
MID_NEW=$(cast call "$MORPHO_NEW" 'marketId()(bytes32)' --rpc-url "$RPC_SEP")
[ "$MID_NEW" = "$MID_OLD" ] && echo "  ✅ marketId matched (same market)" || { echo "❌ marketId drifted: $MID_NEW — STOP"; exit 1; }
GV=$(cast call "$MORPHO_NEW" 'assetVault()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')
[ "$(echo $GV | tr '[:upper:]' '[:lower:]')" = "$(echo $VAULT | tr '[:upper:]' '[:lower:]')" ] && echo "  ✅ assetVault = the safe" || { echo "❌ assetVault ≠ the safe — STOP"; exit 1; }

echo "== [3] safe: whitelist the new adapters"
sendS "$VAULT" 'authorizePoolAdapter(address)' "$AAVE_NEW"
sendS "$VAULT" 'authorizePoolAdapter(address)' "$MORPHO_NEW"

echo "== [4] executor: setPools(new pair)"
sendS "$EXEC" 'setPools(address,address)' "$AAVE_NEW" "$MORPHO_NEW"

echo "== [5] withdrawAll: drain the old ones (0.0019 → A, ledger reset)"
sendS "$VAULT" 'withdrawAll()'

echo "== [6] redeposit the working capital"
sendS "$VAULT" 'deposit()' --value 1900000000000000

echo "== [7] .env: old → *_OLD, upsert new"
upsert() { if grep -q "^$1=" .env 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s\n' "$1=$2" >> .env; fi; }
save_old() { local v; v=$(grep -oP "^$1=\K.*" .env 2>/dev/null); [ -n "$v" ] && upsert "$1_OLD" "$v"; return 0; }
save_old W2_AAVE_ADAPTER;  upsert W2_AAVE_ADAPTER "$AAVE_NEW"
save_old W2_MORPHO_ADAPTER; upsert W2_MORPHO_ADAPTER "$MORPHO_NEW"

echo "== [8] positive checks"
echo "  poolA = $(cast call "$EXEC" 'poolA()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  poolB = $(cast call "$EXEC" 'poolB()(address)' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  isPoolAdapter(newAave) = $(cast call "$VAULT" "isPoolAdapter(address)(bool)" "$AAVE_NEW" --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  isPoolAdapter(newMorpho) = $(cast call "$VAULT" "isPoolAdapter(address)(bool)" "$MORPHO_NEW" --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  inPoolOf(old morpho) = $(cast call "$VAULT" "inPoolOf(address)(uint256)" "$MORPHO_OLD" --rpc-url "$RPC_SEP" | awk '{print $1}') (expect 0)"
echo "  old morpho principal = $(cast call "$MORPHO_OLD" 'principal()(uint256)' --rpc-url "$RPC_SEP" | awk '{print $1}') (expect 0)"
echo "  totalDeposited = $(cast call "$VAULT" 'totalDeposited()' --rpc-url "$RPC_SEP" | awk '{print $1}')"
echo "  A = $(cast from-wei "$(cast balance $A --rpc-url $RPC_SEP)") ETH"
echo "DONE. The executor's next tick will spread the capital across the new pools."
