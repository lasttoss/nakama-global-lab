-- Minimal reproduction of the YugabyteDB failure that blocks `nakama migrate up`.
-- Statements 1-3 are copied verbatim from
--   yb-migrations/20180103142001_initial_schema.sql  (= heroiclabs/nakama v3.41.0, migrate/sql/, Apache-2.0)
-- Wrapped in one explicit transaction, the way a migration runner executes a file.
--
-- Expected (PostgreSQL, CockroachDB): all statements succeed, COMMIT succeeds.
-- Actual (YugabyteDB 2026.1.2, serializable): COMMIT fails and the transaction is discarded:
--   ERROR: current transaction is expired or aborted (query layer retry isn't possible because
--          this is not the first command in the transaction. Consider using READ COMMITTED isolation level.)
--   DETAIL: Heartbeat: Transaction <uuid> expired or aborted by a conflict [serializable]
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
