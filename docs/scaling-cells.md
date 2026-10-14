# Scaling Nakama by cells

## The model

A **cell** is one stateless Nakama node (plus its own Valkey). Cells share a **single data plane**
(YugabyteDB here). Adding capacity = adding cells; there is no data to move, because no cell owns data.

```
                       ┌──────────────────────────┐
        cell A ───────▶│                          │◀─────── cell B
   nakama + valkey     │   data plane (YugabyteDB)│    nakama + valkey
                       │   accounts · storage ·   │
        cell E ───────▶│   leaderboards · wallet  │◀─────── cell N … (add anytime)
   nakama + valkey     └──────────────────────────┘    nakama + valkey
```

## What is shared, what is local

| Data | Where | Why |
|---|---|---|
| account, storage objects, wallet, leaderboards | **shared data plane** | a player must keep them while roaming between cells |
| match/relay state, session cache, per-cell ephemeral keys | **local Valkey per cell** | it is latency-sensitive and meaningless outside the cell |
| telemetry / per-cell metrics | **local** (ship elsewhere) | it is the only data whose volume multiplies by cell count |

Design rule of thumb: **replicate the small, valuable layer; never replicate the high-volume
derived layer**. Cache is not shared between cells — a miss falls back to the data plane.

## Add a cell (one command)

```bash
bash scripts/add-cell.sh e 20550 20551 20580     # id, API port, console port, valkey port
```

It brings up a new Nakama + Valkey pair joined to the existing data-plane network, waits for
health, then **proves** the new cell uses the same data plane by authenticating the same device
on cell A and on the new cell and comparing `user_id`.

Real output from this lab (cell E):

```
== waiting for cell 'e' to answer ==
   cell 'e' HTTP 200 ✓
== proof: same account on cell A and cell 'e'? ==
   cell A       user_id=5ee9a88c-56e6-4c1f-ae0b-af9b9ad7ac85
   cell 'e'     user_id=5ee9a88c-56e6-4c1f-ae0b-af9b9ad7ac85
   ✓ ACCOUNT IS SHARED — cell 'e' joined the right data plane
```

Remove a cell — **no data migration**, because the cell owned no data:

```bash
docker compose -p nkglobal-cell-e -f docker-compose.cell.yml down
```

## Routing players to the nearest cell

Nakama does not do client geo-routing itself; that is one layer above:

1. publish a per-region endpoint list to the client (`GET /regions` on a tiny service, or a CDN-cached
   JSON file) and let the client pick by measured ping — cheapest and most accurate;
2. or GeoDNS/anycast in front of the cells (the client hits one hostname);
3. health-check the cells and drop unhealthy ones from the list.

Keep the credential/account layer in the shared data plane, so a client that lands on the *wrong*
cell still works — it just has worse latency, which is exactly the trade-off that cell + shared
data plane buys you (availability and roaming over perfect placement).

## What cell redundancy does *not* cover

Adding cells protects against **a cell** failing; it does nothing about the shared data plane, which is
a single dependency for every cell at once. Measured (`docs/benchmarks-results.md`):

| Outage | Effect | Recovery |
|---|---|---|
| one cell killed | that cell's clients fail; others unaffected | a cell-list client served by another cell in **0.08 s** |
| data plane paused (stall) | **all** cells fail (4/4 requests) | instant once the plane answers; no cell restart needed |
| data plane stopped | **all** cells fail | YB back in 5–6 s, cells serving **1 s** later |

No data was lost in any of these modes, and the cells never exited. Budget for this honestly: cells buy
you *capacity and cell-level fault tolerance*, not resilience to the database. If the data plane must
survive losing a region, that is a different (and more expensive) design — the trade-off is spelled out
in `docs/nakama-with-yugabytedb.md` and the scaling notes.

## Two traps worth knowing

1. **A player's account row must have a single writer.** Roaming means "read anywhere, write at the
   place the player actually is". Do not run two cells writing the same row concurrently through
   an eventually-consistent replica.
2. **A leaderboard is not idempotent under replication.** `ZINCRBY` applied twice scores double.
   A global board needs a single owner per board (or shard + merge). Verification script:
   `bash scripts/leaderboard-trap.sh`.

## Not measured yet (honest list)

- cross-region latency: this lab runs every cell on one machine, so latency numbers from it would be
  meaningless. The planned method is `tc netem` on the cell↔data-plane link plus client-observed
  round trips; see `docs/benchmarks.md`.
- behaviour under a 3-node YugabyteDB with replication factor 3 (this lab runs single-node YB).
