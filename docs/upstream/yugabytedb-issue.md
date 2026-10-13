# Draft issue for `yugabyte/yugabyte-db` (not filed yet)

**Title:** `[YSQL] DML reports "column does not exist" for a column present in information_schema when statements are sent as one batch`

## Summary

Running Nakama's migrations against YugabyteDB 2026.1.2 fails at one file with
`SQLSTATE 42703: column "role" does not exist`, even though:
- the column exists and is listed in `information_schema.columns`;
- **the exact same SQL file applies successfully through `ysqlsh`** against the same database.

So the failing factor is *how the statements are sent*, not the SQL itself.

## Environment

| | |
|---|---|
| YugabyteDB | `yugabytedb/yugabyte:2026.1.2.0-b137`, single node, `ysql_default_transaction_isolation=serializable` |
| Client (failing) | Nakama 3.41.0 migrator (`heroiclabs/nakama`), tag `v3.41.0` |
| Client (working) | `ysqlsh` from the same image |
| Observed also on | YugabyteDB 2025.2.7.0-b107 (fails earlier, see note below) |

## Steps to reproduce

1. Start YugabyteDB, create an empty database.
2. Apply Nakama's migrations 1–16 from `heroiclabs/nakama@v3.41.0` (`migrate/sql/`) — succeeds.
3. Run the file `20250926112031-console-fine-grained-acl.sql` (Up half only) the way Nakama does it:

```
ALTER TABLE console_user ADD COLUMN IF NOT EXISTS acl JSONB NOT NULL DEFAULT '{"admin":false}'::JSONB;

-- Needed because CockroachDB does not allow ALTER TABLE ... UPDATE in a transaction block.
COMMIT;
BEGIN;

UPDATE console_user
    SET acl = CASE WHEN role = 1 THEN '{"admin":true}'::JSONB ELSE '{"admin":false}'::JSONB END;
ALTER TABLE console_user DROP COLUMN IF EXISTS role;
```

4. **Result:** `ERROR: column "role" does not exist (SQLSTATE 42703)`.
5. Apply the identical file with `ysqlsh -f` (same user, same database): **succeeds**.
6. Also note `SELECT column_name FROM information_schema.columns WHERE table_name='console_user'`
   lists `role` at the time the DML fails.

## Notes / questions

- The statements are sent as a single batch by the client; `ysqlsh -f` processes them statement by
  statement with the file's own `COMMIT; BEGIN;`. Hypothesis to confirm: when a batch contains DDL and
  later DML, the later statement's column resolution is evaluated before/independently of the DDL
  effect. If that is the intended behaviour, is there a documented client-side workaround
  (statement-at-a-time execution), or a setting that changes it?
- With `ysql_default_transaction_isolation=read committed` the same sequence fails earlier, at
  migration #1, with
  `SQLSTATE 40001: current transaction is expired or aborted (query layer retry isn't possible because this is not the first command in the transaction)`.
  That may or may not be the same root cause.
- Workaround used in the meantime (documented, not a fix): apply the migrations with `ysqlsh` and seed
  Nakama's `migration_info` table, then start Nakama without `migrate up` —
  see `docs/nakama-with-yugabytedb.md`.

## Minimal repro you can run without Nakama

_To be completed before filing: a two-statement batch that reproduces the resolution failure on a
fresh table, e.g. `ALTER TABLE t ADD COLUMN c int; UPDATE t SET c = 1;` sent from the same client
library as one batch, versus the same statements sent separately._
