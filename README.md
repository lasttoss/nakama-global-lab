# nakama-global-lab

Running **[Nakama](https://heroiclabs.com/docs/nakama/)** on **[YugabyteDB](https://www.yugabyte.com/)**,
and scaling it by **cells** that share one data plane — with the failure modes reproduced, explained,
and automated.

[![ci](https://github.com/lasttoss/nakama-global-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/lasttoss/nakama-global-lab/actions/workflows/ci.yml)

## What this repo answers

| Question | Answer | Evidence |
|---|---|---|
| Can Nakama run on YugabyteDB? | **Yes**, with a documented workaround | `nakama migrate up` ✗ fails at **migration 1 on a fresh DB (0/5 runs)**; the same SQL via `ysqlsh` ✓ **20/20 (5/5)** — `docs/nakama-with-yugabytedb.md` |
| Do cells share account/storage data? | **Yes** — one device, two cells, same `user_id` | `make smoke` → 11 pass / 0 fail / 1 skip |
| Can a new cell be added with no data migration? | **Yes** — one command, no data moves | `bash scripts/add-cell.sh e` (`docs/scaling-cells.md`) |
| Does local state leak between cells? | **No** — Valkey is per cell by design | smoke step 4 |
| What does a cross-region data plane cost? | **~160× on the hot path** — auth p50 1.5 ms → 242 ms over a symmetric 60 ms WAN | `docs/benchmarks-results.md` |
| How much can one cell take? | **~3.3k auth/s** (knee at concurrency 100, p99 53 ms) and **~4.8k reads/s** (single-node YB) | `docs/benchmarks-results.md` |
| Does the storage side scale? | **yes** — 3-node cluster, replication factor 3: killing one node left writes working **10/10**, and the node rejoined in **1 s** | `docs/yb-3node-lab.md` |
| How long does it hold up? | **10-minute soak at the knee: no degradation** (3 120 req/s, p99 57 ms, 1.87 M requests, 0 errors) | `docs/benchmarks-results.md` |
| What happens when a cell dies? | a cell-list client recovers in **0.08 s** on another cell, **same account**, nothing lost | `docs/benchmarks-results.md` |
| What happens when the data plane dies? | **every cell fails at once** — but no data loss, cells survive, and a cell serves again **1 s** after the plane answers | `docs/benchmarks-results.md` |

## Quickstart

```bash
make fix-perm     # create + chown the YugabyteDB data volume (first run only)
make up           # YB → yb-init (applies the schema) → 2 Nakama cells + 2 Valkey
make smoke        # verifies the shared data plane
make init         # re-run the data-plane init (idempotent: "applied=0 skipped=20")
make down         # stop; `make clean` also removes volumes
```

Expected smoke output:

```
──────── 1. AUTH: cùng device id ở 2 cell → cùng account?
   PASS ✓ ACCOUNT DÙNG CHUNG ✓ (cùng user_id ở 2 cell)
──────── 2. STORAGE: ghi ở A → đọc ở B?
   PASS ✓ STORAGE DÙNG CHUNG ✓ (cell B đọc thấy dữ liệu ghi từ cell A)
──────── 4. VALKEY per-cell: có share không? (kỳ vọng: KHÔNG)
   PASS ✓ VALKEY KHÔNG SHARE ✓ (đúng: state cục bộ)
   PASS=11  FAIL=0  SKIP=1
```

## 1. Nakama + YugabyteDB

`nakama migrate up` **cannot initialise a database on YugabyteDB**: on a fresh database it fails at
the *first* of 20 files (0/5 runs applied anything, `SQLSTATE 40001`), while the **same 20 SQL files**
apply cleanly through `ysqlsh` (20/20, 5/5 runs). The mechanism is **reproduced in 3 statements
without Nakama** — see [`repro/`](repro/README.md): the same statements inside one transaction fail
10/10 at `COMMIT`; outside a transaction they pass 10/10. So the blocker is how the statements are
executed, not the SQL and not YB's SQL layer.

This repo applies the schema itself and seeds Nakama's `migration_info` bookkeeping table, wired as a
real compose **init service** (`yb-init`) that both cells wait on. Full write-up, including why
`read committed` makes it fail even earlier and how to upgrade safely:
**[`docs/nakama-with-yugabytedb.md`](docs/nakama-with-yugabytedb.md)**

## 2. Scaling by cells

A cell is a stateless Nakama node plus its own Valkey; cells share one data plane. Adding capacity
means adding cells — nothing to migrate, because no cell owns data:

```bash
bash scripts/add-cell.sh e 20550 20551 20580
#   cell 'e' HTTP 200 ✓
#   cell A     user_id=5ee9a88c-56e6-4c1f-ae0b-af9b9ad7ac85
#   cell 'e'   user_id=5ee9a88c-56e6-4c1f-ae0b-af9b9ad7ac85
#   ✓ ACCOUNT DÙNG CHUNG — cell 'e' đã vào đúng data plane
```

Model, routing options, what is shared vs local, and the two traps (single writer per account row;
a leaderboard is not idempotent under replication):
**[`docs/scaling-cells.md`](docs/scaling-cells.md)**

## Layout

```
repro/                      # 3-statement minimal reproduction + self-checking runner (no Nakama needed)
docker-compose.yml          # YugabyteDB + yb-init + 2 cells + 2 Valkey   (main stack)
docker-compose.crdb.yml     # same topology on CockroachDB, using `nakama migrate up` (it works there)
docker-compose.cell.yml     # template for adding one more cell
docker-compose.yb3.yml      # 3-node YugabyteDB cluster, replication factor 3 (storage-side scaling)
repro/                      # 4-line reproduction of the migration blocker + controls
scripts/yb3-init.sh         # apply the 20 migrations to the 3-node cluster
scripts/yb3-kill-test.sh    # kill a node, prove writes continue, let it rejoin
scripts/bench-load.go       # goroutine load generator (throughput ceiling, soak)
scripts/yb-init.sh          # applies pinned migrations with ysqlsh + seeds migration_info (idempotent)
scripts/add-cell.sh         # add a cell and prove it shares the data plane
scripts/smoke.sh            # cross-cell verification (auth / storage / leaderboard / Valkey isolation)
scripts/leaderboard-trap.sh # demonstrates the ZINCRBY double-count trap
yb-migrations/              # 20 migration files pinned to Nakama v3.41.0 + checksums
docs/                       # findings, scaling model, self-hosting runbook
```

## Why CockroachDB is also in here

CockroachDB is the control case: `nakama migrate up` completes **20/20** there, so it isolates the
YugabyteDB issue and proves the topology is not the problem. Different trade-offs (license, ops,
ecosystem) are a separate decision and are deliberately **not** part of this repo.

## Benchmarks

Cell ↔ data-plane latency is **measured**, by injecting netem delay on the cell→database leg only:
[`docs/benchmarks-results.md`](docs/benchmarks-results.md) (re-runnable via `bash scripts/bench-latency.sh`).
Headline: the injected delay shows up as **1 / 2 / 3 data-plane round trips** for storage GET / auth /
storage PUT — so those API paths are 1–3 WAN round trips away from answering. The same file also holds
throughput with and without delay, and cell-death recovery (0.08 s failover to another cell).

## Not measured yet (honest list)

- **A real cross-region deployment** — delay was injected on one machine; no multi-region cluster was run.
- **Multi-hour soak** — a 10-minute steady soak is in `docs/benchmarks-results.md`; hours-long
  behaviour (leaks, index bloat, tablet splits) is still untested.
- **Multi-hour behaviour** — the soak above is 10 minutes; hours-long runs (leaks, index bloat,
  tablet splits) are untested. Self-hosting notes for real machines:
  [`docs/selfhost-3node-ubuntu.md`](docs/selfhost-3node-ubuntu.md).
- Leaderboard writes through the client API: creating a board needs a Nakama **runtime RPC**, so the
  smoke test skips that step instead of faking a pass (see `scripts/smoke.sh`).

## Notes in Vietnamese

Working notes kept as-is: [`docs/measurements.md`](docs/measurements.md),
[`docs/yugabyte-workaround.md`](docs/yugabyte-workaround.md),
[`docs/selfhost-3node-ubuntu.md`](docs/selfhost-3node-ubuntu.md).

## License & provenance

MIT for this repo — see [`LICENSE`](LICENSE) and [`PROVENANCE.md`](PROVENANCE.md).
The 20 files in `yb-migrations/` are copied verbatim from `heroiclabs/nakama` (tag `v3.41.0`) and
remain **Apache-2.0**; see [`yb-migrations/README.md`](yb-migrations/README.md).
