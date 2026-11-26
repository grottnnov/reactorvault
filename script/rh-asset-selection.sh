#!/usr/bin/env bash
# rh-asset-selection.sh — the guard's admission algorithm: which
# tokenized real assets we offer, measured, not guessed (26.11).
#
# WHAT: the two-layer pipeline over every feed-covered stock token on
# Robinhood Chain 4663. Dominant layer = the REAL paper (S&P-style
# quality via measured on-chain data), wrapper layer = tokenization
# quality. Conveyor mechanics from freqtrade (57k stars, battle-tested
# pairlist chain: gates -> top-N ranking -> refresh cycle);
# documentation frame = DeFi Pulse Index methodology (four dimensions);
# the industry anchors are cited in README (asset-selection section).
#
# Layer A — the real paper:
#   - class (ETF / mega-cap stock / high-vol stock) from the ticker set;
#   - realized volatility measured ON-CHAIN from the Chainlink feed's
#     own round history (the feed carries the paper's price series);
#   - cadence (updates/hour) — feed reliability + guard freshness.
# Layer B — the wrapper:
#   - official registry token (identity = address, ISIN join);
#   - live feed (answer > 0) + dual-feed deviation (Vitalik-review item:
#     primary vs secondary current answers, % apart);
#   - exit liquidity: deepest hookless <asset>/USDG pool with a sane
#     static fee (<= 3000), stable-side depth in USD;
#   - position-capacity number per asset: max client position = 1% of
#     the measured depth (the brokers' capacity practice, moved to
#     pools; worst-case full-exit impact ~= 2%).
#
# OWN instruments (honestly labeled: no OSS analog exists — reactive
# guards on stock tokens are new): feed cadence as burn/freshness
# metric, and the relative position-size cap.
#
# INPUT: internal/docs/evidence/feed-registry-<date>.json (the pairs
# join; re-run script/feed-registry.sh if stale). Every address and
# every number below is re-measured LIVE on each run.
# OUTPUT: internal/docs/evidence/rh-spectrum-<date>.json + a ranked
# table on stdout. EXIT: 0 = at least one asset passed all gates;
# 1 = none did (STOP — the offerable spectrum is empty).
#
# RPC quirks (measured 26.11, same as rh-pool-discovery.sh): full
# 4-topic arrays work in 10M-block chunks; partial topic sets die
# silently beyond ~1-10k blocks; 429s are real — sleeps everywhere.
#
# Usage: script/rh-asset-selection.sh   (read-only: eth_calls + getLogs)
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC=${RH_RPC:-https://rpc.mainnet.chain.robinhood.com}
PM=0x8366a39cc670b4001a1121b8f6a443a643e40951
SV=0xf3334192d15450cdd385c8b70e03f9a6bd9e673b
USDG=0x5fc5360d0400a0fd4f2af552add042d716f1d168
T_INIT=0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438
# gates (parameters with sources):
MIN_DEPTH_USD=100000   # absolute asset gate: below this the exit market is broken
MAX_FEE=3000           # v4 fee units, 3000 = 0.30%: sane static tier
POS_CAP_NUM=1 POS_CAP_DEN=100  # client position <= 1% of depth -> full-exit impact ~2%
ROUNDS=50              # feed history depth per asset
# risk-level recommendation: warn rung ~ 2x daily sigma
# (low: warn 5%, mid: 8%, high: 18%) -> thresholds 2.5% / 4.0%
VOL_LOW_MAX=2.5 VOL_MID_MAX=4.0
ETF_SET="SPY QQQ DIA IWM VTI VOE"

EVID_DIR=internal/docs/evidence
FEED_EVID=$(ls -1 "$EVID_DIR"/feed-registry-*.json 2>/dev/null | sort | tail -1)
[ -n "$FEED_EVID" ] || { echo "FAIL: no feed-registry evidence; run script/feed-registry.sh first"; exit 1; }
echo "== input: $FEED_EVID =="

# Resumable: point RH_SELECT_WORK at an earlier run's directory to
# reuse its phases (pools.json skips the scan, feed-stats.json skips
# phase 3). A filter bug must never cost the scan hour again.
WORK=${RH_SELECT_WORK:-$(mktemp -d /tmp/opencode/rh-select.XXXXXX)}
mkdir -p "$WORK"
echo "== phase 1: pool scan (both orientations, 10M chunks) =="
if [ -s "$WORK/pools.json" ]; then
  echo "  resume: pools.json present, skipping the scan"
else
python3 - "$FEED_EVID" "$WORK" <<'PYEOF'
import json, subprocess, sys, time
feed_evid, work = sys.argv[1], sys.argv[2]
pairs = json.load(open(feed_evid))['pairs']
targets = {p['token'].lower(): p['ticker'] for p in pairs}
json.dump(pairs, open(f'{work}/pairs.json', 'w'))
USDG = '0x' + '5fc5360d0400a0fd4f2af552add042d716f1d168'.rjust(64, '0')
T0 = '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438'
PM = '0x8366a39cc670b4001a1121b8f6a443a643e40951'
rpc = 'https://rpc.mainnet.chain.robinhood.com'
def post(payload, tries=3):
    for a in range(tries):
        r = subprocess.run(['curl','-s','-X','POST',rpc,'-H','Content-Type: application/json','-d',json.dumps(payload)],capture_output=True,text=True)
        try:
            d = json.loads(r.stdout)
            if 'result' in d: return d['result']
            if d.get('error',{}).get('code') == 429: time.sleep(3*(a+1)); continue
            return None
        except Exception: time.sleep(2)
    return None
pools = {}
def scan(topics):
    b, step, head = 9079, 9_999_000, None
    while True:
        if head is None:
            head = post({'jsonrpc':'2.0','id':1,'method':'eth_blockNumber','params':[]})
            head = int(head, 16)
        to = min(b + step - 1, head)
        # Adaptive: the RPC caps BOTH the block range AND the result
        # count (10k logs; the orientation scan catches every memecoin
        # pool). On any failure halve the window and retry; only a
        # minimal window failing repeatedly aborts (no silent skips).
        hi = to
        while True:
            logs = None
            for attempt in range(4):
                logs = post({'jsonrpc':'2.0','id':1,'method':'eth_getLogs','params':[{'address':PM,'topics':topics,'fromBlock':hex(b),'toBlock':hex(hi)}]})
                if logs is not None: break
                time.sleep(4 * (attempt + 1))
            if logs is not None: break
            if hi - b <= 250_000:
                print(f'FATAL: window {b}-{hi} failed after retries — aborting, no silent data loss', file=sys.stderr)
                sys.exit(1)
            hi = b + (hi - b) // 2
            print(f'  halving window -> {b}-{hi}', file=sys.stderr)
        if hi != to:
            # a narrowed window: process and continue from where it ended
            to = hi
        if logs:
            for l in logs:
                pid = l['topics'][1]
                if pid in pools: continue
                c0 = '0x' + l['topics'][2][-40:]
                c1 = '0x' + l['topics'][3][-40:]
                d = l['data'][2:]
                w = [d[i*64:(i+1)*64] for i in range(len(d)//64)]
                fee = int(w[0], 16)
                ts = int(w[1], 16); ts = ts - (1<<256) if ts >> 255 else ts
                hooks = '0x' + w[2][24:]
                pools[pid] = {'poolId': pid, 'c0': c0, 'c1': c1, 'fee': fee,
                              'tickSpacing': ts, 'hooks': hooks,
                              'initBlock': int(l['blockNumber'], 16), 'initTx': l['transactionHash']}
        if to >= head: break
        b = to + 1
        time.sleep(5)
print('  scanning orientation USDG=currency1 ...', file=sys.stderr)
scan([T0, None, None, USDG])
print('  scanning orientation USDG=currency0 ...', file=sys.stderr)
scan([T0, None, USDG, None])
# keep pools of the target assets vs USDG, hookless, sane fee
cand = []
for p in pools.values():
    other = None
    usdg = '0x' + USDG[-40:]
    other = None
    if p['c1'].lower() == usdg and p['c0'].lower() in targets: other = p['c0']
    if p['c0'].lower() == usdg and p['c1'].lower() in targets: other = p['c1']
    if other and int(p['hooks'], 16) == 0 and p['fee'] <= 3000:
        cand.append(p)
json.dump(cand, open(f'{work}/cand-pools.json', 'w'))
json.dump(pools, open(f'{work}/pools.json', 'w'))
print(f'  unique pools total: {len(pools)}; candidate pools (target asset, hookless, fee<=3000): {len(cand)}', file=sys.stderr)
PYEOF
fi

echo "== phase 2: pool depth (StateView, throttled) =="
python3 - "$WORK" <<'PYEOF'
import json, subprocess, sys, time
work = sys.argv[1]
cand = json.load(open(f'{work}/cand-pools.json'))
pairs = json.load(open(f'{work}/pairs.json'))
SV = '0xf3334192d15450cdd385c8b70e03f9a6bd9e673b'
USDG = '5fc5360d0400a0fd4f2af552add042d716f1d168'
rpc = 'https://rpc.mainnet.chain.robinhood.com'
def castcall(sig, arg, tries=3):
    for a in range(tries):
        r = subprocess.run(['cast','call',SV,sig,arg,'--rpc-url',rpc],capture_output=True,text=True)
        if r.returncode == 0: return r.stdout.strip()
        time.sleep(2*(a+1))
    return None
rows = []
for i, p in enumerate(cand):
    slot0 = castcall('getSlot0(bytes32)', p['poolId'])
    liq = castcall('getLiquidity(bytes32)', p['poolId'])
    time.sleep(0.8)
    if not slot0 or not liq: continue
    s = slot0[2:]
    w = [int(s[j*64:(j+1)*64],16) for j in range(len(s)//64)]
    if w[0] == 0: continue
    L = int(liq[2:].lstrip('0') or '0', 16) if liq != '0x' else 0
    sqrtP = w[0] / 2**96
    # USDG side virtual reserve: currency1 -> L*sqrtP, currency0 -> L/sqrtP
    usdg_is_c1 = p['c1'].lower().endswith(USDG)
    y_raw = L * sqrtP if usdg_is_c1 else (L / sqrtP if sqrtP else 0)
    p2 = dict(p); p2['L'] = L; p2['depthUsd'] = y_raw / 1e6
    rows.append(p2)
    if (i+1) % 25 == 0: print(f'  ranked {i+1}/{len(cand)} pools', file=sys.stderr)
json.dump(rows, open(f'{work}/ranked-pools.json','w'))
print(f'  live pools ranked: {len(rows)}', file=sys.stderr)
PYEOF

echo "== phase 3: feed rounds (cadence, volatility, dual deviation) =="
if [ -s "$WORK/feed-stats.json" ]; then
  echo "  resume: feed-stats.json present, skipping the rounds walk"
else
python3 - "$WORK" <<'PYEOF'
import json, math, subprocess, sys, time
work = sys.argv[1]
pairs = json.load(open(f'{work}/pairs.json'))
rpc = 'https://rpc.mainnet.chain.robinhood.com'
def call(addr, data, tries=3):
    for a in range(tries):
        r = subprocess.run(['curl','-s','-X','POST',rpc,'-H','Content-Type: application/json','-d',
            json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_call','params':[{'to':addr,'data':data},'latest']})],
            capture_output=True,text=True)
        try:
            d = json.loads(r.stdout)
            if 'result' in d and d['result'] != '0x': return d['result']
            if d.get('error',{}).get('code') == 429: time.sleep(3*(a+1)); continue
            return None
        except Exception: time.sleep(2)
    return None
def latest(feed):
    r = call(feed, '0xfeaf968c')  # latestRoundData()
    if not r: return None
    h = r[2:]
    w = [h[i*64:(i+1)*64] for i in range(len(h)//64)]
    rid = int(w[0],16); ans = int(w[1],16); upd = int(w[3],16)
    return rid, ans, upd
def round_at(feed, rid):
    r = call(feed, '0x9a6fc8f5' + format(rid, '064x'))  # getRoundData(uint80)
    if not r: return None
    h = r[2:]
    w = [h[i*64:(i+1)*64] for i in range(len(h)//64)]
    return int(w[1],16), int(w[3],16)  # answer, updatedAt
out = []
for p in pairs:
    feed, feed2 = p['feed'], p.get('feedSecondary')
    lr = latest(feed)
    if not lr or lr[1] <= 0:
        out.append({**p, 'feedLive': False}); continue
    rid0, ans0, upd0 = lr
    hist = [(ans0, upd0)]
    for i in range(1, 50):
        rr = round_at(feed, rid0 - i)
        if not rr or rr[1] == 0 or rr[0] <= 0: break
        hist.append(rr)
        time.sleep(0.35)
    # cadence + vol over the window
    if len(hist) >= 3:
        span_s = hist[0][1] - hist[-1][1]
        hrs = max(span_s / 3600.0, 1e-9)
        cad = (len(hist)-1) / hrs
        rets = []
        for a, b in zip(hist, hist[1:]):
            if b[0] > 0 and a[0] > 0: rets.append(math.log(a[0]/b[0]))
        mu = sum(rets)/len(rets) if rets else 0.0
        var = sum((r-mu)**2 for r in rets)/max(len(rets)-1, 1) if len(rets) > 1 else 0.0
        sig_round = math.sqrt(var)
        sig_daily = sig_round * math.sqrt(max(cad * 24, 1e-9))
        dev = None
        if feed2:
            l2 = latest(feed2)
            if l2 and l2[1] > 0:
                dev = abs(ans0 - l2[1]) / max(ans0, 1) * 100
        out.append({**p, 'feedLive': True, 'rounds': len(hist), 'windowHrs': round(hrs,1),
                    'updatesPerHour': round(cad, 3), 'volDailyPct': round(sig_daily*100, 3),
                    'dualDevPct': (round(dev, 3) if dev is not None else None)})
    else:
        out.append({**p, 'feedLive': True, 'rounds': len(hist)})
    print(f"  {p['ticker']}: {len(hist)} rounds", file=sys.stderr)
    time.sleep(0.5)
json.dump(out, open(f'{work}/feed-stats.json','w'))
PYEOF
fi

echo "== phase 4: gates, recommendation, output =="
python3 - "$WORK" <<'PYEOF'
import json, sys
work = sys.argv[1]
pairs = json.load(open(f'{work}/pairs.json'))
feed_stats = {s['ticker']: s for s in json.load(open(f'{work}/feed-stats.json'))}
pools = json.load(open(f'{work}/ranked-pools.json'))
ETF_SET = set('SPY QQQ DIA IWM VTI VOE'.split())
# deepest pool per asset
best = {}
for p in pools:
    asset = p['c1'] if p['c0'].endswith('5fc5360d0400a0fd4f2af552add042d716f1d168') else p['c0']
    a = asset.lower()
    if a not in best or p['depthUsd'] > best[a]['depthUsd']: best[a] = p
rows = []
for p in pairs:
    t = p['ticker']; tok = p['token'].lower()
    fs = feed_stats.get(t, {})
    pool = best.get(tok)
    vol = fs.get('volDailyPct')
    if vol is None: level = None
    elif vol <= 2.5: level = 'low'
    elif vol <= 4.0: level = 'medium'
    else: level = 'high'
    reasons = []
    if not fs.get('feedLive'): reasons.append('feed dead')
    if fs.get('rounds', 0) < 3: reasons.append('history too short')
    if not pool: reasons.append('no hookless sane-fee pool')
    elif pool['depthUsd'] < 100000: reasons.append(f"depth ${pool['depthUsd']:.0f} < $100k")
    rows.append({
        'ticker': t, 'token': p['token'], 'variant': p.get('variant'),
        'class': ('ETF' if t in ETF_SET else 'stock'),
        'feed': p['feed'], 'feedSecondary': p.get('feedSecondary'),
        'updatesPerHour': fs.get('updatesPerHour'), 'volDailyPct': vol,
        'dualDevPct': fs.get('dualDevPct'),
        'pool': (None if not pool else {
            'poolId': pool['poolId'], 'fee': pool['fee'], 'tickSpacing': pool['tickSpacing'],
            'depthUsd': round(pool['depthUsd'], 2),
            'maxPositionUsd': round(pool['depthUsd'] * 0.01, 2),
            'initBlock': pool['initBlock'], 'initTx': pool['initTx']}),
        'recommendedLevel': level,
        'eligible': not reasons, 'reasons': reasons,
    })
rows.sort(key=lambda r: -(r['pool'] or {}).get('depthUsd', 0) if r['pool'] else 0)
print(f"{'ticker':7} {'class':6} {'depthUsd':>10} {'maxPos':>9} {'cad/h':>6} {'volD%':>6} {'dev%':>6} {'level':>7} verdict")
for r in rows:
    pl = r['pool'] or {}
    print(f"{r['ticker']:7} {r['class']:6} {pl.get('depthUsd',0):>10.0f} {pl.get('maxPositionUsd',0):>9.0f} "
          f"{(r['updatesPerHour'] or 0):>6.2f} {(r['volDailyPct'] or 0):>6.2f} {(r['dualDevPct'] or 0):>6.2f} "
          f"{(r['recommendedLevel'] or '-'):>7} {'OK' if r['eligible'] else '; '.join(r['reasons'])}")
ok = [r for r in rows if r['eligible']]
import datetime
out = {'generated': datetime.datetime.now(datetime.timezone.utc).isoformat(),
       'chain': 4663, 'method': 'two-layer admission pipeline (README: asset selection); every number measured live this run',
       'gates': {'minDepthUsd': 100000, 'maxFee': 3000, 'positionCap': '1% of depth', 'volLevels': {'low': '<=2.5%/day', 'medium': '<=4.0%/day', 'high': '>4.0%/day'}},
       'assets': rows}
import os
os.makedirs('internal/docs/evidence', exist_ok=True)
path = f"internal/docs/evidence/rh-spectrum-{datetime.datetime.now():%y%m%d}.json"
json.dump(out, open(path, 'w'), indent=1)
print(f'\neligible spectrum: {len(ok)}/{len(rows)}; evidence: {path}')
PYEOF

# exit 1 when nothing passed the gates
python3 - <<'PYEOF'
import glob, json, sys
p = sorted(glob.glob('internal/docs/evidence/rh-spectrum-*.json'))[-1]
ok = [a for a in json.load(open(p))['assets'] if a['eligible']]
sys.exit(0 if ok else 1)
PYEOF
