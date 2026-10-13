# Đo đạc — nakama-global-lab (2026-10-13)

Máy: 12 vCPU / 31 GB RAM · Docker 29.1.3 · Ubuntu 24.04 · **tất cả trên một máy** ⇒ latency ở đây
**không** đại diện latency xuyên region thật ✗. Mục đích là chứng minh **đúng/sai**, không đo địa lý.

Phiên bản: **YugabyteDB 2026.1.2.0-b137** (`yugabytedb/yugabyte:2026.1.2.0-b137`) ·
**Nakama 3.41.0** · **Valkey 8-alpine**.

## Kết quả 1 — "Nakama chạy được trên YB" ⇒ **KHÔNG** (không phải drop-in)

`nakama migrate up` **dừng ở 16/20 migration**, tạo được **17 bảng** (`leaderboard`, `storage`,
`leaderboard_record`, `migration_info`, `console_user`, `groups`, …) rồi chết ✗:

| isolation đã thử | kết quả |
|---|---|
| **READ COMMITTED** (YB docs khuyến nghị cho app không retry) | ✗ **chết ngay file schema đầu tiên** (`20180103142001_initial_schema.sql`) |
| **SERIALIZABLE** | ✓ qua **16 migration** rồi ✗ chết ở `20250926112031-console-fine-grained-acl.sql` |

Hai lỗi khác loại nhau:

1. **SQLSTATE 40001** — `current transaction is expired or aborted (query layer retry isn't possible
   because this is not the first command in the transaction. Consider using READ COMMITTED isolation
   level.)` ⇒ Nakama gửi **nhiều statement trong 1 transaction** ✗; YB chỉ auto-retry được khi câu lỗi
   là **câu đầu tiên** ✗; Nakama **không có retry logic** ✗.
2. **SQLSTATE 42703** — `column "role" does not exist` khi chạy
   `UPDATE console_user SET acl = CASE WHEN role = 1 THEN '{"admin":true}'::JSONB ... END` ✗.

**Điều đáng chú ý**: lỗi (2) **tái hiện được bằng `ysqlsh` thuần** ✗ (không qua Nakama) ⇒ **không phải
lỗi client** ✓; và **không phải cache** (restart YB, session mới vẫn lỗi ✗). Giả thuyết "YB coi `role` là
reserved keyword" đã **kiểm và sai** ✗: `pg_get_keywords()` trả `role|U|unreserved` ✓.
⇒ Hành vi này cần báo upstream (YB issue) — chưa kết luận cơ chế cuối cùng ✓.

**Điều đã chứng minh tốt**: Nakama **kết nối và nhận diện được YB** ✓ —
log `Database information: "PostgreSQL 15.12-YB-2026.1.2.0-b0 ..."` ✓; cell B đọc được trạng thái schema
✗/✓ (`"DB schema outdated, migrations": 20` ✓) ⇒ **connectivity + query cơ bản chạy** ✓, chỉ migration ✗.

## Kết quả 2 — hạ tầng: 5 lỗi thật gặp phải (đều đã fix, ghi để lần sau khỏi mất thời gian)

| # | lỗi | nguyên nhân thật | fix |
|---|---|---|---|
| 1 | `PermissionError: '/home/yugabyte/yb_data/conf'` | volume do root tạo, image chạy uid **10001** gid **100** (`users` ✗ không phải `yugabyte`) | `docker run -u 0 -v vol:/mnt … chown -R 10001:100 /mnt` (`make fix-perm`) |
| 2 | Nakama: `dial tcp <ip>:5433: connection refused` | `yugabyted` single-node bind **127.0.0.1** ✗ (`advertise_address: 127.0.0.1`) | `--tserver_flags=pgsql_proxy_bind_address=0.0.0.0:5433` |
| 3 | healthcheck báo **healthy** trong khi container khác không kết nối được ✗ | healthcheck test **loopback** ✗ | đổi sang `ysqlsh -h $(hostname -i)` ✓ |
| 4 | compose warning `The "i" variable is not set` ✗ | docker compose interpolate `$` | phải viết `$$` trong YAML |
| 5 | port `5433` / `6380` đã bị chiếm | `another project` (5433) + container lab cũ (6380) | dời lab sang dải **20xxx** (20350/20450/20380/20381/20433) |

## Trạng thái hiện tại

- Stack dựng được ✓: `yb` healthy ✓ + 2 valkey ✓ + 2 nakama ✗ (không lên được vì migrate chưa xong)
- `nakama-a`/`nakama-b` đang **dừng** để không spam log ✗; bật lại: `docker compose up -d nakama-a nakama-b`
- Chưa chạy được `make smoke` ✗ (cần migrate xong trước ✓)

## A/B #1 — version YB (đã chạy 2026-10-13)

| YB version | isolation | migrate |
|---|---|---|
| **2026.1.2.0-b137** | READ COMMITTED | ✗ chết ở migration #1 (`20180103142001_initial_schema.sql`) |
| **2026.1.2.0-b137** | SERIALIZABLE | ✓ **16/20**, 17 bảng, chết ở `console-fine-grained-acl.sql` |
| 2025.2.7.0-b107 | SERIALIZABLE | ✗ chết ở migration #1 (40001 "not the first command in the transaction") |
| 2025.2.7.0-b107 | READ COMMITTED | **chưa chạy được** ✗ — lỗi DNS (`lookup yb … server misbehaving`) khi recreate network; không ảnh hưởng kết luận ✓ |

⇒ **Không phải regression ở 2026.1** ✗ — ngược lại: **2026.1.2 đi xa hơn 2025.2.7** ✓.
⇒ Kết luận: đây là **bất tương thích Nakama ↔ YB**, không phải "chọn đúng version là xong" ✗.
Lưu ý công bằng: **tái hiện đúng tuyên bố 2022** cần **Nakama 3.13 + YB 2.14** (bài dev.to) — đó là
A/B #3, **chưa** làm ✓.

