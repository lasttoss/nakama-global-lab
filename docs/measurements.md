> ⚠️ **CORRECTION 2026-10-14** — the older numbers in this file ("dies at 16/20, file `console-fine-grained-acl`, `SQLSTATE 42703`") **do not reproduce** ✗.
> Measured again on a fresh database: `nakama migrate up` **fails at file #1 (0/5 runs)**, `SQLSTATE 40001`, at **COMMIT**;
> that same file applied **statement by statement** succeeds 10/10, and applied inside **one transaction** fails 10/10.
> A 3-statement repro with no Nakama needed: `repro/`. The correct conclusion: `docs/nakama-with-yugabytedb.md`.

# Measurements — nakama-global-lab (2026-10-13)

Machine: 12 vCPU / 31 GB RAM · Docker 29.1.3 · Ubuntu 24.04 · **everything on one machine** ⇒ the latency here is
**not** representative of real cross-region latency ✗. The goal was to prove **right or wrong**, not to map geography.

Versions: **YugabyteDB 2026.1.2.0-b137** (`yugabytedb/yugabyte:2026.1.2.0-b137`) ·
**Nakama 3.41.0** · **Valkey 8-alpine**.

## Result 1 — "Nakama runs on YB" ⇒ **NO** (it is not a drop-in)

`nakama migrate up` **stops at migration 16/20**, creates **17 tables** (`leaderboard`, `storage`,
`leaderboard_record`, `migration_info`, `console_user`, `groups`, …) and then dies ✗:

| isolation tried | result |
|---|---|
| **READ COMMITTED** (what YB docs recommend for apps that do not retry) | ✗ **dies at the very first schema file** (`20180103142001_initial_schema.sql`) |
| **SERIALIZABLE** | ✓ gets through **16 migrations**, then ✗ dies at `20250926112031-console-fine-grained-acl.sql` |

Those two failures are of different kinds:

1. **SQLSTATE 40001** — `current transaction is expired or aborted (query layer retry isn't possible
   because this is not the first command in the transaction. Consider using READ COMMITTED isolation
   level.)` ⇒ Nakama sends **several statements in one transaction** ✗; YB can auto-retry only when the failing
   statement is the **first one** ✗; and Nakama has **no retry logic** ✗.
2. **SQLSTATE 42703** — `column "role" does not exist` when running
   `UPDATE console_user SET acl = CASE WHEN role = 1 THEN '{"admin":true}'::JSONB ... END` ✗.

**The notable part**: failure (2) **reproduces with plain `ysqlsh`** ✗ (no Nakama involved) ⇒ **not a client bug** ✓;
and **not a cache** (restart YB, new session, same failure ✗). The hypothesis "YB treats `role` as a
reserved keyword" was **tested and wrong** ✗: `pg_get_keywords()` returns `role|U|unreserved` ✓.
⇒ This behaviour belongs upstream (a YB issue) — the final mechanism is not settled ✓.

**What is well proven**: Nakama **connects to and recognises YB** ✓ —
the log line `Database information: "PostgreSQL 15.12-YB-2026.1.2.0-b0 ..."` ✓; cell B reads the schema state
✗/✓ (`"DB schema outdated, migrations": 20` ✓) ⇒ **connectivity and basic queries work** ✓, only migration ✗.

## Result 2 — infrastructure: 5 real failures hit (all fixed, written down so the next run is faster)

| # | failure | real cause | fix |
|---|---|---|---|
| 1 | `PermissionError: '/home/yugabyte/yb_data/conf'` | the volume was created by root, the image runs as uid **10001** gid **100** (`users` ✗ not `yugabyte`) | `docker run -u 0 -v vol:/mnt … chown -R 10001:100 /mnt` (`make fix-perm`) |
| 2 | Nakama: `dial tcp <ip>:5433: connection refused` | `yugabyted` single-node bind **127.0.0.1** ✗ (`advertise_address: 127.0.0.1`) | `--tserver_flags=pgsql_proxy_bind_address=0.0.0.0:5433` |
| 3 | the healthcheck reported **healthy** while other containers could not connect ✗ | the healthcheck tested **loopback** ✗ | switched to `ysqlsh -h $(hostname -i)` ✓ |
| 4 | compose warning `The "i" variable is not set` ✗ | docker compose interpolates `$` | write `$$` in YAML |
| 5 | ports `5433` / `6380` were already taken | another project (5433) plus an old lab container (6380) | moved this lab to the **20xxx** range (20350/20450/20380/20381/20433) |

## Current state

- The stack comes up ✓: `yb` healthy ✓ + 2 valkeys ✓ + 2 nakamas ✗ (they cannot start until migrate finishes)
- `nakama-a`/`nakama-b` are **stopped** to avoid log spam ✗; start them again with `docker compose up -d nakama-a nakama-b`
- `make smoke` could not run yet ✗ (it needs a finished migration ✓)

## A/B #1 — YB versions (run 2026-10-13)

| YB version | isolation | migrate |
|---|---|---|
| **2026.1.2.0-b137** | READ COMMITTED | ✗ dies at migration #1 (`20180103142001_initial_schema.sql`) |
| **2026.1.2.0-b137** | SERIALIZABLE | ✓ **16/20**, 17 tables, dies at `console-fine-grained-acl.sql` — superseded, see the correction at the top |
| 2025.2.7.0-b107 | SERIALIZABLE | ✗ dies at migration #1 (40001 "not the first command in the transaction") |
| 2025.2.7.0-b107 | READ COMMITTED | **could not run** ✗ — DNS error (`lookup yb … server misbehaving`) while recreating the network; does not change the conclusion ✓ |

