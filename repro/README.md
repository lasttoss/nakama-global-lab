# Minimal reproduction — no Nakama needed

Three statements, copied **verbatim** from Nakama's first migration file, inside one transaction:

```sql
BEGIN;
CREATE TABLE IF NOT EXISTS users (PRIMARY KEY (id), id UUID NOT NULL, username VARCHAR(128) NOT NULL CONSTRAINT users_username_key UNIQUE);
INSERT INTO users (id, username) VALUES ('00000000-0000-0000-0000-000000000000','') ON CONFLICT(id) DO NOTHING;
CREATE TABLE IF NOT EXISTS user_device (PRIMARY KEY (id), FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE, id VARCHAR(128) NOT NULL, user_id UUID NOT NULL, UNIQUE (user_id, id));
COMMIT;
```

Run it against a YugabyteDB container (the lab's `yb` service is fine):

```bash
bash repro/run.sh            # or: YBC=<container-name> bash repro/run.sh
```

The runner creates a **fresh database per case** and **checks its own expectations**, so a mismatch
prints `✗ KHÁC KỲ VỌNG` instead of passing silently.

## Measured result (2026-10-14, YugabyteDB 2026.1.2.0-b137, single node, serializable)

```
YugabyteDB: 15.12-YB-2026.1.2.0-b0
  3 câu đầu (repro/repro.sql), 1 transaction       FAIL  ✓ khớp
        ERROR:  current transaction is expired or aborted (query layer retry isn't possible because this is not the first command in the transaction. Consider using READ COMMITTED isolation level.)
        DETAIL:  Heartbeat: Transaction 84d3dc2b-… expired or aborted by a conflict [serializable]
  3 câu đó, KHÔNG có transaction (đối chứng)        OK    ✓ khớp
  cả file migration #1, 1 transaction               FAIL  ✓ khớp
  cả file migration #1, TỪNG CÂU (= đường yb-init)  OK    ✓ khớp
```

Repeated runs (not just one pass):

| Case | Repetitions | Result |
|---|---|---|
| these 3 statements, one transaction | 10 | ✗ **10/10 fail** |
| the whole first migration file, one transaction | 10 | ✗ 10/10 fail |
| the whole first migration file, statement-at-a-time | 10 | ✓ 0/10 fail |
| `nakama migrate up`, fresh database | 5 | ✗ 5/5 fail (0 migrations applied) |

So: **the transaction is what fails**, not the SQL. The same statements executed without an explicit
transaction succeed every time.

## Controls (verified, not assumed)

The same `repro.sql`, run as-is:

| Engine | Result |
|---|---|
| YugabyteDB `2026.1.2.0-b137` (serializable) | ✗ fails at `COMMIT` — 10/10 runs |
| PostgreSQL 15 (`postgres:15`) | ✓ `BEGIN / CREATE TABLE / INSERT 0 1 / CREATE TABLE / COMMIT` |
| CockroachDB v23.2.5 (`cockroachdb/cockroach:v23.2.5`) | ✓ same statements, `COMMIT` succeeds |

### How the controls were run

```bash
# PostgreSQL 15
docker run -d --name repro-pg -e POSTGRES_PASSWORD=postgres -p 25432:5432 postgres:15
docker exec repro-pg psql -U postgres -c "CREATE DATABASE repro"
docker exec -i repro-pg psql -U postgres -d repro -v ON_ERROR_STOP=1 -f /dev/stdin < repro/repro.sql

# CockroachDB
docker exec <crdb-container> cockroach sql --insecure -e "CREATE DATABASE repro"
docker exec -i <crdb-container> cockroach sql --insecure --database repro -f /dev/stdin < repro/repro.sql
```

## What this does *not* establish

- Which part of the three statements is strictly required (we stopped shrinking once the minimal case
  was stable and verbatim).
- Why the transaction is reported as aborted *by a conflict* at `COMMIT`, on tables only this session
  has touched.
- Whether READ COMMITTED would help in a different version — measured here: **it does not** (same
  failure, different message).

## Confirmation on the real thing

`docs/nakama-with-yugabytedb.md` shows the same failure arriving through `nakama migrate up`, and the
statement-at-a-time workaround that this repo's `yb-init` service automates.
