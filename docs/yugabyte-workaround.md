> ⚠️ **CORRECTION 2026-10-14** — the older numbers in this file ("dies at 16/20, file `console-fine-grained-acl`, `SQLSTATE 42703`") **do not reproduce** ✗.
> Measured again on a fresh database: `nakama migrate up` **fails at file #1 (0/5 runs)**, `SQLSTATE 40001`, at **COMMIT**;
> that same file applied **statement by statement** succeeds 10/10, and inside **one transaction** fails 10/10.
> A 3-statement repro with no Nakama needed: `repro/`. The correct conclusion: `docs/nakama-with-yugabytedb.md`.

# Nakama on YugabyteDB — the way that WORKS (proven 2026-10-13)

## The conclusion, reversed

I first concluded "YB does not work with Nakama" because `nakama migrate up` died at 16/20.
**That was wrong.** YB works — what dies is **the way Nakama EXECUTES** the migration, not the SQL.

## Evidence

| step | result |
|---|---|
| `nakama migrate up` on YB 2026.1.2 (serializable) | ✗ 16/20 — died at `20250926112031-console-fine-grained-acl.sql`, `SQLSTATE 42703 column "role" does not exist` — superseded, see the correction at the top |
| **those same 20 SQL files, applied with `ysqlsh`** | ✓ **20/20** |
| Nakama 3.41 starting on YB (no `migrate up`) | ✓ HTTP 200, runs normally |
| 2 Nakama nodes + 1 YB: auth with the same device | ✓ **same user_id** (`ebc151e9-…`) |
| 2 Nakama nodes + 1 YB: write storage on A → read on B | ✓ **the data is there** |
| query YB directly: `select * from storage` / `users` | ✓ real data lives in YB (`nakama_ybt`) |

## How it is done (3 steps) — `scripts/yb-apply-migrations.sh`

1. **Leave YB on its default `serializable`** ✓ (YB 2026.1.2 itself reports `default_transaction_isolation=serializable`;
   **do not** force READ COMMITTED ✗ — RC dies at migration #1 with `SQLSTATE 40001`).
2. **Apply the schema yourself**: download the 20 files from `heroiclabs/nakama/migrate/sql`, run **only the `-- +migrate Up` part**
   ⚠️ (running the whole file also runs the Down part ✗) through `ysqlsh`.
3. **Seed `migration_info`** (`id text PRIMARY KEY, applied_at timestamptz`) with 20 rows, `id` = the **.sql file name**
   (e.g. `20180103142001_initial_schema.sql`) → then start Nakama **without `migrate up`**.

## Why the old (2022) setup worked with nothing special

Yugabyte's own post (`dev.to/yugabyte/nakama-with-yugabytedb`) uses **YB 2.14.1.0-b36 +**
Nakama 3.13.1**, with no isolation flag set:
- YB back then **defaulted to serializable** ✓ (so no flag was needed);
- Nakama 3.13.1 **did not have** the migration `20250926112031-console-fine-grained-acl.sql` (added 9/2025) ✗
  ⇒ it **never hit the `role` failure** ✓.

⇒ "20/20 back then" is true ✓ — and it is achievable now ✓, it just takes one manual step.

## What the YB path costs

- Every **Nakama upgrade** needs the manual step re-run for the new migrations ✗ (scriptable ✓).
- If that step runs out of order or a `migration_info` row is missing → Nakama refuses to start ✗ (with a clear message ✓).
- In exchange: **Apache 2.0 forever, no licence key, no node limit, no telemetry** ✓✓.

---

## Automation: the `yb-init` service in docker-compose

Instead of doing it by hand, `docker-compose.yml` carries an **init service** that does exactly the above:

```yaml
  yb-init:
    image: yugabytedb/yugabyte:${YB_TAG:-2026.1.2.0-b137}
    restart: "no"
    depends_on:
      yb: {condition: service_healthy}          # wait for YSQL
    environment: {YB_HOST: yb, YB_PORT: "5433", YB_USER: yugabyte, YB_DB: yugabyte, MIG_DIR: /migrations}
    volumes:
      - ./yb-migrations:/migrations:ro          # Nakama's 20 SQL files (committed to this repo)
      - ./scripts/yb-init.sh:/yb-init.sh:ro
    entrypoint: ["/bin/bash","-lc","/yb-init.sh"]

  nakama-a:
    depends_on:
      yb-init: {condition: service_completed_successfully}   # start only AFTER the schema is done
```

⇒ `docker compose up -d` does **everything**: YB boots → `yb-init` applies the schema (idempotent) → both cells start.
⇒ `nakama migrate up` is **removed** from `nakama-a` (on YB it would fail).
⇒ `make init` re-runs init (already-applied rows are skipped — `applied=0 skipped=20 ✓`).

### Measured results

| check | result |
|---|---|
| first `yb-init` (fresh DB) | ✓ **APPLIED 20/20** — including `console-fine-grained-acl.sql`, which `nakama migrate up` cannot get through |
| second `yb-init` | ✓ **applied=0 skipped(already present)=20** (idempotent) |
| both cells start after init | ✓ healthy, HTTP 200, no migration errors |
| `make smoke` (YB stack) | ✓ **PASS=11 FAIL=0 SKIP=1** — accounts shared ✓ · storage shared ✓ · valkey not shared ✓ |
| the only SKIP | submitting a score over the client API (needs a runtime RPC to create the board — phase B ✗) |

### How the two stacks in this repo differ (deliberately)

| | `docker-compose.yml` (**YB**, default) | `docker-compose.crdb.yml` (CRDB) |
|---|---|---|
| Migrate | ✗ **no `nakama migrate up`** | ✓ uses `nakama migrate up` (the normal way) |
| Who applies the schema | the **`yb-init`** service (ysqlsh + seeding `migration_info`) | Nakama itself |
| Why | YB fails at the 9/2025 migration (see above) | CRDB does 20/20 ✓ |

### Operational notes

- Upgrading Nakama: add the new SQL files to `yb-migrations/` (change `MIG_URL` or re-download), then
  `make init` ✓ — the script applies only the files **missing** from `migration_info` ✓.
- If init fails halfway it **stops immediately** and prints 5 lines of the error ✓; fix it and re-run `make init` ✓ (safe because
  it applies only the missing part ✓).
