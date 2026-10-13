> Running Nakama on YugabyteDB, measured: `nakama migrate up` fails at migration 1 on a fresh database (same SQL applies 20/20 via ysqlsh, reduced to a 4-line repro that PostgreSQL and CockroachDB commit); plus cell-based scaling with netem-measured latency, throughput and 0.08 s cell failover.

# GitHub description & topics (paste manually)

- **Description:** the `> ` line above (`portfolio-tools/create-repos.py` reads it).
- **Topics:** `nakama` `yugabytedb` `distributed-sql` `game-backend` `docker-compose` `postgres-compatibility` `realtime` `scaling`

## Suggested pin order (profile)

1. `udp-realtime-gameserver`
2. `nakama-global-lab`  ← this repo: findings + reproducible lab
3. `ts-nakama-game-demo` / `liveops-console` (whichever stays public)
4. `zinx-server`
