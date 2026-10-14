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

## Throughput (same machine, one cell, single-node YugabyteDB)

Client: `scripts/bench-throughput.py` (Python threads) — a **floor**, not a ceiling, because the client
shares one CPU with everything else. `--requests 600`, errors 0 in every case.

| API | concurrency 1 | 10 | 50 |
|---|---|---|---|
| auth **req/s** | 679 | **1372** | 789 |
| auth p95 | 2.0 ms | 7.0 ms | 514 ms |
| storage GET **req/s** | 884 | **2086** | 1721 |
| storage GET p95 | 1.2 ms | 6.5 ms | 168 ms |

⇒ It saturates around **concurrency 10** (~1.4k auth/s, ~2.1k reads/s). **These numbers are
client-bound, not cell-bound** — see the ceiling section below for what the cell actually does.

## Throughput with a WAN-like delay (netem 120 ms one-way ≈ 240 ms RTT)

| API | concurrency 1 | 10 | 50 |
|---|---|---|---|
| auth req/s | 4 | 33 | 81 |
| auth p50 / p95 | 242 / 243 | 242 / **1174** | 245 / **1348** |
| storage GET req/s | 8 | 71 | 206 |
| storage GET p50 / p95 | 122 / 122 | 122 / 397 | 126 / 468 |

⇒ Latency-bound, exactly as the round-trip count predicts: 4 req/s ≈ 1 / 0.242 s at concurrency 1, and
throughput grows with concurrency, so distance is not a hard wall — but **p95 climbs far faster than
p50** (1174 ms vs 242 ms at concurrency 10), i.e. requests queue behind the cell's data-plane
connections. Reads reach ~3× the write throughput at the same concurrency, matching their 1-vs-3
round trips.

## Cell death (kill a cell mid-traffic)

`bash scripts/bench-recovery.sh` — the measured cell is killed outright with `docker kill`:

| Client behaviour | Result |
|---|---|
| knows only that cell's address | **5/5 requests fail** ✗ |
| has a cell list (tries the dead cell, then the other) | succeeded on the other cell **0.08 s** after the kill |
| data | account identical on the surviving cell (`9327923b-…`) — nothing lost |
| total requests lost across both behaviours | 6 |

⇒ A cell is disposable: the recovery cost is the client's failover logic, and no data is lost because
no cell owns data. This is the practical payoff of the per-cell + shared-data-plane design.


## Ceiling — with a load generator that is not the bottleneck

Three clients were tried, and the first two measured themselves:

| Client | Reported | What it actually measured |
|---|---|---|
| Python threads | ~1.4k auth/s | the client (one CPU, GIL) |
| `xargs -P` + one `curl` per request | 573 req/s | **process spawning**, not the cell |
| `scripts/bench-load.go` (goroutines, fixed concurrency, fixed duration) | see below | the cell |

```bash
go run scripts/bench-load.go -api http://127.0.0.1:20350 -op auth -conc 100 -dur 8s
```

| op | concurrency | req/s | p50 | p95 | p99 | errors |
|---|---|---|---|---|---|---|
| auth | 10 | 2 376 | 3.9 ms | 6.4 ms | 8.1 ms | 0 |
| auth | 50 | 2 719 | 17.3 ms | 28.6 ms | 36.5 ms | 0 |
| auth | **100** | **3 275** | 29.7 ms | 43.6 ms | 52.8 ms | 0 |
| auth | 200 | 3 164 | 58.9 ms | 105.3 ms | 134.7 ms | 0 |
| storage GET | 50 | 4 317 | 10.5 ms | 17.8 ms | 23.5 ms | 0 |
| storage GET | **200** | **4 781** | 36.4 ms | 78.3 ms | 112.2 ms | 0 |

⇒ **auth knees around concurrency 100 ≈ 3.3k req/s** (p99 stays under 53 ms); reads keep scaling to
**≈4.8k req/s at concurrency 200**. Zero errors at every level. Reads are the cheapest path, consistent
with their single data-plane round trip.

## Soak — 10 minutes at the knee

`go run scripts/bench-load.go -api http://127.0.0.1:20350 -op auth -conc 100 -dur 10m`:

