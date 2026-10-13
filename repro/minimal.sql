-- Four-line reproduction of a YugabyteDB failure that blocks db-migration tools
-- (Nakama's migrator among them). Nothing Nakama-specific: this is plain SQL.
--
-- On PostgreSQL 15 and CockroachDB v23.2.5 all statements succeed and COMMIT succeeds.
-- On YugabyteDB 2026.1.2.0-b137 (default serializable) the COMMIT fails 10/10 runs:
--   ERROR:  current transaction is expired or aborted (query layer retry isn't possible because
--           this is not the first command in the transaction. Consider using READ COMMITTED isolation level.)
--   DETAIL: Heartbeat: Transaction <uuid> expired or aborted by a conflict [serializable]
--
-- What is required (measured, see README.md):
--   * an INSERT into a table, followed by
--   * a CREATE TABLE carrying a FOREIGN KEY that references that same table,
--   * all inside one explicit transaction.
--   ON CONFLICT is irrelevant; inserting into a different table does not trigger it.
BEGIN;

CREATE TABLE a (id int PRIMARY KEY, v text);
INSERT INTO a (id, v) VALUES (1, 'x');
CREATE TABLE b (id int PRIMARY KEY, a_id int REFERENCES a (id));

COMMIT;
