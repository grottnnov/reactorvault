#!/usr/bin/env bash
# deploy-probe.sh — the Lasna probe: a cross-chain callback loop
# Lasna → Eth Sepolia. Proves: subscription → react →
# requestCallbackV_1_0 → the Sepolia proxy → a receiver with
# AbstractCallback guards (+ sender-slot injection). The W2 gate.
# Preconditions: PROBE_DEPLOYER_PK (a single EOA: lREACT on Lasna,
# ETH on Sepolia); topics/proxy live-verified 06.11. Deployment gas:
# forge create with NO cap.
set -uo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

LASNA_RPC=${LASNA_RPC:-https://lasna-rpc.rnk.dev}
SEPOLIA_RPC=${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4
CRON1000=0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4
CRON10000=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56
RECEIVER_FUND=${RECEIVER_FUND:-0.03ether}
## Reactive gas: react() is paid as DEBT on SYSTEM (0x8888), not by the
## address's native balance; debt > 0 = a silent delivery stop (the
## 08.11 lesson: tick 1 into debt → 2.5h of silence; cleared only by
## depositTo(PROBE) — a plain transfer does NOT clear it; missed events
## are never re-delivered).
PROBE_TANK=${PROBE_TANK:-0.1ether}

: "${PROBE_DEPLOYER_PK:?PROBE_DEPLOYER_PK is required}"
PK=$PROBE_DEPLOYER_PK
# Probe source is parameterizable (the 12.11 gas-limit differential probe
# reuses this script with PROBE_SRC=src/probe/CallbackProbe12.sol:CallbackProbe12)
PROBE_SRC=${PROBE_SRC:-src/probe/CallbackProbe.sol:CallbackProbe}

sendL() { cast send "$@" --rpc-url "$LASNA_RPC" --private-key "$PK" --json 2>/dev/null | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'], r['status'])"; }
sendS() { cast send "$@" --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --json 2>/dev/null | python3 -c "import json,sys; r=json.load(sys.stdin); print('  tx', r['transactionHash'], r['status'])"; }
balL() { cast from-wei "$(cast balance "$1" --rpc-url "$LASNA_RPC" 2>/dev/null)"; }
balS() { cast from-wei "$(cast balance "$1" --rpc-url "$SEPOLIA_RPC" 2>/dev/null)"; }
mustCode() { # $1=address $2=name $3=rpc
  for I in $(seq 1 10); do
    SZ=$(cast code "$1" --rpc-url "$3" 2>/dev/null | wc -c)
    [ "$SZ" -gt 4 ] && { echo "  ✅ $2 code in place"; return 0; }
    sleep 3
  done
  echo "❌ $2 ($1) HAS NO CODE — STOP"; exit 1
}
deployTo() { # $1=source $2=rpc $3..=constructor-args; echoes the address
  OUT=$(forge create "$1" --broadcast --rpc-url "$2" --private-key "$PK" \
    --constructor-args "${@:3}" 2>&1)
  # Lasna estimator dies on large creation code ("contract creation code
  # storage out of gas", w22 incident #5): retry with an explicit generous
  # gas limit — unused gas is refunded, the nonce survives the estimate fail
  if ! echo "$OUT" | grep -aq 'Deployed to:'; then
    OUT=$(forge create "$1" --broadcast --rpc-url "$2" --private-key "$PK" \
      --gas-limit 2000000 --gas-price 120gwei --priority-gas-price 118gwei --constructor-args "${@:3}" 2>&1)
  fi
  echo "$OUT" | grep -aE 'Error|error' | head -3
  echo "$OUT" | awk '/Deployed to:/ {print $NF}' | tr -d '[:space:]'
}

A=$(cast wallet address "$PK")
echo "== [0] A=$A | Lasna: $(balL $A) lREACT | Sepolia: $(balS $A) ETH"
[ "$(echo "$(balL $A) > 0.1" | bc)" = "1" ] || { echo "NOT ENOUGH lREACT on Lasna (need >0.1)"; exit 1; }
ETH_MIN=$(echo "${RECEIVER_FUND%ether} + 0.01" | bc)
[ "$(echo "$(balS $A) > $ETH_MIN" | bc)" = "1" ] || { echo "NOT ENOUGH ETH on Sepolia (need > $ETH_MIN: CREATE + fund $RECEIVER_FUND)"; exit 1; }

echo "== [1/6] CallbackProbe on Lasna (phase 2 = resubscribe to Cron10000 from react())"
PROBE=$(deployTo "$PROBE_SRC" "$LASNA_RPC" "$CRON1000" "$CRON10000")
echo "  PROBE=$PROBE"
[ -n "$PROBE" ] && mustCode "$PROBE" probe "$LASNA_RPC" || { echo "probe deploy failed"; exit 1; }

echo "== [2/6] init() subscription (a separate tx — the M0 lesson)"
sendL "$PROBE" 'init()'

echo "== [2b/6] reactive tank: depositTo(PROBE) $PROBE_TANK (a tick's debt ≈ 0.017)"
sendL 0x8888888888888888888888888888888888888888 'depositTo(address)' "$PROBE" --value "$PROBE_TANK"

echo "== [3/6] CallbackProbeReceiver on Sepolia (proxy=0xAa14…3b4, sender=probe)"
RECEIVER=$(deployTo src/probe/CallbackProbeReceiver.sol:CallbackProbeReceiver "$SEPOLIA_RPC" "$PROXY" "$PROBE")
echo "  RECEIVER=$RECEIVER"
[ -n "$RECEIVER" ] && mustCode "$RECEIVER" receiver "$SEPOLIA_RPC" || { echo "receiver deploy failed"; exit 1; }

echo "== [4/6] probe.setReceiver (owner = A)"
sendL "$PROBE" 'setReceiver(address)' "$RECEIVER"

echo "== [5/6] receiver fund $RECEIVER_FUND (callbacks are billed to the recipient in ETH)"
sendS "$RECEIVER" --value "$RECEIVER_FUND"

echo "== [6/6] status"
echo "  probe: pingCount=$(cast call "$PROBE" 'pingCount()(uint256)' --rpc-url "$LASNA_RPC" 2>/dev/null) resubscribed=$(cast call "$PROBE" 'resubscribed()(bool)' --rpc-url "$LASNA_RPC" 2>/dev/null) pings2=$(cast call "$PROBE" 'pings2()(uint256)' --rpc-url "$LASNA_RPC" 2>/dev/null) callbacksRequested=$(cast call "$PROBE" 'callbacksRequested()(uint256)' --rpc-url "$LASNA_RPC" 2>/dev/null)"
echo "  receiver: callbacksReceived=$(cast call "$RECEIVER" 'callbacksReceived()(uint256)' --rpc-url "$SEPOLIA_RPC" 2>/dev/null) bal=$(balS $RECEIVER) ETH"
echo ""
echo "LOOP: a Cron1000 tick every ~18 min; on the 4th tick react() itself"
echo "  resubscribes to Cron10000 (live check #1 — subscribing from"
echo "  react(), tick ≈ 3h); after 3 phase-2 ticks — the final"
echo "  unsubscribe. Watch it:"
echo "  Lasna:  cast logs --address $PROBE --rpc-url $LASNA_RPC --from-block latest"
echo "  Sepolia: cast logs --address $RECEIVER --rpc-url $SEPOLIA_RPC --from-block latest"
echo "  Proves: ProbeReact (react is alive) + ProbeReceived(sender=PROBE, ping) —"
echo "  the full cross-chain loop with guards; ResubscribedFromReact ="
echo "  subscribing from react() is allowed (the GasPayer gate);"
echo "  lastObservedSender==$PROBE = sender-slot injection."