Ghi chú kỹ thuật nhỏ nhưng hữu ích: DSN **mặc định** của Nakama là `root@localhost:26257` ✓ — đúng port
mặc định của **CockroachDB** ✓, tức CRDB là DB distributed "mặc định" trong đầu Nakama ✓.

## A/B #2 — CockroachDB v23.2.5 (đã chạy 2026-10-13) — **ĐÂY LÀ KẾT QUẢ CHÍNH**

| hạng mục | kết quả |
|---|---|
| `nakama migrate up` | ✓ **20/20** (`"Successfully applied migration","count":20`) |
| bảng | **20** ✓ |
| 2 cell (nakama 3.41) cùng 1 DB | ✓ **cả 2 healthy** |
| account dùng chung | ✓ **cùng user_id** khi auth ở cell A và cell B (cùng device id) |
| storage dùng chung | ✓ ghi ở A → **cell B đọc thấy** |
| valkey per-cell | ✓ **KHÔNG** share (đúng ranh giới) |
| leaderboard (row) | ✓ row tạo ở A **cả 2 console đọc thấy** (console API cell A 7351 + cell B 7451 trả cùng `smoke_board`) ✓ |
| leaderboard (client API) | ✗ 404/`{}` — board tạo thẳng bằng SQL **không** được node phục vụ qua client path ⇒ phải tạo bằng **runtime RPC** (phase B) ✓ |
| Valkey không share | ✓ |

⇒ **So sánh trực tiếp**: **CRDB 20/20 ✓** vs **YB 2026.1.2 16/20 ✗** vs **YB 2025.2.7 0/20 ✗**
⇒ Vấn đề **là YB-specific** ✓, không phải "Nakama không làm được distributed SQL" ✓.
⇒ Và **câu hỏi #2 (dữ liệu global dùng chung) = CÓ** ✓✓ — chỉ cần **một data plane dùng chung** cho N cell ✓.

### Cách dựng đúng (mất 5 lần mới ra ✗ — ghi để lần sau 1 phát)

1. `--insecure` của CRDB **buộc `--listen-addr=127.0.0.1`** ✗ (cả v23.2.5 và v26.3.2) ⇒ mọi service phải
   dùng **host networking** mới nói chuyện được ✓ (hoặc TLS ✓).
2. Nakama 3.41: server key phải gửi bằng **HTTP Basic** (`Authorization: Basic base64("defaultkey:")`) ✓
   — `Bearer defaultkey` **không** còn đúng ✗.
3. `device id` phải **10–128 bytes** ✗ (short · bị 400 ✓).
4. API dùng **protobuf-JSON**: `value` của storage là **string** ✗ (không phải object ✓); `score` cũng là
   **string** ✓ ("10" ✓).
5. Tạo leaderboard qua HTTP API: `POST /v2/leaderboard` → **404** ✗ ⇒ trong 3.41 phải tạo qua **runtime
   RPC** ✓ (hoặc console ✓). Row chèn thẳng SQL **không** được node đăng ký ✗ (registry trong RAM ✓) ⇒
   cần runtime hoặc restart node ✓.
6. `response` của `authenticate/device` **không có object `user`** ✗ ⇒ uid phải lấy từ `GET /v2/account`
   (hoặc decode JWT ✓).
7. `valkey-cli` trong container chạy port khác (6380) phải thêm `-p 6380` ✗.

## Stack YUGABYTEDB — giờ CHẠY ĐƯỢC (compose tự init) — 2026-10-13

Xem `docs/yugabyte-workaround.md`. Điểm chính:

| | kết quả |
|---|---|
| `nakama migrate up` trên YB | ✗ 16/20 (chết ở `20250926112031-console-fine-grained-acl.sql`, `column "role" does not exist`) |
| **cùng 20 file SQL, áp bằng `ysqlsh`** | ✓ **20/20** ⇒ lỗi ở cách Nakama chạy, KHÔNG phải SQL/YB |
| service **`yb-init`** trong compose (tự động) | ✓ APPLY 20/20 · chạy lại: bỏ qua 20 (idempotent) |
| `make smoke` trên stack YB | ✓ **PASS=10 FAIL=0 SKIP=1** — account ✓ storage ✓ dùng chung · valkey ✗ không share |
| SKIP | nộp điểm qua client API (cần runtime RPC — phase B) |
| tra thẳng YB | ✓ `select * from storage` / `users` / `migration_info` thấy dữ liệu thật |

⇒ Kết luận cũ "YB không chạy được với Nakama" là **SAI** ✗ — YB là lựa chọn **license sạch (Apache 2.0)** và
**còn được vá**, đổi lại: phải dùng bước init thủ công (đã tự động hoá ✓).

## Bước tiếp theo (đề xuất, chưa làm)

1. **A/B version YB**: thử `2025.2.7.0-b107` (423 MB) và `2.25.x` — nếu migrate qua ⇒ **regression ở
   2026.1** ✗✓ (kết luận rất có giá trị, và rẻ: đổi 1 dòng tag ✓).
2. **A/B sang CockroachDB** cùng bộ test ⇒ giải thích được vì sao Nakama hỗ trợ CRDB ✓ mà YB thì không ✓.
3. **A/B Nakama 3.32** (bản thời bài dev.to 2022 ✓) ⇒ xác định lỗi đến từ phía Nakama mới hay YB mới ✓.
4. Nếu muốn đi tiếp bằng YB: phải xử lý ở tầng migration ✗ — patch runner để **retry + tách transaction**
   ✓ (không phải việc nhỏ ✓, và là lý do đủ để cân nhắc lại lựa chọn YB ✓).
