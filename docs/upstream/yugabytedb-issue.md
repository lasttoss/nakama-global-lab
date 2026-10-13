# Draft issue for `yugabyte/yugabyte-db` — ready to file

**Title:** `[YSQL] A transaction containing CREATE TABLE after INSERT … ON CONFLICT is aborted at COMMIT; next statement fails with SQLSTATE 40001 (and the suggested READ COMMITTED does not help)`

> Status: reproduction is fully verified here — the failing case, the statement-at-a-time control,
> the read-committed variant, and the PostgreSQL/CockroachDB controls. Nothing in this draft is an
> assumption.

## Summary

At the default `serializable` isolation, a short transaction that (1) creates a table, (2) inserts a
row with `ON CONFLICT DO NOTHING`, and (3) creates a second table with a foreign key to the first, is
**aborted at `COMMIT`**. The next statement then fails with a message that recommends READ COMMITTED —
but setting the database to READ COMMITTED fails the same way with a different message.

Executing the **identical statements without an explicit transaction succeeds every time**, so the
transaction (not the SQL) is what fails. This blocks `nakama migrate up` completely: it applies **0 of
20** migrations on a fresh database (5/5 runs).

## Environment

| | |
|---|---|
| YugabyteDB | `yugabytedb/yugabyte:2026.1.2.0-b137`, single node, `ysqlsh` from the same image |
| Server version as reported | `PostgreSQL 15.12-YB-2026.1.2.0-b0` |
| Isolation | default (`serializable`) unless stated |
| Also observed on | YugabyteDB 2025.2.7.0-b107 (same class of failure, different file) |
| Client that surfaced it | Nakama 3.41.0 migrator (`heroiclabs/nakama`, tag `v3.41.0`) — but Nakama is **not** required to reproduce |

## Reproduction (no Nakama required)

`repro.sql` — the three statements are copied verbatim from Nakama's first migration file
(`migrate/sql/20180103142001_initial_schema.sql`, Apache-2.0):

```sql
BEGIN;

CREATE TABLE IF NOT EXISTS users (
    PRIMARY KEY (id),
    id            UUID          NOT NULL,
    username      VARCHAR(128)  NOT NULL CONSTRAINT users_username_key UNIQUE
);

INSERT INTO users (id, username)
    VALUES ('00000000-0000-0000-0000-000000000000', '')
    ON CONFLICT(id) DO NOTHING;

CREATE TABLE IF NOT EXISTS user_device (
    PRIMARY KEY (id),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    id      VARCHAR(128) NOT NULL,
    user_id UUID         NOT NULL,
    UNIQUE (user_id, id)
);

COMMIT;
```

```bash
createdb repro                                     # or: CREATE DATABASE repro;
ysqlsh -h <host> -U yugabyte -d repro -f repro.sql # ← fails
```

### Actual

```
ERROR:  current transaction is expired or aborted (query layer retry isn't possible because this is
        not the first command in the transaction. Consider using READ COMMITTED isolation level.)
DETAIL:  Heartbeat: Transaction 84d3dc2b-e616-4c15-9474-cd1e66d90a0f expired or aborted by a conflict [serializable]
```

### Expected

`COMMIT` succeeds. Verified controls — the identical file, run as-is:

| Engine | Result |
|---|---|
| PostgreSQL 15 (`postgres:15`) | ✓ `BEGIN / CREATE TABLE / INSERT 0 1 / CREATE TABLE / COMMIT` |
| CockroachDB v23.2.5 | ✓ same statements, `COMMIT` succeeds |
| YugabyteDB 2026.1.2.0-b137 (serializable) | ✗ fails at `COMMIT`, 10/10 runs (this report) |

## Repetitions (fresh database each time)

| Case | Runs | Failures |
|---|---|---|
| the 3 statements above, one transaction | 10 | **10** |
| the full first migration file (Up half), one transaction | 10 | **10** |
| the same file, statement-at-a-time (autocommit) | 10 | 0 |
| `nakama migrate up` on a fresh database | 5 | **5** (0 of 20 migrations applied) |

## READ COMMITTED does not help (measured)

```sql
ALTER DATABASE repro SET default_transaction_isolation TO 'read committed';
```

Same file, fresh database: still fails, now with

```
ERROR:  current transaction is expired or aborted (query layer retry isn't possible,
        READ COMMITTED transaction was aborted  and so …)
```

So the remediation named in the error message is not a workaround for this case — which makes the
message actively misleading for anyone who follows it.

## Possibly related output in the same run

In the full migration file, the same session also prints (in autocommit mode these are only
**warnings**, so they are not what fails here):

```
DETAIL:  Create index in transaction block cannot be concurrent.
HINT:    Consider running it outside of a transaction block. See https://github.com/yugabyte/yugabyte-db/issues/6240.
```

And when a whole file is sent as a single simple-query batch, the error is even more explicit about a
protocol limitation:

```
ERROR:  current transaction is expired or aborted (query layer retries aren't supported for
        multi-statement queries issued via the simple query protocol, upvote github issue #21833 if you want this)
```

## Questions

1. Is the `serializable` conflict here real or spurious? The session only creates its own tables and
   inserts one row; nothing else has touched them.
2. Is `INSERT … ON CONFLICT DO NOTHING` + subsequent DDL in one transaction a known-bad pattern in YSQL?
3. Should the error message avoid recommending READ COMMITTED when that switch does not resolve it?

## Workaround in use

Apply migrations **outside a transaction, statement-at-a-time**, then seed the migration bookkeeping
table and start the application without its built-in migrator. Documented with evidence in
`docs/nakama-with-yugabytedb.md`; automated as `scripts/yb-init.sh` in this repo.
