# Benchmarks — method (not yet run)

This file fixes the method so numbers are produced and trusted. **Items 1–5 have been run** — see [`docs/benchmarks-results.md`](benchmarks-results.md):
cell↔data-plane latency (1/2/3 data-plane round trips per read/auth/write, measured with netem),
throughput with and without delay, and cell-death recovery. Also run: **throughput ceiling** with a
goroutine load generator (3.3k auth/s, 4.8k reads/s), a **10-minute soak** (no degradation), and
**data-plane failure** (pause and stop).
**Still not measured:** a real cross-region deployment and multi-hour soak behaviour.

## What to measure

| # | Metric | How |
|---|---|---|
| 1 | Auth round trip, p50/p95/p99 | N=1000 sequential `POST /v2/account/authenticate/device`, per cell |
| 2 | Storage write / read p50/p95 | 1000 objects × (`PUT /v2/storage`, `GET /v2/storage/{collection}`) |
| 3 | Cell→data-plane link latency | `tc netem` delay on the cell's egress, then repeat 1–2 |
| 4 | Throughput ceiling | ramped workers (k6/artillery), report req/s at p95 < 27 ms and error rate |
| 5 | Cell failure recovery | kill cell A mid-ramp: time until clients reconnect to cell B, error count |
| 6 | Cost per 1k CCU-hour | node counts × cloud list prices, stated with the region and date |
| 7 | Data-plane outage | `docker pause` (stall) and `docker stop`, measuring client errors, cell survival, recovery time, data integrity |

## The cross-region part (the only number that decides the architecture)

Simulate distance instead of renting it — inject the RTT a cell would see towards a distant data plane:

```bash
# on the cell's egress (inside the nakama container namespace)
tc qdisc add dev eth0 root netem delay 60ms     # ~ one-way 60ms ≈ 120ms RTT ≈ US↔EU
# and for a same-region control run
tc qdisc del dev eth0 root 2>/dev/null
```

Then repeat measurements 1–4 and report the **delta**, not the absolute values. That delta is what a
player pays when their account write lands in another region — and it is the number that justifies or
kills a shared data plane.

## Rules for publishing numbers here

1. State the machine, region, container versions, method, and sample size — every time.
2. Report p50 **and** p95; single "average" numbers are not accepted in this repo.
3. Never compare runs with different client hardware unless the difference is the point.
4. If a number could not be produced, say so here instead of estimating it.
