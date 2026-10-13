# Running Nakama on YugabyteDB

## Summary

`nakama migrate up` **cannot initialise a database on YugabyteDB**. On a fresh database it fails at
the **first of the 20 migration files** — measured **0 of 5 runs applied anything**. The **same SQL**
applied through `ysqlsh` succeeds **20/20, 5 of 5 runs**. So the blocker is *how the SQL is executed*
(inside one transaction), not the SQL and not YugabyteDB's SQL layer.

The mechanism is reproducible **without Nakama**, in three statements: see [`repro/`](../repro/README.md).

## The failure, measured 2026-10-14

YugabyteDB 2026.1.2.0-b137, single node, default isolation `serializable`; Nakama 3.41.0.

| What was run | Result |
|---|---|
| `nakama migrate up` on a **fresh** database | ✗ **0/5 runs** applied a single migration; fails at `20180103142001_initial_schema.sql` (file 1 of 20), `SQLSTATE 40001` |
| same, with `default_transaction_isolation = read committed` | ✗ still fails at file 1 — **READ COMMITTED is not a fix** (different message) |
| Nakama's 20 files via `ysqlsh`, statement-at-a-time (= what `yb-init` does) | ✓ **20/20**, 5/5 runs |
| one migration file inside a **single transaction** (`ysqlsh -1 -f`) | ✗ **10/10 runs fail** |
| the same file, **statement-at-a-time** (autocommit) | ✓ **0/10 failures** |

The error is identical whether it comes from Nakama or from plain `ysqlsh`:

```
ERROR:  current transaction is expired or aborted (query layer retry isn't possible
        because this is not the first command in the transaction.
        Consider using READ COMMITTED isolation level.)
DETAIL:  Heartbeat: Transaction 84d3dc2b-… expired or aborted by a conflict [serializable]
```

With `read committed` the message changes but the outcome does not — still `0/20`:

```
ERROR:  current transaction is expired or aborted (query layer retry isn't possible,
        READ COMMITTED transaction was aborted …)
```

## What causes it (and what is still unknown)

*Measured:*

1. It is **transaction-scoped**. The very same statements outside a transaction succeed 10/10; inside
   one transaction the **COMMIT** fails 10/10.
2. YugabyteDB reports the abort as a **serialization conflict** (`aborted by a conflict [serializable]`)
   even though the session only reads and writes its own new tables, and asks for READ COMMITTED.
3. The advice in the message **does not work** — setting the database to READ COMMITTED still fails.
4. `DETAIL: Create index in transaction block cannot be concurrent.` + a HINT pointing at
   [yugabyte#6240](https://github.com/yugabyte/yugabyte-db/issues/6240) appears in the same output.
   In autocommit mode the same line is only a **warning**, so it is *not* the thing that fails here —
   worth reporting alongside, not as the cause.

*Not established (stated so nobody over-reads this):* which exact statement shape is required (our
minimal case has a `CREATE TABLE` + `INSERT … ON CONFLICT` + a second `CREATE TABLE` with a foreign
key, all taken verbatim from file 1), and whether the conflict is real or spurious.

*Also seen once, not reproduced:* `SQLSTATE 42703: column "role" does not exist` at file 17. That
happened on a database that had been migrated **partly by two different tools**. When we deliberately
rebuilt that state (files 1–16 applied, the `role` column present) `nakama migrate up` reported
`40001` at file 17, not `42703` — so treat `42703` as a symptom of a half-migrated database, not as
the primary failure.

A minimal reproduction is ready to file against `yugabyte/yugabyte-db`:
[`docs/upstream/yugabytedb-issue.md`](upstream/yugabytedb-issue.md).

## The workaround (3 steps, automated)

1. Leave YugabyteDB at its default isolation — the alternatives do not help (measured).
2. Apply the 20 migrations with `ysqlsh` **statement-at-a-time** (autocommit) and **only the
   `-- +migrate Up` half** — running the whole file also executes its `Down` part. A multi-statement
   batch or a single transaction fails (measured), so this step must not be "optimised" later.
3. Create Nakama's bookkeeping table and seed it, then start Nakama **without** `migrate up`:

```sql
CREATE TABLE migration_info (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
INSERT INTO migration_info(id) VALUES ('20180103142001_initial_schema.sql');  -- id = SQL filename
```

Without this, Nakama refuses to start with
`Could not get migration records, run 'nakama migrate up'`.

### Automated: the `yb-init` service

`docker-compose.yml` wires it as a real init service — `docker compose up -d` does everything:

```yaml
  yb-init:
    image: yugabytedb/yugabyte:${YB_TAG:-2026.1.2.0-b137}
    restart: "no"
    depends_on:
      yb: {condition: service_healthy}                 # wait for YSQL
    environment: {YB_HOST: yb, YB_PORT: "5433", YB_USER: yugabyte, YB_DB: yugabyte, MIG_DIR: /migrations}
    volumes:
      - ./yb-migrations:/migrations:ro                 # 20 SQL files, pinned to Nakama v3.41.0
      - ./scripts/yb-init.sh:/yb-init.sh:ro
    entrypoint: ["/bin/bash","-lc","/yb-init.sh"]

  nakama-a:
    depends_on:
      yb-init: {condition: service_completed_successfully}
    entrypoint: ["/nakama/nakama"]                     # ← no `migrate up`
```

`scripts/yb-init.sh` is **idempotent**: it applies only migrations whose `id` is not yet in
`migration_info`. Re-running it on a ready database reports `applied=0 skipped=20`.

| Check | Result |
|---|---|
| first `yb-init` on an empty database | ✓ `APPLY` 20/20 |
| second run (`make init`) | ✓ `applied=0  skipped=20` (idempotent) |
| both Nakama cells after init | ✓ HTTP 200, no migration errors |
| `make smoke` | ✓ 11 pass / 0 fail / 1 skip |

## Upgrading Nakama

Migration SQL is **pinned by version** on purpose (`yb-migrations/`, tag `v3.41.0`, checksums in
`MANIFEST.sha256`). To upgrade: copy `migrate/sql/*.sql` from the new tag into `yb-migrations/`,
regenerate the manifest (`make regen-manifest`), then `make init` — only the new files are applied.
(Re-check first whether `nakama migrate up` works by then — if it does, this whole workaround can go.)
