# Benchmark results — cell ↔ data plane latency

**Run:** 2026-10-14 · one machine, all containers local · Node `N=100` per case, sequential, single client
**Versions:** Nakama 3.41.0 · YugabyteDB 2026.1.2.0-b137 (single node) · Valkey 8 · Docker Compose v2
**Script:** `scripts/bench-latency.sh` (re-runnable) · **Method:** [`docs/benchmarks.md`](benchmarks.md)

## What was done

Delay was injected **only on the cell→data-plane leg** (a `tc`/netem filter matching the YugabyteDB
container IP, so the client→cell hop and the per-cell Valkey stay untouched). A dedicated cell with
`NET_ADMIN` was used (`bench-latency.sh --setup`), so the running lab was not modified.

## Results (milliseconds)

| API call | baseline p50 | netem 60 ms 1-way | netem 120 ms 1-way |
|---|---|---|---|
| `POST /v2/account/authenticate/device` | 1.5 | **122.2** | **242.3** |
| `PUT /v2/storage` | 2.1 | **182.2** | **362.2** |
| `GET /v2/storage/{collection}` | 1.3 | **61.7** | **121.8** |

p95 stayed within a few ms of p50 in every case (e.g. 120 ms run: auth 244.5, PUT 363.4, GET 122.7) —
the injected delay dominates, so the client-side spread is small.

## Interpretation — the numbers are exactly linear, and that is the useful part

Each injected one-way delay `D` adds `k × D`:

| API call | k (data-plane round trips) | 60 ms | 120 ms |
|---|---|---|---|
| storage GET | **1** | 61.7 ≈ 1×60 | 121.8 ≈ 2×60 |
| authenticate | **2** | 122.2 ≈ 2×60 | 242.3 ≈ 4×60 |
| storage PUT | **3** | 182.2 ≈ 3×60 | 362.2 ≈ 6×60 |

So a single measurement of one API call tells you **how many synchronous data-plane round trips it
costs** — 1 for a read, 2 for auth, 3 for a write. That is a property of the code path, not of the
network, and it is what makes the network distance expensive:

> **A symmetric 60 ms WAN link (roughly US ↔ EU) costs one data-plane round trip 120 ms.**
> Auth then takes ~242 ms p50; a storage write ~362 ms p50 — against 1.5 ms and 2.1 ms on a local
> data plane. Same code, same database, ~160× the latency, purely from placement.

## What this means for design

1. **Keep the write path in-region.** A storage write is 3 round trips; making it cross-region
   multiplies the worst case by ~3 × RTT. Reads (1 round trip) tolerate distance far better than
   writes.
2. **Avoid a cross-region data plane for session-critical calls.** Any call on the login/join path
   inherits 2–3 × RTT before anything else happens.
3. **Per-cell Valkey earns its place.** Local state is served without touching the data plane at all —
   the reason it must stay per-cell (and the reason it must not hold anything that has to survive
   a cell dying).

## Limitations (so these numbers are not over-read)

- Injected delay is **one-way only** (the YugabyteDB container has no `tc`, and the host has no
  passwordless `sudo`). A symmetric WAN adds the same delay on the return leg, so **double the deltas**
  for a real cross-region hop — which is exactly why the 120 ms column is shown: it is the equivalent
  of a symmetric 60 ms link.
- **Sequential single client**, no concurrency: these are latencies, not throughput. No req/s claim is made.
- Not measured: connection-pool warming, retries, and behaviour when the data plane is *briefly*
  unavailable (see `docs/benchmarks.md`, items 4–5).
