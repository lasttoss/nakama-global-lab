# Self-host distributed SQL trên Ubuntu — YB vs CRDB, và review config thật

## Trước hết: SO SÁNH ĐỘ PHỨC TẠP (cùng loại việc, khác mức)

| | **YugabyteDB** | **CockroachDB** |
|---|---|---|
| Số tiến trình phải nuôi | **6** (master + tserver × 3 node) ✗ | **3** (1 tiến trình/node ✓) |
| Flag bắt buộc/node | master: `--master_addresses`, `--rpc_bind_addresses`, `--fs_data_dirs`<br>tserver: `--tserver_master_addrs`, `--rpc_bind_addresses`, `--pgsql_proxy_bind_address`, `--fs_data_dirs` | 1 bộ: `--join`, `--advertise-addr`, `--locality`, `--store` |
| Hostname thay IP | IP là chuẩn ✓ (hostname được nhưng đừng dựa vào) | **hostname/DNS được** ✓ |
| Nhiều NIC / NAT | **phải** thêm `--server_broadcast_addresses` ✗ | `--advertise-addr` xử lý ✓ |
| TLS | tuỳ chọn ✓ (nhưng nên bật `--ysql_enable_auth`) | secure cluster **bắt buộc sinh cert từng node** ✗ (`cockroach cert`) |
| Port cần mở | 7100 (master RPC), 9100 (tserver RPC), 5433 (YSQL); UI 7000/9000 để private | 26257 (cluster + client), 8080 (DB Console) |
| Đồng hồ | cần (HLC) — lệch nhiều ⇒ read restart ✗ | **lệch > 80% của 500 ms ⇒ node TỰ TẮT** ✓ (docs) |
| LB trước DB | tuỳ (YSQL qua bất kỳ tserver ✓) | khuyến nghị HAProxy ✓ |
| Đường dễ nhất | **`yugabyted start --join <node1>`** ✓ | `systemd` template chính thức ✓ |

## 5 LỖI trong config thật của anh (`<path>`)

```
# master.conf (HIỆN TẠI — có lỗi)
--master-addresses=10.0.0.11:7100,10.0.0.12:7100   ← chỉ 2 master ✗
--rpc_bind_addresses=10.0.0.11:7100
--fs_data_dirs=/root                                   ← ✗✗ data nằm trên /root
```

1. **2 master là sai cho production** ✗ — RF=3 cần **3 master** (mất 1 vẫn còn quorum ✓). Với 2, mất 1 là
   **mất luôn cluster** ✗. Và file conf của **mỗi** node phải giống nhau ở danh sách `--master-addresses`
   (đủ 3 ✓), chỉ khác `--rpc_bind_addresses` ✓.
2. **`--fs_data_dirs=/root`** ✗✗ — phải là **volume riêng** (`/data/yb`, NVMe, XFS ✓). Để trên `/root` =
   dữ liệu chung sống với OS, không tận dụng được IOPS, và mất theo root volume ✓.
3. **`User=root`** trong cả 2 service ✗ — tạo user `yugabyte`, `chown` data dirs ✓.
4. **`After=network.target`** ✗ — phải là **`network-online.target`** ✓: với IP tĩnh, service có thể start
   **trước khi IP được gán** ⇒ bind fail ⇒ chết (lỗi kinh điển của self-host ✗).
5. **Thiếu**: `LimitNOFILE` (YB cần fd cao ✓), **NTP/chrony** (đồng hồ ✗✗), **THP off** (khuyến nghị YB ✓),
   `--ysql_enable_auth` (nếu muốn mật khẩu ✓).

## Đường dễ nhất để dựng 3 node (khuyên dùng)

```bash
# trên CẢ 3 máy (Ubuntu 22.04/24.04), cùng version YB
wget https://downloads.yugabyte.com/releases/2026.1.2.0/yugabyte-2026.1.2.0-b137-linux-x86_64.tar.gz
tar xzf yugabyte-*.tar.gz -C /opt && mv /opt/yugabyte-* /opt/yugabyte

# máy 1 (node khởi tạo)
/opt/yugabyte/bin/yugabyted start \
  --base_dir=/data/yb --listen=10.0.0.11 \
  --tserver_flags="pgsql_proxy_bind_address=10.0.0.11:5433" \
  --background

# máy 2, 3 — CHỈ cần --join là đủ, KHÔNG phải cấu hình master/tserver bằng tay
/opt/yugabyte/bin/yugabyted start \
  --base_dir=/data/yb --listen=10.0.0.12 --join=10.0.0.11 \
  --tserver_flags="pgsql_proxy_bind_address=10.0.0.12:5433" \
  --background
```

