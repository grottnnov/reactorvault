#!/usr/bin/env bash
# feed-registry.sh — the guard's price-feed telephone book (25.11).
#
# WHAT: joins two OFFICIAL sources into one registry:
#   1. Chainlink Reference Data Directory (the machine-readable source
#      the docs page itself renders from — found in the docs repo):
#      feeds-robinhood-mainnet.json — proxy addresses, 24/5 and 24/7
#      variants per ticker;
#   2. Robinhood REST asset registry (public, no account):
#      api.robinhood.com/rhj/assets — token addresses, multipliers.
# Then LIVE-VERIFIES every joined pair on chain 4663: the token's
# symbol must equal the ticker (the USDC-was-LINK lesson: never trust
# an address without asking the chain), the feed's description must
# name the ticker, the answer must be positive. Cadence (updates per
# hour) is measured by walking the feed's own round history for the
# DEMO_TICKERS — the K8 number:
# feed hunger is counted BEFORE any subscription is armed.
# NO third-party datasets (hood20 license discipline).
#
# OUTPUT: internal/docs/evidence/feed-registry-<date>.json (public
# data only: addresses, prices, cadence) + a summary on stdout.
# EXIT: 0 = at least one verified pair and zero failed verifications;
# 1 = a chosen pair failed the live check (STOP — do not subscribe).
#
# Usage: script/feed-registry.sh   (read-only: HTTP GETs + eth_calls)
set -euo pipefail
export PATH="$PATH:${HOME:-/root}/.foundry/bin"
cd "$(dirname "$0")/.."

