# Draft issue for `yugabyte/yugabyte-db` — ready to file

**Title:** `[YSQL] A transaction that INSERTs into a table and then CREATEs another table with a FOREIGN KEY to it is aborted at COMMIT (SQLSTATE 40001), while PostgreSQL and CockroachDB commit`

> Status: fully verified here — the failing case, the shrink matrix, the statement-at-a-time control,
> the READ COMMITTED variant, and the PostgreSQL/CockroachDB controls. Nothing below is an assumption.

## Summary

Four lines of plain SQL fail on YugabyteDB and succeed on PostgreSQL 15 and CockroachDB v23.2.5:

```sql
BEGIN;
CREATE TABLE a (id int PRIMARY KEY, v text);
INSERT INTO a (id, v) VALUES (1, 'x');
CREATE TABLE b (id int PRIMARY KEY, a_id int REFERENCES a (id));   -- FOREIGN KEY to the table just inserted into
COMMIT;                                                            -- ← fails
```

```
ERROR:  current transaction is expired or aborted (query layer retry isn't possible because this is
        not the first command in the transaction. Consider using READ COMMITTED isolation level.)
DETAIL:  Heartbeat: Transaction 9f2c1f54-0d96-4341-92c0-45dba46ce085 expired or aborted by a conflict [serializable]
```

Measured **10/10 runs** on fresh databases; the identical statements **without** the transaction
wrapper succeed. This pattern is what a migration runner produces, so it blocks database
initialisation for tools that wrap each file in a transaction — `nakama migrate up` applies **0 of 20**
migrations on a fresh database (5/5 runs).

## Environment

| | |
|---|---|
| YugabyteDB | `yugabytedb/yugabyte:2026.1.2.0-b137`, single node, `ysqlsh` from the same image |
| Server version as reported | `PostgreSQL 15.12-YB-2026.1.2.0-b0` |
| Isolation | default (`serializable`) unless stated |
| Also observed on | YugabyteDB 2025.2.7.0-b107 (same class of failure, different file) |
| Client that surfaced it | Nakama 3.41.0 migrator (`heroiclabs/nakama`, tag `v3.41.0`) — but Nakama is **not** required to reproduce |

## Reproduction

`repro/minimal.sql`:

```sql
BEGIN;
CREATE TABLE a (id int PRIMARY KEY, v text);
INSERT INTO a (id, v) VALUES (1, 'x');
CREATE TABLE b (id int PRIMARY KEY, a_id int REFERENCES a (id));
COMMIT;
```

```bash
CREATE DATABASE repro;
ysqlsh -h <host> -U yugabyte -d repro -f repro/minimal.sql    # ← fails at COMMIT
```

### What is required (shrunk by measurement)

| Variant | Result |
|---|---|
| 3 statements as above | ✗ fails |
| without `ON CONFLICT` (the INSERT has none here) | ✗ fails |
| INSERT into a **different** table than the FK target | ✓ succeeds |
| second table **without** the FOREIGN KEY | ✓ succeeds |
| without the INSERT | ✓ succeeds |
| without the explicit transaction | ✓ succeeds |

Required combination: `INSERT` **+** `CREATE TABLE` whose `FOREIGN KEY` references the table just
inserted into, **inside one transaction**.

### Controls (identical file)

| Engine | Result |
|---|---|
| PostgreSQL 15 | ✓ `BEGIN / CREATE TABLE / INSERT 0 1 / CREATE TABLE / COMMIT` |
| CockroachDB v23.2.5 | ✓ same statements, `COMMIT` succeeds |
| YugabyteDB 2026.1.2.0-b137 | ✗ fails at `COMMIT`, 10/10 runs |

### The same failure through a real tool

The first three statements of `heroiclabs/nakama@v3.41.0`
`migrate/sql/20180103142001_initial_schema.sql`, wrapped in one transaction, fail identically
(`repro/nakama-origin.sql`) — and so does the whole file, 10/10 runs.

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
