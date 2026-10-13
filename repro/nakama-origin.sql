-- The same failure, as it reaches a real tool: the first three statements of
-- heroiclabs/nakama@v3.41.0  migrate/sql/20180103142001_initial_schema.sql  (Apache-2.0),
-- copied verbatim, wrapped the way a migration runner wraps a file.
-- Result on YugabyteDB: identical failure at COMMIT.
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
