# Minimal reproduction — no Nakama needed

A database migration tool that wraps each migration file in a transaction (Nakama's migrator does)
**cannot initialise a YugabyteDB database**. Reduced to plain SQL, the trigger is four lines:

```sql
BEGIN;
CREATE TABLE a (id int PRIMARY KEY, v text);
INSERT INTO a (id, v) VALUES (1, 'x');
CREATE TABLE b (id int PRIMARY KEY, a_id int REFERENCES a (id));
COMMIT;   -- ← fails on YugabyteDB
```

```bash
bash repro/run.sh          # or: YBC=<container-name> bash repro/run.sh
```

Files: `minimal.sql` (the four lines), `nakama-origin.sql` (the same failure as it reaches a real
tool — the first three statements of Nakama's first migration file, verbatim). The runner creates a
**fresh database per case** and **checks its own expectations**, so a mismatch prints
`✗ UNEXPECTED` instead of passing silently.

## Measured result (2026-10-14, YugabyteDB 2026.1.2.0-b137, single node, serializable)

```
YugabyteDB: 15.12-YB-2026.1.2.0-b0
  minimal repro, 3 statements, 1 transaction     FAIL  ✓ match
        ERROR:  current transaction is expired or aborted (query layer retry isn't possible because this is not the first command in the transaction. Consider using READ COMMITTED isolation level.)
        DETAIL:  Transaction 9f2c1f54-… expired or aborted by a conflict [serializable]
  same 3 statements, NO transaction              OK    ✓ match
  Nakama's real 3 statements, 1 transaction      FAIL  ✓ match
  all of migration #1, 1 transaction             FAIL  ✓ match
  all of migration #1, STATEMENT BY STATEMENT    OK    ✓ match
```

## What is actually required (shrunk by measurement, not by guessing)

| Case | Result |
|---|---|
| Nakama's real 3 statements, one transaction | ✗ fails |
| INSERT into a table **+ CREATE TABLE with a FOREIGN KEY to that same table** | ✗ fails |
| …same, with `ON CONFLICT` removed | ✗ fails (`ON CONFLICT` is irrelevant) |
| …same, but the INSERT goes to a **different** table than the FK target | ✓ succeeds |
| …same, but the second table has **no FOREIGN KEY** | ✓ succeeds |
| …same, without the INSERT | ✓ succeeds |
| the same statements **without an explicit transaction** | ✓ succeeds |

So the required combination is: an `INSERT`, then a `CREATE TABLE` whose `FOREIGN KEY` references the
table just inserted into, **inside one transaction**.

## Repetitions

| Case | Runs | Failures |
|---|---|---|
| the four lines above, one transaction | 10 | **10** |
| the full first migration file, one transaction | 10 | **10** |
| the same file, statement-at-a-time | 10 | 0 |
| `nakama migrate up`, fresh database | 5 | **5** (0 of 20 migrations applied) |

## Controls (verified, not assumed)

| Engine | Result |
|---|---|
| **PostgreSQL 15** (`postgres:15`) | ✓ `BEGIN / CREATE TABLE / INSERT 0 1 / CREATE TABLE / COMMIT` |
| **CockroachDB v23.2.5** | ✓ same statements, `COMMIT` succeeds |
| **YugabyteDB 2026.1.2.0-b137** | ✗ fails at `COMMIT`, 10/10 runs |

```bash
# PostgreSQL 15
docker run -d --name repro-pg -e POSTGRES_PASSWORD=postgres postgres:15
docker exec repro-pg psql -U postgres -c "CREATE DATABASE repro"
docker exec -i repro-pg psql -U postgres -d repro -v ON_ERROR_STOP=1 -f /dev/stdin < repro/minimal.sql

# CockroachDB
docker exec <crdb-container> cockroach sql --insecure -e "CREATE DATABASE repro"
docker exec -i <crdb-container> cockroach sql --insecure --database repro -f /dev/stdin < repro/minimal.sql
```

## Also measured: READ COMMITTED does not help

The error message suggests READ COMMITTED. Setting it on the database
(`ALTER DATABASE … SET default_transaction_isolation TO 'read committed'`) still fails at the first
migration, with a different message (`… READ COMMITTED transaction was aborted …`, 0/20 applied).

## What this does *not* establish

- Why YugabyteDB reports a **conflict** here: the transaction only creates its own tables and inserts
  its own row.
- Whether the conflict is real or spurious, and whether the FK validation inside the transaction is
  what makes it unretryable.
- Whether `CREATE INDEX` warnings seen in the same output (`DETAIL: Create index in transaction block
  cannot be concurrent.` → yugabyte#6240) are related. In autocommit mode those are warnings only.

## Confirmation on the real thing

`docs/nakama-with-yugabytedb.md` shows the same failure arriving through `nakama migrate up`, and the
statement-at-a-time workaround that this repo's `yb-init` service automates.
