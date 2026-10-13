# Pinned Nakama migrations

These **20 SQL files are copied verbatim** from
[`heroiclabs/nakama`](https://github.com/heroiclabs/nakama) at tag **`v3.41.0`**
(path `migrate/sql/`), and are **Apache-2.0** (copyright The Nakama Authors).

Verified: the file list at tag `v3.41.0` and this directory are identical (20/20).

## Why they are vendored here

Nakama embeds its migrations in the binary and applies them with `nakama migrate up`.
That path is **broken on YugabyteDB** (fails at
`20180103142001_initial_schema.sql` with `SQLSTATE 40001`, at the COMMIT of the file's transaction —
see `docs/nakama-with-yugabytedb.md`)
while **the very same SQL applies cleanly through `ysqlsh`**. See `docs/findings.md`.

So this repo applies the schema itself (`scripts/yb-init.sh`) and seeds Nakama's
`migration_info` bookkeeping table. The SQL must be present at runtime ⇒ vendored.

## Integrity

`MANIFEST.sha256` pins the checksums; CI verifies them (`make test`).
When you upgrade Nakama, refresh this directory from the new tag and regenerate
the manifest (`make manifest`).
