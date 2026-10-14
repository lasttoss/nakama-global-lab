> Nakama on YugabyteDB, measured: migrate up fails at migration 1 on a fresh database, though the same SQL applies 20/20 via ysqlsh and a 4-line repro makes PostgreSQL and CockroachDB commit. Cell scaling with 0.08 s failover, a 3-node RF=3 cluster that still writes when a node dies, a 10-minute soak at 3.1k req/s.

# GitHub description & topics (paste manually)

- **Description:** the `> ` line above (`portfolio-tools/create-repos.py` reads it).
- **Topics:** `nakama` `yugabytedb` `distributed-sql` `game-backend` `docker-compose` `postgres-compatibility` `realtime` `scaling`

## Suggested pin order (profile)

1. `udp-realtime-gameserver`
2. `nakama-global-lab`  ← this repo: findings + reproducible lab
3. `ts-nakama-game-demo` / `liveops-console` (whichever stays public)
4. `zinx-server`
