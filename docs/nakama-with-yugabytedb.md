# Running Nakama on YugabyteDB

## Summary

`nakama migrate up` **fails on YugabyteDB** (16/20 migrations). The very same SQL
**applies cleanly** through `ysqlsh` (20/20). So this repo applies the schema itself and
lets Nakama start without migrating. It is automated as a compose init service.

## The failure, exactly

| Attempt | Result |
|---|---|
| `nakama migrate up` on YugabyteDB 2026.1.2, isolation `serializable` | ✗ 16/20 |
| The same 20 files applied with `ysqlsh` | ✓ **20/20** |

The migration that stops it is `20250926112031-console-fine-grained-acl.sql`, with:

```
SQLSTATE 42703: column "role" does not exist
```

That file even contains a comment acknowledging this class of problem — for CockroachDB:

```sql
-- Needed because CockroachDB does not allow ALTER TABLE ... UPDATE in a transaction block.
COMMIT;
BEGIN;

UPDATE console_user
    SET acl = CASE WHEN role = 1 THEN '{"admin":true}'::JSONB ELSE '{"admin":false}'::JSONB END;
ALTER TABLE console_user DROP COLUMN IF EXISTS role;
```

On CockroachDB the migration **passes** (20/20). On YugabyteDB the same statements executed by
Nakama's migrator fail, while `ysqlsh` runs them fine ⇒ **the blocker is how Nakama executes the
statements, not the SQL and not YugabyteDB's SQL layer**.

Also verified: YugabyteDB 2026.1.2 reports `default_transaction_isolation = serializable`, so
**do not** force `read committed` — that fails even earlier (migration #1) with
`SQLSTATE 40001: current transaction is expired or aborted (query layer retry isn't possible
because this is not the first command in the transaction)`.

## The fix (3 steps, automated)

1. Leave YugabyteDB at its default isolation (`serializable`).
2. Apply the 20 migrations yourself with `ysqlsh`, **running only the `-- +migrate Up` half**
   (running the whole file also executes its `Down` part).
3. Create Nakama's bookkeeping table and seed it, then start Nakama **without** `migrate up`:

```sql
CREATE TABLE migration_info (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
INSERT INTO migration_info(id) VALUES ('20180103142001_initial_schema.sql');  -- id = SQL filename
```

If this step is missing or incomplete, Nakama refuses to start with:
`Could not get migration records, run 'nakama migrate up'`.

## Automated: the `yb-init` service

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

### Verified output

| Check | Result |
|---|---|
| first `yb-init` on an empty database | ✓ `APPLY` 20/20, including the migration Nakama cannot run |
| second run (`make init`) | ✓ `applied=0  skipped=20` (idempotent) |
| both Nakama cells after init | ✓ HTTP 200, no migration errors |
| `make smoke` | ✓ 11 pass / 0 fail / 1 skip |

## Upgrading Nakama

Migration SQL is **pinned by version** on purpose (`yb-migrations/`, tag `v3.41.0`, checksums in
`MANIFEST.sha256`). To upgrade: copy `migrate/sql/*.sql` from the new tag into `yb-migrations/`,
regenerate the manifest (`make regen-manifest`), then `make init` — only the new files are applied.

## Upstream

A minimal reproduction is ready to file against `yugabyte/yugabyte-db` — see
[`upstream/yugabytedb-issue.md`](upstream/yugabytedb-issue.md).
