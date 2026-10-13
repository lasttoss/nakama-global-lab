# Nakama trên YugabyteDB — CÁCH LÀM ĐƯỢC (đã chứng minh 2026-10-13)

## Kết luận ngược với kết luận ban đầu

Ban đầu tôi kết luận "YB không chạy được với Nakama" vì `nakama migrate up` chết ở 16/20.
**Sai.** YB chạy được — cái chết là ở **cách Nakama THỰC THI** migration, không phải ở SQL.

## Bằng chứng

| bước | kết quả |
|---|---|
| `nakama migrate up` trên YB 2026.1.2 (serializable) | ✗ 16/20 — chết ở `20250926112031-console-fine-grained-acl.sql`, `SQLSTATE 42703 column "role" does not exist` |
| **cùng 20 file SQL đó, áp bằng `ysqlsh`** | ✓ **20/20** |
| Nakama 3.41 start trên YB (không `migrate up`) | ✓ HTTP 200, chạy bình thường |
| 2 node Nakama + 1 YB: auth cùng device | ✓ **cùng user_id** (`ebc151e9-…`) |
| 2 node Nakama + 1 YB: ghi storage ở A → đọc ở B | ✓ **thấy dữ liệu** |
| tra thẳng YB: `select * from storage` / `users` | ✓ dữ liệu thật nằm trong YB (`nakama_ybt`) |

## Cách làm (3 bước) — `scripts/yb-apply-migrations.sh`

1. **YB để mặc định `serializable`** ✓ (chính YB 2026.1.2 trả `default_transaction_isolation=serializable`;
   **đừng** ép READ COMMITTED ✗ — RC chết ngay migration #1 với `SQLSTATE 40001`).
2. **Tự áp schema**: tải 20 file từ `heroiclabs/nakama/migrate/sql`, chạy **chỉ phần `-- +migrate Up`**
   ⚠️ (chạy cả file là chạy luôn phần Down ✗) bằng `ysqlsh`.
3. **Seed `migration_info`** (`id text PRIMARY KEY, applied_at timestamptz`) với 20 dòng, `id` = **tên file
   .sql** (vd `20180103142001_initial_schema.sql`) → rồi start Nakama **không kèm `migrate up`**.

## Vì sao bản cũ (2022) chạy được mà không cần gì

Bài chính thức của Yugabyte (`dev.to/yugabyte/nakama-with-yugabytedb`) dùng **YB 2.14.1.0-b36 +
Nakama 3.13.1**, không đặt flag isolation nào:
- YB thời đó **mặc định serializable** ✓ (nên không cần flag);
- Nakama 3.13.1 **chưa có** migration `20250926112031-console-fine-grained-acl.sql` (thêm 9/2025) ✗
  ⇒ **không bao giờ gặp lỗi `role`** ✓.

⇒ "Ngày xưa 20/20" là thật ✓ — và bây giờ cũng làm được ✓, chỉ thêm 1 bước thủ công.

## Giá phải trả khi chọn đường YB

- Mỗi lần **nâng Nakama** phải chạy lại bước thủ công cho các migration mới ✗ (script hoá được ✓).
- Nếu bước này sai thứ tự / thiếu dòng `migration_info` → Nakama từ chối start ✗ (thông báo rõ ràng ✓).
- Đổi lại: **Apache 2.0 vĩnh viễn, không license key, không giới hạn node, không telemetry** ✓✓.

---

## Tự động hoá: service `yb-init` trong docker-compose

Thay vì chạy tay, `docker-compose.yml` có **service init** làm đúng bước trên:

```yaml
  yb-init:
    image: yugabytedb/yugabyte:${YB_TAG:-2026.1.2.0-b137}
    restart: "no"
    depends_on:
      yb: {condition: service_healthy}          # chờ YSQL lên
    environment: {YB_HOST: yb, YB_PORT: "5433", YB_USER: yugabyte, YB_DB: yugabyte, MIG_DIR: /migrations}
    volumes:
      - ./yb-migrations:/migrations:ro          # 20 file SQL của Nakama (đã commit vào repo)
      - ./scripts/yb-init.sh:/yb-init.sh:ro
    entrypoint: ["/bin/bash","-lc","/yb-init.sh"]

  nakama-a:
    depends_on:
      yb-init: {condition: service_completed_successfully}   # chỉ start SAU khi schema xong
```

⇒ `docker compose up -d` là **chạy hết**: YB boot → `yb-init` áp schema (idempotent) → 2 cell start.
⇒ `nakama migrate up` **đã bị bỏ** khỏi `nakama-a` (trên YB nó sẽ fail).
⇒ `make init` để chạy lại init (đã áp rồi thì bỏ qua — `áp mới=0 bỏ qua=20 ✓`).

### Kết quả đo được

| kiểm chứng | kết quả |
|---|---|
| `yb-init` lần đầu (DB trắng) | ✓ **APPLY 20/20** — kể cả migration `console-fine-grained-acl.sql` mà `nakama migrate up` không qua được |
| `yb-init` lần hai | ✓ **áp mới=0 bỏ qua(đã có)=20** (idempotent) |
| 2 cell start sau init | ✓ healthy, HTTP 200, không lỗi migration |
| `make smoke` (stack YB) | ✓ **PASS=10 FAIL=0 SKIP=1** — account dùng chung ✓ · storage dùng chung ✓ · valkey không share ✓ |
| SKIP duy nhất | nộp điểm qua client API (cần runtime RPC tạo board — phase B ✗) |

### So sánh 2 stack trong repo (cố ý giữ khác nhau)

| | `docker-compose.yml` (**YB**, mặc định) | `docker-compose.crdb.yml` (CRDB) |
|---|---|---|
| Migrate | ✗ **không dùng `nakama migrate up`** | ✓ dùng `nakama migrate up` (chuẩn) |
| Ai áp schema | service **`yb-init`** (ysqlsh + seed `migration_info`) | chính Nakama |
| Vì sao | YB fail ở migration 9/2025 (xem trên) | CRDB chạy 20/20 ✓ |

### Lưu ý vận hành

- Khi nâng Nakama lên bản mới: thêm file SQL mới vào `yb-migrations/` (đổi `MIG_URL`/tải lại) rồi
  `make init` ✓ — script chỉ áp file **chưa có** trong `migration_info` ✓.
- Nếu init fail giữa chừng: nó **dừng ngay** và in 5 dòng lỗi ✓; sửa rồi chạy lại `make init` ✓ (an toàn vì
  chỉ áp phần còn thiếu ✓).