⇒ **Not a regression in 2026.1** ✗ — the opposite: **2026.1.2 got further than 2025.2.7** ✓.
⇒ Conclusion: this is a **Nakama ↔ YB incompatibility**, not a matter of "pick the right version" ✗.
Fair note: reproducing the **2022 claim** needs **Nakama 3.13 + YB 2.14** (the dev.to post) — that is
A/B #3, **not done** ✓.

A small but useful note: Nakama's **default** DSN is `root@localhost:26257` ✓ — that is
**CockroachDB's** default port ✓, i.e. CRDB is the distributed database Nakama was defaulted to ✓.

## A/B #2 — CockroachDB v23.2.5 (run 2026-10-13) — **THIS IS THE KEY RESULT**

| item | result |
|---|---|
| `nakama migrate up` | ✓ **20/20** (`"Successfully applied migration","count":20`) |
| tables | **20** ✓ |
| 2 cells (nakama 3.41) on one DB | ✓ **both healthy** |
| accounts shared | ✓ **same user_id** when authenticating on cell A and on cell B (same device id) |
| storage shared | ✓ write on A → **cell B reads it** |
| per-cell valkey | ✓ **NOT** shared (the right boundary) |
| leaderboard (row) | ✓ a row created on A is **read by both consoles** (console API cell A 7351 + cell B 7451 return the same `smoke_board`) ✓ |
| leaderboard (client API) | ✗ 404/`{}` — a board created straight through SQL is **not** served over the client path ⇒ it has to be created by a **runtime RPC** (phase B) ✓ |
| valkey is not shared | ✓ |

⇒ **Direct comparison**: **CRDB 20/20 ✓** vs **YB 2026.1.2 16/20 ✗** vs **YB 2025.2.7 0/20 ✗**
⇒ The problem is **YB-specific** ✓, not "Nakama cannot do distributed SQL" ✓.
⇒ And **question #2 (globally shared data) = YES** ✓✓ — it just needs **one shared data plane** for N cells ✓.

### Getting it right (it took 5 tries ✗ — written down so the next one is one shot)

1. CRDB's `--insecure` **forces `--listen-addr=127.0.0.1`** ✗ (both v23.2.5 and v26.3.2) ⇒ every service has to
   use **host networking** to talk to it ✓ (or TLS ✓).
2. Nakama 3.41: the server key must be sent as **HTTP Basic** (`Authorization: Basic base64("defaultkey:")`) ✓
   — `Bearer defaultkey` **no longer** works ✗.
3. `device id` must be **10–128 bytes** ✗ (shorter gets a 400 ✓).
4. The API speaks **protobuf-JSON**: a storage `value` is a **string** ✗ (not an object ✓); `score` likewise is
   **string** ✓ ("10" ✓).
5. Creating a leaderboard over the HTTP API: `POST /v2/leaderboard` → **404** ✗ ⇒ in 3.41 it has to be created by a **runtime
   RPC** ✓ (or the console ✓). A row inserted straight through SQL is **not** registered by the node ✗ (the registry lives in RAM ✓) ⇒
   a runtime call or a node restart is needed ✓.
6. The `authenticate/device` **response has no `user` object** ✗ ⇒ the uid must come from `GET /v2/account`
   (or from decoding the JWT ✓).
7. A `valkey-cli` inside a container on another port (6380) needs `-p 6380` ✗.

## The YUGABYTEDB stack — now WORKS (the compose initialises itself) — 2026-10-13

See `docs/yugabyte-workaround.md`. The headline points:

| | result |
|---|---|
| `nakama migrate up` on YB | ✗ 16/20 (died at `20250926112031-console-fine-grained-acl.sql`, `column "role" does not exist`) — superseded, see the correction at the top |
| **the same 20 SQL files, applied with `ysqlsh`** | ✓ **20/20** ⇒ the fault is in how Nakama runs them, NOT in the SQL or in YB |
| the **`yb-init`** service in the compose (automatic) | ✓ APPLIED 20/20 · re-run: skips 20 (idempotent) |
| `make smoke` on the YB stack | ✓ **PASS=11 FAIL=0 SKIP=1** — accounts ✓ storage ✓ shared · valkey ✗ not shared |
| SKIP | submitting a score over the client API (needs a runtime RPC — phase B) |
| querying YB directly | ✓ `select * from storage` / `users` / `migration_info` show real data |

⇒ The old conclusion "YB does not work with Nakama" is **WRONG** ✗ — YB is the **clean-licence (Apache 2.0)** option and it is
**still being fixed**, at the cost of a manual init step (now automated ✓).

## Next steps (suggested, not done)

1. **A/B more YB versions**: try `2025.2.7.0-b107` (423 MB) and `2.25.x` — if migrate gets through ⇒ a **regression in
   2026.1** ✗✓ (a very valuable conclusion, and cheap: one tag change ✓).
2. **A/B against CockroachDB** with the same test set ⇒ explains why Nakama supports CRDB ✓ but not YB ✓.
3. **A/B Nakama 3.32** (the version from the 2022 dev.to post ✓) ⇒ determines whether the fault comes from newer Nakama or newer YB ✓.
4. To stay on YB: handle this at the migration layer ✗ — patch the runner to **retry + split the transaction**
   ✓ (not a small job ✓, and reason enough to reconsider the YB choice ✓).
