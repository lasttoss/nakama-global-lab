#!/usr/bin/env python3
"""Measure throughput + latency across concurrency levels for one Nakama cell.

  python3 scripts/bench-throughput.py --api http://127.0.0.1:20850 --requests 600 --concurrency 1,10,50

No external libraries. Each concurrency level runs in sequence; prints req/s, p50/p95, error rate.
"""
import argparse, json, statistics, threading, time, urllib.request, urllib.error, base64

def call(url, method, body=None, bearer=None, server_key="defaultkey"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {bearer}" if bearer else
                   "Basic " + base64.b64encode(f"{server_key}:".encode()).decode())
    if data: req.add_header("Content-Type", "application/json")
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            r.read(); return time.perf_counter() - t0, None
    except urllib.error.HTTPError as e:
        return time.perf_counter() - t0, f"HTTP {e.code}"
    except Exception as e:                                  # noqa: BLE001
        return time.perf_counter() - t0, type(e).__name__

def measure(api, kind, n, conc):
    lat, errs, lock = [], {}, threading.Lock()
    def worker(count):
        for _ in range(count):
            if kind == "auth":
                dt, err = call(f"{api}/v2/account/authenticate/device?create=true", "POST",
                               {"id": "bench-throughput-device"})
            else:
                dt, err = call(f"{api}/v2/storage/bench?user_id={DEVICE_UID}", "GET", bearer=TOKEN)
            with lock:
                if err: errs[err] = errs.get(err, 0) + 1
                else: lat.append(dt)
    per = n // conc
    ts = [threading.Thread(target=worker, args=(per,)) for _ in range(conc)]
    t0 = time.perf_counter()
    for t in ts: t.start()
    for t in ts: t.join()
    wall = time.perf_counter() - t0
    done = per * conc
    lat.sort()
    p = lambda q: lat[min(len(lat) - 1, int(round(q * (len(lat) - 1))))] * 1000 if lat else float("nan")
    return dict(kind=kind, conc=conc, wall=wall, done=done, errs=sum(errs.values()),
                err_kinds=", ".join(f"{k}×{v}" for k, v in sorted(errs.items())),
                rps=done / wall if wall else 0, p50=p(.5), p95=p(.95))

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://127.0.0.1:20350")
    ap.add_argument("--requests", type=int, default=600)
    ap.add_argument("--concurrency", default="1,10,50")
    ap.add_argument("--only", choices=["auth", "get", "both"], default="both")
    ap.add_argument("--settle", type=float, default=3.0, help="pause between levels (seconds)")
    a = ap.parse_args()

    _, err = call(f"{a.api}/v2/account/authenticate/device?create=true", "POST",
                  {"id": "bench-throughput-device"})
    if err: raise SystemExit(f"cell did not answer: {err}")
    import re
    req = urllib.request.Request(f"{a.api}/v2/account/authenticate/device?create=true", method="POST",
                                 data=b'{"id":"bench-throughput-device"}')
    req.add_header("Authorization", "Basic " + base64.b64encode(b"defaultkey:").decode())
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as r:
        TOKEN = json.load(r)["token"]
    req = urllib.request.Request(f"{a.api}/v2/account", headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req) as r:
        DEVICE_UID = json.load(r)["user"]["id"]

    print(f"cell={a.api}  requests/level={a.requests}")
    print(f"{'operation':<10} {'concurrency':>11} {'req/s':>9} {'p50(ms)':>9} {'p95(ms)':>9} {'errors':>7}")
    kinds = {"auth": ["auth"], "get": ["storage GET"], "both": ["auth", "storage GET"]}[a.only]
    for kind in kinds:
        for c in [int(x) for x in a.concurrency.split(",")]:
            m = measure(a.api, "auth" if kind == "auth" else "get", a.requests, c)
            print(f"{kind:<10} {c:>9} {m['rps']:>9.0f} {m['p50']:>9.1f} {m['p95']:>9.1f} "
                  f"{m['errs']:>5}  {m['err_kinds']}")
            time.sleep(a.settle)
