#!/usr/bin/env bash
# rh-pool-discovery.sh — pick the Uniswap v4 pool the RH swap adapter
# trades through (26.11).
#
# WHAT: on Robinhood Chain (4663) ANYONE can initialize a pool for a
# token pair with ANY fee/tickSpacing, so the pair has dozens of pools
# (mostly launchpad spam with absurd fees). The adapter must trade the
# one real pool, chosen by MEASUREMENT, not by guess:
#   1. enumerate every Initialize of the PoolManager for the exact
#      token pair (registry addresses pinned below — identity is the
#      contract address, never the ticker);
#   2. rank live: StateView.getSlot0 (alive + price) and
#      StateView.getLiquidity (depth) per pool;
#   3. filter: no hook (hook pools change semantics), static sane fee
#      (<= 3000: v4 fee units, 3000 = 0.30%), depth >= the demo
#      capital in stable units.
# Output: a ranked table + the chosen PoolKey words with sources (the
# Initialize tx + block per pool). Evidence JSON goes to
# internal/docs/evidence/rh-pools-<date>.json (public data only).
# EXIT: 0 = a pool passed every filter; 1 = none did (STOP — do not
# hardcode; widen the pair or report the gap).
#
# RPC quirk learned live 26.11: topic-filtered getLogs silently
# returns EMPTY for wide ranges (works <= ~10k blocks for partial
# topic sets) — but the FULL 4-topic spec with the pair addresses
# works in 10M-block chunks. Rate limit is real (429): sleeps between
# calls. All limits are handled below; do not "optimize" them away.
#
# Usage: script/rh-pool-discovery.sh   (read-only: eth_calls + getLogs)
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC=${RH_RPC:-https://rpc.mainnet.chain.robinhood.com}

# Pinned 26.11 from the official Robinhood asset registry snapshot
# (api.robinhood.com/rhj/assets, 2026-09-02; identity = address) and
# the official Uniswap v4 deployments page (chain 4663). Every address
# is LIVE-CHECKED below before use: code size / symbol().
TSLA=0x322f0929c4625ed5bad873c95208d54e1c003b2d
USDG=0x5fc5360d0400a0fd4f2af552add042d716f1d168
PM=0x8366a39cc670b4001a1121b8f6a443a643e40951
SV=0xf3334192d15450cdd385c8b70e03f9a6bd9e673b
# topic0 of the fork's Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)
# (id + both currencies are INDEXED on this fork — the pair filter is exact)
T_INIT=0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438
# The RH v4 is an early-2024 snapshot: fees are STATIC-per-pool here
# (dynamic LP fee exists but requires a hook; hookless = static).
MAX_FEE=3000
# Demo capital $25-30 (STRATEGY.md:77) -> require >= $100 of the
# stable side in the pool so the guard's demo swap is a rounding error.
MIN_DEPTH_USD=100

rpc() { curl -s -X POST "$RPC" -H 'Content-Type: application/json' -d "$1"; }

echo "== live checks =="
for a in "$PM" "$SV"; do
  sz=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$a\",\"latest\"]}" \
    | python3 -c "import json,sys; print((len(json.load(sys.stdin)['result'])-2)//2)")
  [ "$sz" -gt 100 ] || { echo "FAIL: no code at $a ($sz bytes)"; exit 1; }
  echo "  code ok: $a ($sz bytes)"
done
sym() { cast call "$1" "symbol()(string)" --rpc-url "$RPC" | tr -d '"'; }
s0=$(sym "$TSLA"); s1=$(sym "$USDG")
echo "  symbol($TSLA) = $s0; symbol($USDG) = $s1"
[ "$s0" = "TSLA" ] && [ "$s1" = "USDG" ] || { echo "FAIL: symbol mismatch — addresses are not what we think"; exit 1; }

C0=$(python3 -c "print(min('$TSLA'.lower(),'$USDG'.lower()))")
C1=$(python3 -c "print(max('$TSLA'.lower(),'$USDG'.lower()))")
echo "  pair: currency0=$C0 currency1=$C1"

