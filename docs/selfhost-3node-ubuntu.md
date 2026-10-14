# Self-hosting distributed SQL on Ubuntu — YB vs CRDB, and a review of a real config

## First: COMPLEXITY COMPARISON (same job, different effort)

| | **YugabyteDB** | **CockroachDB** |
|---|---|---|
| Processes to babysit | **6** (master + tserver × 3 nodes) ✗ | **3** (1 process per node ✓) |
| Required flags per node | master: `--master_addresses`, `--rpc_bind_addresses`, `--fs_data_dirs`<br>tserver: `--tserver_master_addrs`, `--rpc_bind_addresses`, `--pgsql_proxy_bind_address`, `--fs_data_dirs` | one set: `--join`, `--advertise-addr`, `--locality`, `--store` |
| Hostname instead of IP | IP is the standard ✓ (hostnames work, but do not rely on them) | **hostname/DNS is fine** ✓ |
| Multiple NICs / NAT | you **must** add `--server_broadcast_addresses` ✗ | `--advertise-addr` handles it ✓ |
| TLS | optional ✓ (but turn on `--ysql_enable_auth`) | a secure cluster **requires a cert per node** ✗ (`cockroach cert`) |
| Ports to open | 7100 (master RPC), 9100 (tserver RPC), 5433 (YSQL); keep the UI on 7000/9000 private | 26257 (cluster + client), 8080 (DB Console) |
| Clocks | needed (HLC) — a large skew ⇒ read restarts ✗ | **skew above 80% of 500 ms ⇒ the node SHUTS ITSELF DOWN** ✓ (docs) |
| LB in front of the DB | optional (YSQL through any tserver ✓) | HAProxy recommended ✓ |
| Easiest path | **`yugabyted start --join <node1>`** ✓ | the official `systemd` template ✓ |

## 5 FAILURES in that real config (`<path>`)

```
# master.conf (CURRENT — has bugs)
--master-addresses=10.0.0.11:7100,10.0.0.12:7100   ← only 2 masters ✗
--rpc_bind_addresses=10.0.0.11:7100
--fs_data_dirs=/root                                   ← ✗✗ data lives on /root
```

1. **2 masters is wrong for production** ✗ — RF=3 needs **3 masters** (losing 1 still leaves a quorum ✓). With 2, losing 1
   **loses the whole cluster** ✗. And **every** node's conf must agree on the `--master-addresses` list
   (all 3 of them ✓), differing only in `--rpc_bind_addresses` ✓.
2. **`--fs_data_dirs=/root`** ✗✗ — it must be a **dedicated volume** (`/data/yb`, NVMe, XFS ✓). Leaving it on `/root` means
   the data lives with the OS, gets no IOPS benefit, and dies with the root volume ✓.
3. **`User=root`** in both services ✗ — create a `yugabyte` user and `chown` the data directories ✓.
4. **`After=network.target`** ✗ — it must be **`network-online.target`** ✓: with a static IP the service can start
   **before the IP is assigned** ⇒ the bind fails ⇒ it dies (the classic self-host failure ✗).
5. **Missing**: `LimitNOFILE` (YB needs a high fd count ✓), **NTP/chrony** (clocks ✗✗), **THP off** (YB recommends it ✓),
   `--ysql_enable_auth` (if you want passwords ✓).

## The easiest path to a 3-node cluster (recommended)

```bash
# on ALL 3 machines (Ubuntu 22.04/24.04), the same YB version
wget https://downloads.yugabyte.com/releases/2026.1.2.0/yugabyte-2026.1.2.0-b137-linux-x86_64.tar.gz
tar xzf yugabyte-*.tar.gz -C /opt && mv /opt/yugabyte-* /opt/yugabyte

# machine 1 (the initialising node)
/opt/yugabyte/bin/yugabyted start \
  --base_dir=/data/yb --listen=10.0.0.11 \
  --tserver_flags="pgsql_proxy_bind_address=10.0.0.11:5433" \
  --background

# machines 2 and 3 — `--join` is enough, no hand-written master/tserver config
/opt/yugabyte/bin/yugabyted start \
  --base_dir=/data/yb --listen=10.0.0.12 --join=10.0.0.11 \
  --tserver_flags="pgsql_proxy_bind_address=10.0.0.12:5433" \
  --background
```