RPC_RH=${RH_RPC:-https://rpc.mainnet.chain.robinhood.com}
RDD_URL="https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json"
RHJ_URL="https://api.robinhood.com/rhj/assets"
DEMO_TICKERS=${DEMO_TICKERS:-"TSLA,NVDA,AAPL"}
OUT="internal/docs/evidence/feed-registry-$(date -u +%y%m%d).json"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -sL "$RDD_URL" -o "$WORK/rdd.json"
curl -sL "$RHJ_URL" -o "$WORK/rhj.json"
echo "sources: rdd=$(wc -c < "$WORK/rdd.json")B rhj=$(wc -c < "$WORK/rhj.json")B"

# Join + parse (python: no jq dependency; the sensor already uses it).
python3 - "$WORK" "$RPC_RH" "$DEMO_TICKERS" <<'PYEOF'
import json, subprocess, sys, datetime

work, rpc, demo = sys.argv[1], sys.argv[2], [t.strip() for t in sys.argv[3].split(",")]

def cast(*args, default=None):
    r = subprocess.run(["cast"] + list(args) + ["--rpc-url", rpc],
                       capture_output=True, text=True, timeout=60)
    return r.stdout.strip() if r.returncode == 0 else default

rdd = json.load(open(f"{work}/rdd.json"))
rhj = json.load(open(f"{work}/rhj.json"))["assets"]

# RHJ tokens on 4663: ticker → token address (+ multiplier info)
tokens = {}
for a in rhj:
    for dep in a.get("deployments", []):
        if dep.get("chainId") == 4663:
            tokens[a["tokenSymbol"]] = {"token": dep["contractAddress"],
                                        "multiplier": a.get("currentMultiplier", "")}

# RDD feeds: "Robinhood <TICKER> / USD" (24/5) and "Robinhood <TICKER> (24/7)"
feeds = {}  # ticker → list of {variant, proxy, secondary}
for e in rdd:
    name = e.get("name", "")
    if not name.startswith("Robinhood "):
        continue  # crypto feeds without Robinhood tokens
    rest = name[len("Robinhood "):]
    if rest.endswith(" (24/7)"):
        feeds.setdefault(rest[:-6].strip(), []).append(
            {"variant": "24/7", "proxy": e.get("proxyAddress"),
             "secondary": e.get("secondaryProxyAddress")})
    elif " / USD" in rest:
        feeds.setdefault(rest.split(" / USD")[0].strip(), []).append(
            {"variant": "24/5", "proxy": e.get("proxyAddress"),
             "secondary": e.get("secondaryProxyAddress")})
    elif rest.endswith("-USD"):
        feeds.setdefault(rest[:-4].strip(), []).append(
            {"variant": "24/5", "proxy": e.get("proxyAddress"),
             "secondary": e.get("secondaryProxyAddress")})

now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
registry, failed = [], []
for ticker, variants in sorted(feeds.items()):
    # prefer the 24/7 variant: the guard keeps watching on weekends
    pick = next((v for v in variants if v["variant"] == "24/7"), variants[0])
    tok = tokens.get(ticker)
    rec = {"ticker": ticker, "variant": pick["variant"], "feed": pick["proxy"],
           "feedSecondary": pick.get("secondary"), "token": tok["token"] if tok else None,
           "multiplier": tok["multiplier"] if tok else None}
    if not tok:
        rec["error"] = "no RHJ token on 4663"
        registry.append(rec)
        continue
    # live verification: token symbol, feed description, feed answer
    sym = cast("call", rec["token"], "symbol()(string)")
    desc = cast("call", rec["feed"], "description()(string)")
    rnd = cast("call", rec["feed"], "latestRoundData()(uint80,int256,uint256,uint256,uint80)")
    rec["verified"] = False
    problems = []
    if sym != f'"{ticker}"':
        problems.append(f"symbol={sym}")
    if not (desc and ticker in desc):
        problems.append(f"description={desc}")
    if rnd:
        parts = [p.strip().split(" ")[0] for p in rnd.split("\n")]
        answer, updated = int(parts[1]), int(parts[3])
        rec["answer"] = answer
        rec["updatedAt"] = updated
        rec["ageSeconds"] = max(0, now - updated)
        if answer <= 0:
            problems.append("answer<=0")
    else:
        problems.append("latestRoundData failed")
    if problems:
        rec["error"] = "; ".join(problems)
        failed.append(ticker)
    else:
        rec["verified"] = True
    registry.append(rec)

# cadence for the demo tickers (K8: count the hunger BEFORE subscribing).
# The 4663 RPC eth_getLogs with an address filter silently returns empty
# (measured 25.11 — the Lasna lesson inverted: there topic0 was broken,
# here the ADDRESS filter is), and Blockscout sits behind a JS challenge.
# The feeds themselves keep the count: roundIds are per-update counters,
# each round carries its updatedAt — walk back from the latest round
# while it is younger than one hour. One eth_call per round.
for rec in registry:
    if rec.get("ticker") in demo and rec.get("feed"):
        rnd = cast("call", rec["feed"], "latestRoundData()(uint80,int256,uint256,uint256,uint80)")
        if not rnd:
            continue
        parts = [x.strip().split(" ")[0] for x in rnd.split("\n")]
        rid, updated = int(parts[0]), int(parts[3])
        count = 1 if updated >= now - 3600 else 0
        while count < 300:
            rid -= 1
            step = cast("call", rec["feed"], f"getRoundData(uint80)({rid})")
            if not step:
                break
            sp = [x.strip().split(" ")[0] for x in step.split("\n")]
            if int(sp[3]) < now - 3600:
                break
            count += 1
        rec["updatesPerHour"] = count

out = {
    "generatedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "chain": 4663,
    "rpc": rpc,
    "sources": {
        "rdd": "reference-data-directory.vercel.app/feeds-robinhood-mainnet.json (official Chainlink RDD — the docs page renders from it)",
        "rhj": "api.robinhood.com/rhj/assets (official Robinhood registry, 205 assets on 4663)",
    },
    "note": "feed price already includes the corporate-action multiplier (docs: Total Return Value); the guard math never applies it twice",
    "pairs": registry,
}
path = "internal/docs/evidence/feed-registry-%s.json" % datetime.datetime.now(datetime.timezone.utc).strftime("%y%m%d")
json.dump(out, open(path, "w"), indent=1)

ok = [r for r in registry if r.get("verified")]
print(f"joined pairs: {len(registry)}  verified: {len(ok)}  failed: {len(failed)}")
for r in ok:
    extra = f" age={r['ageSeconds']}s" if "ageSeconds" in r else ""
    cad = f" cadence={r['updatesPerHour']}/h" if "updatesPerHour" in r else ""
    print(f"  {r['ticker']:6} {r['variant']:4} feed={r['feed']} answer={r.get('answer')}{extra}{cad}")
if failed:
    print("FAILED VERIFICATIONS (do NOT subscribe):")
    for r in registry:
        if r.get("error"):
            print(f"  {r['ticker']:6} {r['error']}")
    sys.exit(1)
print(f"evidence: {path}")
PYEOF

[ -d internal/docs/evidence ] || mkdir -p internal/docs/evidence
echo "registry written: $OUT (if the python step renamed it by UTC date, trust that file)"