HEAD=$(rpc '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")
echo "  head = $HEAD"

echo "== scanning Initialize logs (10M-block chunks, full topic spec) =="
python3 - "$C0" "$C1" "$HEAD" <<'PYEOF' > /tmp/opencode/rh-init-logs.jsonl
import json, subprocess, sys, time
c0, c1, head = sys.argv[1].lower().replace('0x',''), sys.argv[2].lower().replace('0x',''), int(sys.argv[3])
C0 = '0x' + c0.rjust(64, '0'); C1 = '0x' + c1.rjust(64, '0')
T0 = '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438'
PM = '0x8366a39cc670b4001a1121b8f6a443a643e40951'
rpc = 'https://rpc.mainnet.chain.robinhood.com'
def post(payload):
    for attempt in range(3):
        r = subprocess.run(['curl','-s','-X','POST',rpc,'-H','Content-Type: application/json','-d',json.dumps(payload)],capture_output=True,text=True)
        try:
            d = json.loads(r.stdout)
            if 'result' in d: return d['result']
            if d.get('error',{}).get('code') == 429:
                time.sleep(3*(attempt+1)); continue
            print(f'RPC error: {d.get("error")}', file=sys.stderr); return None
        except Exception as e:
            print(f'curl fail: {e}', file=sys.stderr); time.sleep(2)
    return None
seen = {}
step = 10_000_000
b = 9079
while b <= head:
    to = min(b + step - 1, head)
    logs = post({'jsonrpc':'2.0','id':1,'method':'eth_getLogs','params':[{
        'address': PM, 'topics': [T0, None, C0, C1],
        'fromBlock': hex(b), 'toBlock': hex(to)}]})
    if logs is None:
        print(f'chunk {b}-{to}: FAILED, skipping', file=sys.stderr)
    else:
        for l in logs:
            pid = l['topics'][1]
            d = l['data'][2:]
            w = [d[i*64:(i+1)*64] for i in range(len(d)//64)]
            fee = int(w[0],16); ts = int(w[1],16); ts = ts - (1<<256) if ts >> 255 else ts
            hooks = '0x' + w[2][24:]
            sqrt_p = int(w[3],16); tick = int(w[4],16); tick = tick - (1<<256) if tick >> 255 else tick
            rec = {'poolId': pid, 'fee': fee, 'tickSpacing': ts, 'hooks': hooks,
                   'sqrtPriceX96': sqrt_p, 'tick': tick,
                   'initBlock': int(l['blockNumber'],16), 'initTx': l['transactionHash']}
            if pid not in seen: seen[pid] = rec
    b = to + 1
    time.sleep(2.5)
for pid, rec in seen.items(): print(json.dumps(rec))
sys.stderr.write(f'unique pools: {len(seen)}\n')
PYEOF
N=$(wc -l < /tmp/opencode/rh-init-logs.jsonl)
echo "  unique pools: $N"

echo "== live ranking (StateView) =="
python3 - <<'PYEOF' > /tmp/opencode/rh-pools-ranked.txt
import json, subprocess, sys, time
pools = [json.loads(l) for l in open('/tmp/opencode/rh-init-logs.jsonl')]
SV = '0xf3334192d15450cdd385c8b70e03f9a6bd9e673b'
rpc = 'https://rpc.mainnet.chain.robinhood.com'
def castcall(sig, arg):
    for attempt in range(3):
        r = subprocess.run(['cast','call',SV,sig,arg,'--rpc-url',rpc],capture_output=True,text=True)
        if r.returncode == 0: return r.stdout.strip()
        time.sleep(2*(attempt+1))
    return None
rows = []
for p in pools:
    slot0 = castcall('getSlot0(bytes32)', p['poolId'])
    liq = castcall('getLiquidity(bytes32)', p['poolId'])
    time.sleep(1.2)
    if not slot0 or not liq: continue
    s = slot0[2:]; w = [int(s[i*64:(i+1)*64],16) for i in range(len(s)//64)]
    if w[0] == 0: continue  # slot0.sqrtPriceX96 == 0: not really live
    L = int(liq[2:].lstrip('0') or '0', 16) if liq != '0x' else 0
    # full-range virtual reserves in raw units: y = L*sqrtP/2^96 (token1 side)
    sqrtP = w[0] / 2**96
    y_raw = L * sqrtP
    # TSLA=18 decimals (token0), USDG=6 (token1) -> stable-side value in USD
    y_usd = y_raw / 1e6
    rows.append({**p, 'L': L, 'lpFee': w[3] if len(w) > 3 else 0, 'depthUsd': y_usd})
rows.sort(key=lambda r: (-r['depthUsd']))
print(f"{'depthUsd':>14} {'L':>22} {'fee':>8} {'ts':>6} {'hook':>5} poolId / init tx")
for r in rows:
    print(f"{r['depthUsd']:>14.2f} {r['L']:>22} {r['fee']:>8} {r['tickSpacing']:>6} "
          f"{'' if int(r['hooks'],16)==0 else 'HOOK'} {r['poolId']} blk={r['initBlock']} tx={r['initTx'][:18]}..")
# chosen = hookless, fee <= 3000, deepest
ok = [r for r in rows if int(r['hooks'],16)==0 and r['fee'] <= 3000 and r['depthUsd'] >= 100]
if ok:
    c = ok[0]
    print('\nCHOSEN (hookless, fee<=3000, depth>=$100):')
    print(f"  currency0 = 0x322f0929c4625ed5bad873c95208d54e1c003b2d")
    print(f"  currency1 = 0x5fc5360d0400a0fd4f2af552add042d716f1d168")
    print(f"  fee = {c['fee']}, tickSpacing = {c['tickSpacing']}, hooks = 0x0")
    print(f"  poolId = {c['poolId']}")
    print(f"  source: Initialize at block {c['initBlock']}, tx {c['initTx']} (measured live)")
    json.dump(rows, open('/tmp/opencode/rh-pools-all.json','w'), indent=1)
else:
    print('\nNO POOL PASSED THE FILTERS — do not hardcode; report the gap')
    json.dump(rows, open('/tmp/opencode/rh-pools-all.json','w'), indent=1)
PYEOF
cat /tmp/opencode/rh-pools-ranked.txt

# evidence artifact (public data only) into the internal vault
EVID="internal/docs/evidence/rh-pools-$(date +%y%m%d).json"
python3 - <<PYEOF
import json
rows = json.load(open('/tmp/opencode/rh-pools-all.json'))
out = {
  'generated': '$(date -Iseconds)',
  'chain': 4663,
  'method': 'PoolManager Initialize scan (full topic spec, 10M chunks) + StateView getSlot0/getLiquidity live',
  'pair': ['TSLA 0x322f0929c4625ed5bad873c95208d54e1c003b2d (18d)', 'USDG 0x5fc5360d0400a0fd4f2af552add042d716f1d168 (6d)'],
  'pools': rows,
}
json.dump(out, open('$EVID','w'), indent=1)
print(f"evidence: $EVID")
PYEOF

grep -q 'CHOSEN' /tmp/opencode/rh-pools-ranked.txt || exit 1
exit 0