`yugabyted` tự lo master+tserver, tự join, tự persist cấu hình ✓ — **đây là câu trả lời cho "cấu hình nối IP
phức tạp"** ✓. Dùng `--flagfile` với yb-master/yb-tserver chỉ cần khi muốn kiểm soát từng tham số ✗.

Nếu đã có Kubernetes: dùng **yb-operator / Helm chart** ✓ (reproducible ✓, node chết tự thay ✓).

## Nếu vẫn muốn systemd (bản đã sửa)

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
# master.conf — TRÊN MỖI NODE giống nhau phần danh sách, khác phần bind
--master_addresses=10.0.0.11:7100,10.0.0.12:7100,10.0.0.13:7100
--rpc_bind_addresses=10.0.0.11:7100        # ← đổi theo từng máy
--fs_data_dirs=/data/yb
--replication_factor=3
--enable_ysql
```
```conf
# tserver.conf
--tserver_master_addrs=10.0.0.11:7100,10.0.0.12:7100,10.0.0.13:7100
--rpc_bind_addresses=10.0.0.11:9100        # ← đổi theo từng máy
--enable_ysql
--pgsql_proxy_bind_address=10.0.0.11:5433  # ← đổi theo từng máy
--fs_data_dirs=/data/yb
--ysql_enable_auth
# chỉ khi máy có nhiều NIC hoặc sau NAT:
# --server_broadcast_addresses=10.0.0.11:9100
```

## CockroachDB — 3 node (đơn giản hơn: 1 binary)

```bash
# 1) sinh cert 1 lần trên máy làm CA
cockroach cert create-ca --certs-dir=certs --ca-key=ca.key
# mỗi node 1 cert (làm cho từng IP/hostname)
cockroach cert create-node 10.0.0.11 localhost --certs-dir=certs --ca-key=ca.key
cockroach cert create-client root --certs-dir=certs --ca-key=ca.key

# 2) trên từng node
cockroach start \
  --certs-dir=certs --store=/data/crdb \
  --listen-addr=10.0.0.11:26257 --http-addr=10.0.0.11:8080 \
  --advertise-addr=10.0.0.11:26257 \
  --join=10.0.0.11:26257,10.0.0.12:26257,10.0.0.13:26257 \
  --locality=region=singapore,zone=sgp-a \
  --background
# 3) khởi tạo cluster (1 lần)
cockroach init --certs-dir=certs --host=10.0.0.11:26257
```

⚠️ CRDB **tự tắt node** khi lệch đồng hồ quá 80% của 500 ms (docs ✓) ⇒ **bắt buộc** NTP/chrony ✓.

## Checklist bắt buộc cho CẢ HAI (thứ tự đúng)

1. **Đồng hồ**: `chrony` (hoặc ntpd) trên mọi node ✓✓ — quên cái này là lỗi bí ẩn nhất ✗.
2. **IP tĩnh** cho mọi node ✓ (đừng dùng DHCP ✗); firewall mở đúng port nội bộ ✓.
3. **Volume riêng cho data** (NVMe, XFS) ✓ — không dùng `/root` ✗.
4. **THP** = `madvise`/off ✓ (YB khuyến nghị ✓).
5. **ulimit** fd cao (`LimitNOFILE=1048576`) ✓.
6. **1 node / 1 máy** ✓ (đừng chạy 2 node trên 1 VM ✗ — CRDB docs nói rõ ✓).
7. **LB** phía trước (HAProxy cho CRDB ✓; YSQL thì trỏ vào tserver bất kỳ ✓).
8. **Backup**: `yb-admin`/`cockroach backup` + đích S3 ✓ (chưa có backup thì chưa gọi là chạy production ✗).
9. **Monitoring**: Prometheus scrape master/tserver (`:7000/prometheus-metrics`, `:9000/...`) ✓.
10. **Đóng gói lại thành repo/script** ✓ (như `yb-init` ✓) — vì 3 năm sau không ai còn nhớ ✗.

## Chi phí thật (không phải tiền)

| | Setup ban đầu | Vận hành về sau |
|---|---|---|
| 3 node YB/CRDB | **1 buổi → 2 ngày** ✓ | Nâng version ✗ · vá CVE ✗ · disk hỏng ✗ · rebalance ✗ · backup/restore ✗ · **bạn là người duy nhất hiểu nó** ✗ |

⇒ Setup không tệ như cảm giác ✗; **chi phí thật nằm ở "về sau"** ✓ — và đó chính là thứ Aurora/RDS bán ✓.