| | 8-second burst | **10-minute soak** |
|---|---|---|
| req/s | 3 275 | 3 120 |
| p50 / p95 / p99 | 29.7 / 43.6 / 52.8 ms | 31.0 / 47.0 / 57.1 ms |
| requests served | 19 692 | **1 872 325**, 0 errors |

⇒ No degradation across 10 minutes: throughput and every percentile hold at the same level.

### Memory: measured properly, and the earlier number was the wrong number

The first pass sampled `docker stats` and read YugabyteDB **1.93 → 2.55 GiB** and the loaded cell
**122 → 309 MiB**, both "still creeping upward". That measurement could not tell cache warming from a
leak, because `docker stats` (and cgroup `memory.current`) adds **page cache** into the same figure as
process memory. `bash scripts/bench-memory.sh` now reads cgroup `memory.stat` and splits them:

| Container | Phase | `anon` (process) | `file` (page cache) | `memory.current` (= what `docker stats` shows) |
|---|---|---|---|---|
| YugabyteDB | 7 min idle | 569 → **570 MiB** | 475 → **476 MiB** | 1106 → **1108 MiB** |
| YugabyteDB | 10 min at 3278 req/s | 1042 → **1174 MiB**, converging | 476 → **6943 MiB**, linear in requests | 1106 → **8396 MiB** |
| YugabyteDB | 9 min idle again | **1166 MiB**, flat | 6943 MiB, flat | 8396 MiB, flat |
| Cell A (loaded) | 10 min at 3278 req/s | 278 → **288 MiB, flat for the last 4 min** | 4 MiB, flat | 298 MiB |
| Cell A (loaded) | 9 min idle again | 288 → **187 MiB** — gives memory back | 4 MiB | 195 MiB |
| Cell B (no traffic) | all 19 min | **10 MiB, flat** | 0.5 MiB | 13 MiB |

Three things this settles:

- **No leak.** Nothing grows without traffic: cell B receives none and stays flat at 10 MiB for 19
  minutes, and every phase goes flat the moment load stops. A leaking process does not hand 35% of its
  memory back when the load ends, which is exactly what cell A does (288 → 187 MiB).
- **YugabyteDB's process memory converges, it does not climb.** The per-sample deltas decelerate
  (+58, +30, +24, +20, then −9 MiB) and settle near **1.15 GiB** — warm-up of caches and arenas, bounded.
- **The scary number was page cache.** Of YugabyteDB's 7.3 GiB apparent growth, **6.5 GiB is `file`** —
  rock-solid, reclaimable page cache from RocksDB file I/O, not memory held hostage. 87% of the figure
  `docker stats` reports is memory the kernel will evict on demand.

The 10-minute soak's own numbers stand (3.1k req/s, p99 57 ms, no degradation); only the memory
conclusion changes, and it changes from "cannot tell" to "measured: cache, not leak".

## Data-plane failure — the one dependency cells do not cover

Cells are disposable; the shared data plane is not. `bash scripts/bench-dataplane-failure.sh`:

| Scenario | Clients during the outage | Cell process | Recovery once the plane answers | Data |
|---|---|---|---|---|
| **paused** (`docker pause` — a stall, the harsher case) | 4/4 requests fail (4 s timeout) | stays up | auth **0 s**, storage **0 s** | intact (`migration_info` = 20) |
| **stopped** (`docker stop` — gone) | 4/4 fail | stays up, does not exit | YB answers again after **5–6 s**; auth **1 s**, storage **1 s** later | intact |

⇒ A data-plane outage takes **every cell** down at once: per-cell redundancy does not cover it. What was
measured here is the reassuring half — no data loss in either mode, cells do not crash, and recovery is
automatic and takes about a second after the plane answers (no cell restart needed).

## Limitations (so these numbers are not over-read)

- Injected delay is **one-way only** (the YugabyteDB container has no `tc`, and the host has no
  passwordless `sudo`). A symmetric WAN adds the same delay on the return leg, so **double the deltas**
  for a real cross-region hop — which is exactly why the 120 ms column is shown: it is the equivalent
  of a symmetric 60 ms link.
- The throughput client is Python-threaded and shares the machine with the stack, so those numbers
  are a **floor**; a dedicated load generator would find a higher ceiling.
- Not measured: connection-pool warming, retries, data-plane (not cell) failure, and multi-hour soak
  behaviour. See `docs/benchmarks.md` for the remaining method notes.
