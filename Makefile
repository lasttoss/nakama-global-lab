SHELL := /bin/bash
API_A := http://127.0.0.1:20350
API_B := http://127.0.0.1:20450
KEY   := defaultkey
YB_TAG ?= 2026.1.2.0-b137

.PHONY: pull up down logs ps init init-logs smoke smoke-crdb trap clean fix-perm test lint manifest

# ── stack YugabyteDB (mặc định) ───────────────────────────────────────────────
fix-perm: ; docker volume create nkglobal_yb_data >/dev/null; docker run --rm -u 0 -v nkglobal_yb_data:/mnt --entrypoint bash yugabytedb/yugabyte:$(YB_TAG) -c 'chown -R 10001:100 /mnt'
pull:     ; docker compose pull
up:       ; docker compose up -d --wait --wait-timeout 600
down:     ; docker compose down
ps:       ; docker compose ps
logs:     ; docker compose logs --tail=80 yb yb-init nakama-a nakama-b

# ── init data plane (thay cho `nakama migrate up`, xem docs/findings.md) ──────
init:      ; docker compose run --rm yb-init
init-logs: ; docker compose logs yb-init

# ── kiểm chứng ───────────────────────────────────────────────────────────────
smoke: ; API_A=http://127.0.0.1:20350 API_B=http://127.0.0.1:20450 CONSOLE_A=http://127.0.0.1:20351 \
         VK_A=nkglobal-valkey-a VK_B=nkglobal-valkey-b VK_PORT_A=6379 VK_PORT_B=6379 \
         SQL_EXEC="docker exec nkglobal-yb /home/yugabyte/bin/ysqlsh -h 127.0.0.1 -U yugabyte -d yugabyte -c" \
         bash scripts/smoke.sh
smoke-crdb: ; API_A=http://127.0.0.1:7350 API_B=http://127.0.0.1:7450 CONSOLE_A=http://127.0.0.1:7351 \
         VK_A=nkcrdb-valkey-a VK_B=nkcrdb-valkey-b bash scripts/smoke.sh
trap:  ; bash scripts/leaderboard-trap.sh
clean: ; docker compose down -v

# ── kiểm tra tĩnh (không cần Docker; CI chạy đúng những cái này) ──────────────
test: lint manifest
lint: ; bash scripts/check-secrets.sh
	python3 scripts/check-docs-links.py
	docker compose config -q
	docker compose -f docker-compose.crdb.yml config -q
	@echo "OK: tất cả kiểm tra tĩnh đã qua"
manifest: ; bash scripts/check-sql-manifest.sh
regen-manifest: ; ( cd yb-migrations && find . -maxdepth 1 -name '*.sql' | sed 's|^\\./||' | sort | xargs sha256sum > MANIFEST.sha256 )
	@echo "MANIFEST.sha256 đã tạo lại"
