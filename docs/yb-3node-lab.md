# Scaling the storage side: a 3-node YugabyteDB cluster (RF=3)

The main lab runs a **single-node** data plane so it stays cheap to run. Production needs fault
tolerance, so this is the other half of the scaling story, **measured rather than described**: a
3-node cluster, replication factor 3, and a test that shows losing a node does not stop writes.

## How it is built

`docker-compose.yb3.yml` — three containers, each running a master **and** a tserver (the same shape
as three machines), one zone each, so `--fault_tolerance=zone` produces replication factor 3:

| node | zone | YSQL (host port) |
|---|---|---|
| `n1` | `lab.region1.zone1` | 15433 |
| `n2` | `lab.region1.zone2` | 25433 |
| `n3` | `lab.region1.zone3` | 35433 |

```bash
docker compose -f docker-compose.yb3.yml up -d
bash scripts/yb3-init.sh        # the 20 migrations, statement-at-a-time, + migration_info seed
bash scripts/yb3-kill-test.sh   # kill a node, prove writes continue, let it rejoin
```

`yugabyted status --base_dir=/home/yugabyte/yb_data` on a node reports:

```
| Status     : Running.
| YSQL Status: Ready
| Replication Factor: 3
```

The migrations are applied by **the same statement-at-a-time path** as the single-node lab
(`docs/nakama-with-yugabytedb.md`) — it works unchanged on a multi-node cluster: `applied=20`.

## Measured: losing a node does not stop writes

| Step | Result |
|---|---|
| cluster of 3, write + read probe | OK |
| **`docker kill yb3-n3`** (one of three replicas gone) | **write + read OK 10/10 runs** |
| `yb3-n3` restarted | rejoined in **1 s** |
| rows before/after | intact (12 rows) |

Recreating the three containers against the same data directory also preserved everything
(`migration_info` 20/20, every probe row) — the cluster is durable across container lifecycle, and
`YB3_DATA=<path>` lets that 5 GB of data live outside the source tree.

Placement confirms the data plane is genuinely spread across the nodes — e.g. the `users` tablet is
led by `n2` (`yb-admin list_tablets ysql.nakama3 users`), not by the node the client connects to.

## What this proves, and what it does not

*Proves:* replication factor 3 tolerates **one** node loss without interrupting writes; a node rejoins
without any operator action; the migration path is unchanged on a multi-node cluster.

*Does not prove:* two-node loss (that is beyond RF=3 — never claimed here); multi-region latency;
YugabyteDB's own upgrade path.

## Lab notes (the fiddly parts, so nobody rediscovers them)

- `yugabyted` in this build rejects `--replication_factor`; the supported flag is
  `--fault_tolerance=zone`, with a distinct `--cloud_location` per node.
- Every `yugabyted` subcommand must repeat `--base_dir=/home/yugabyte/yb_data`, or `status` reports
  "not running" for a healthy node.
- YSQL binds to the node's **advertised name** (`n1`), not `127.0.0.1`. Connect with `-h n1` from
  inside a node container; the published host ports do not work for that reason.
- The image runs as **uid 10001**, so bind-mounted data directories must be writable by it. This lab
  uses `chmod 777` on them; the honest production answer is to match ownership, or to run the
  container with your own uid.

## Cost note

Three containers with a 1.5 GB tserver cap each; memory measured while serving traffic:
`docs/benchmarks-results.md`.