`yugabyted` handles master+tserver, joining and config persistence by itself ✓ — **this is the answer to "the
complicated IP wiring"** ✓. `--flagfile` with yb-master/yb-tserver is only needed when you want to control every knob ✗.

If Kubernetes is already around: use the **yb-operator / Helm chart** ✓ (reproducible ✓, dead nodes replaced automatically ✓).

## If you still want systemd (the fixed version)

```ini
[Unit]
Description=YugabyteDB Master
After=network-online.target
Wants=network-online.target

[Service]
User=yugabyte
Group=yugabyte
Type=simple
LimitNOFILE=1048576
ExecStart=/opt/yugabyte/bin/yb-master --flagfile=/opt/yugabyte/conf/master.conf
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

```conf
# master.conf — the address list is the SAME on every node, the bind part differs
--master_addresses=10.0.0.11:7100,10.0.0.12:7100,10.0.0.13:7100
--rpc_bind_addresses=10.0.0.11:7100        # ← change per machine
--fs_data_dirs=/data/yb
--replication_factor=3
--enable_ysql
```
```conf
# tserver.conf
--tserver_master_addrs=10.0.0.11:7100,10.0.0.12:7100,10.0.0.13:7100
--rpc_bind_addresses=10.0.0.11:9100        # ← change per machine
--enable_ysql
--pgsql_proxy_bind_address=10.0.0.11:5433  # ← change per machine
--fs_data_dirs=/data/yb
--ysql_enable_auth
# only when the machine has several NICs or sits behind NAT:
# --server_broadcast_addresses=10.0.0.11:9100
```

## CockroachDB — 3 nodes (simpler: one binary)

```bash
# 1) generate certs once on the machine acting as CA
cockroach cert create-ca --certs-dir=certs --ca-key=ca.key
# one cert per node (do it for each IP/hostname)
cockroach cert create-node 10.0.0.11 localhost --certs-dir=certs --ca-key=ca.key
cockroach cert create-client root --certs-dir=certs --ca-key=ca.key

# 2) on each node
cockroach start \
  --certs-dir=certs --store=/data/crdb \
  --listen-addr=10.0.0.11:26257 --http-addr=10.0.0.11:8080 \
  --advertise-addr=10.0.0.11:26257 \
  --join=10.0.0.11:26257,10.0.0.12:26257,10.0.0.13:26257 \
  --locality=region=singapore,zone=sgp-a \
  --background
# 3) initialise the cluster (once)
cockroach init --certs-dir=certs --host=10.0.0.11:26257
```

⚠️ CRDB **shuts a node down** once the clock skew exceeds 80% of 500 ms (docs ✓) ⇒ NTP/chrony is **mandatory** ✓.

## Mandatory checklist for BOTH (in order)

1. **Clocks**: `chrony` (or ntpd) on every node ✓✓ — forgetting this is the most mysterious failure ✗.
2. **Static IPs** for every node ✓ (do not use DHCP ✗); open exactly the internal ports in the firewall ✓.
3. **A dedicated volume for data** (NVMe, XFS) ✓ — never `/root` ✗.
4. **THP** = `madvise`/off ✓ (YB recommends it ✓).
5. **ulimit** fd cao (`LimitNOFILE=1048576`) ✓.
6. **1 node per machine** ✓ (do not run 2 nodes on one VM ✗ — the CRDB docs are explicit ✓).
7. **An LB** in front (HAProxy for CRDB ✓; for YSQL point at any tserver ✓).
8. **Backups**: `yb-admin`/`cockroach backup` to S3 ✓ (until backups exist, it is not production ✗).
9. **Monitoring**: Prometheus scrape master/tserver (`:7000/prometheus-metrics`, `:9000/...`) ✓.
10. **Package it as a repo/script** ✓ (like `yb-init` ✓) — because in three years nobody remembers ✗.

## The real cost (not money)

| | Initial setup | Later operation |
|---|---|---|
| 3-node YB/CRDB | **an afternoon to 2 days** ✓ | version upgrades ✗ · CVE patches ✗ · disk failures ✗ · rebalancing ✗ · backup/restore ✗ · **you are the on-call** ✗ |

⇒ Setup is not as bad as it feels ✗; **the real cost is the "later"** ✓ — and that is exactly what Aurora/RDS sells ✓.
