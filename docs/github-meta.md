> Nakama on YugabyteDB, measured end to end: migrate up fails at migration 1 on a fresh database (same SQL applies 20/20 via ysqlsh, reduced to a 4-line repro that PostgreSQL and CockroachDB commit); cell scaling with 0.08 s cell failover, a 3-node RF=3 cluster that keeps writing when a node is killed, and a 10-minute soak at 3.1k req/s with no degradation.

# GitHub description & topics (paste manually)

- **Description:** the `> ` line above (`portfolio-tools/create-repos.py` reads it).
- **Topics:** `nakama` `yugabytedb` `distributed-sql` `game-backend` `docker-compose` `postgres-compatibility` `realtime` `scaling`

## Suggested pin order (profile)

1. `udp-realtime-gameserver`
2. `nakama-global-lab`  ← this repo: findings + reproducible lab
3. `ts-nakama-game-demo` / `liveops-console` (whichever stays public)
4. `zinx-server`
