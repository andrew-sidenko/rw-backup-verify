#!/usr/bin/env bash
# Живой e2e: настоящий Docker + postgres. Собирает синтетический bot-архив
# (как custom-restore: PROFILE.env + postgres_dump.sql.gz + redis RDB +
# project_dir.tar.gz) и гоняет НАСТОЯЩИЙ rbv-run-one.sh.
#
# Проверяет то, что сломалось в проде:
#   A) полный цикл: download → extract → restore → user_rows → event_freshness
#      → stack в --internal → зелёный отчёт;
#   B) внешний `docker rm -f` песочницы классифицируется как external
#      (а не «OOM rc=137») и прогон становится retryable (exit 75, не в tested).
#
# Пропускается, если Docker недоступен.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL $1 — $2"; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: нет доступного Docker — живой тест пропущен"
  exit 0
fi

T="$(mktemp -d)"
cleanup() {
  docker ps -aq --filter 'name=rbv_pg_' --filter 'name=rbv_probe_' \
    --filter 'name=rbv_iso_' --filter 'name=rbv_preflight_' 2>/dev/null \
    | while IFS= read -r c; do [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1; done || true
  docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^rbv' \
    | while IFS= read -r n; do docker network rm "$n" >/dev/null 2>&1; done || true
  rm -rf "$T"
}
trap cleanup EXIT

export RBV_CONFIG="$T/config.json"
export RBV_STATE_DIR="$T/state"
mkdir -p "$RBV_STATE_DIR" "$T/bin" "$T/s3" "$T/build"

# --- config ----------------------------------------------------------------
jq -n '{
  version:1, pg_version:"17", settle_seconds:3, runs_keep:2,
  notify_on_success:false,
  verify:{interval_hours:12},
  checks:{
    timezone_skew_hours:14, stability_seconds:8, preflight_isolation:true,
    bot:{user_rows:true, event_freshness:true, stack:true, isolation:true, backend_ports:false},
    panel:{user_rows:true, event_freshness:true, stack:false, isolation:true, backend_ports:false}
  },
  telegram:{token:"", chat_id:"", thread_id:""},
  storages:[{id:"live", endpoint:"", bucket:"b", access_key:"a", secret_key:"s",
             region:"us-east-1", prefix:"", backup_hint:"test", telegram:{}}]
}' >"$RBV_CONFIG"

# --- mock aws: s3 cp из локального каталога --------------------------------
cat >"$T/bin/aws" <<'AWS'
#!/bin/bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint-url|--region|--profile) shift 2 ;;
    --*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
if [[ "${1:-}" == "s3" && "${2:-}" == "cp" ]]; then
  key="${3#s3://b/}"
  cp "${RBV_TEST_S3}/${key}" "$4"
  exit $?
fi
echo "unexpected aws: $*" >&2
exit 1
AWS
chmod +x "$T/bin/aws"
export RBV_TEST_S3="$T/s3"
export PATH="$T/bin:$PATH"

# --- синтетический бэкап бота ----------------------------------------------
ARCH_TS="$(date -u +%Y%m%d_%H%M%S)"
EVENT_TS="$(date -u -d '-1 hour' '+%Y-%m-%d %H:%M:%S')"
ROWS="${RBV_TEST_ROWS:-20000}"

B="$T/build"
mkdir -p "$B/swarm"
{
  echo "SET statement_timeout = 0;"
  echo "SET client_encoding = 'UTF8';"
  echo "SET standard_conforming_strings = on;"
  # как на проде: дамп кластера (pg_dumpall) — приложение живёт в своей БД,
  # а `postgres` остаётся пустым. Проверяем, что выбирается именно vpnbot.
  echo "CREATE DATABASE vpnbot;"
  echo "\\connect vpnbot"
  # владелец, которого нет в песочнице → проверяем rbv_pg_precreate_roles
  echo "CREATE TABLE public.users (id bigint NOT NULL, telegram_id bigint, username text, created_at timestamp with time zone, updated_at timestamp with time zone);"
  echo "ALTER TABLE public.users OWNER TO botuser;"
  echo "CREATE TABLE public.subscriptions (id bigint NOT NULL, user_id bigint, tariff text, created_at timestamp with time zone);"
  echo "ALTER TABLE public.subscriptions OWNER TO botuser;"
  # у этого «бота» есть не все таблицы групп — это норма
  echo "CREATE TABLE public.tariffs (id bigint NOT NULL, name text);"
  echo "INSERT INTO public.tariffs VALUES (1,'base'),(2,'pro');"
  echo "CREATE TABLE public.recurring_yookassa (id bigint NOT NULL, user_id bigint);"
  echo "CREATE TABLE public.payment_webhook_events (id bigint NOT NULL, provider text, payload text, created_at timestamp with time zone, processed_at timestamp with time zone);"
  echo "ALTER TABLE public.payment_webhook_events OWNER TO botuser;"
  echo "COPY public.users (id, telegram_id, username, created_at, updated_at) FROM stdin;"
  awk -v n="$ROWS" -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=n;i++) printf "%d\t%d\tuser%d\t%s+00\t%s+00\n", i, 100000+i, i, ts, ts}'
  echo '\.'
  echo "COPY public.subscriptions (id, user_id, tariff, created_at) FROM stdin;"
  awk -v n="$ROWS" -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=n;i++) printf "%d\t%d\tbase\t%s+00\n", i, i, ts}'
  echo '\.'
  echo "COPY public.payment_webhook_events (id, provider, payload, created_at, processed_at) FROM stdin;"
  awk -v n="$ROWS" -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=n;i++) printf "%d\tyookassa\t{\"id\":%d}\t%s+00\t%s+00\n", i, i, ts, ts}'
  echo '\.'
  echo "ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);"
  echo "ALTER TABLE ONLY public.subscriptions ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);"
  echo "ALTER TABLE ONLY public.payment_webhook_events ADD CONSTRAINT pwe_pkey PRIMARY KEY (id);"
  echo "CREATE INDEX users_tg_idx ON public.users USING btree (telegram_id);"
  echo "GRANT ALL ON TABLE public.users TO botuser;"
} | gzip -1 >"$B/postgres_dump.sql.gz"

# без POSTGRES_DB: на проде PROFILE.env в архиве бота вообще нет — БД должна
# определяться по содержимому кластера, а не по подсказке
printf 'POSTGRES_SERVICE=postgres\nREDIS_SERVICE=redis\n' >"$B/PROFILE.env"
printf 'REDIS0011fake' >"$B/redis_dump.rdb"

cat >"$B/swarm/docker-compose.yml" <<'YML'
services:
  bot:
    image: alpine:3.20
    command: ["sleep", "600"]
    environment:
      DATABASE_URL: postgresql://botuser:secret@10.0.0.5:5432/postgres
      REDIS_HOST: 10.0.0.6
    ports:
      - "8081:8080"
    volumes:
      - ./volumes/redis:/data
  postgres:
    image: postgres:17-alpine
    volumes:
      - ./pgdata:/var/lib/postgresql/data
YML
printf 'PROJECT_NAME=livetest\n' >"$B/swarm/.env"
tar -czf "$B/project_dir.tar.gz" -C "$B" swarm

KEY="bots/live/custom_bot_livetest_${ARCH_TS}.tar.gz"
mkdir -p "$(dirname "${T}/s3/${KEY}")"
tar -czf "${T}/s3/${KEY}" -C "$B" postgres_dump.sql.gz PROFILE.env redis_dump.rdb project_dir.tar.gz
echo "архив: $(du -h "${T}/s3/${KEY}" | awk '{print $1}') (${ROWS} строк на таблицу)"

docker pull alpine:3.20 >/dev/null 2>&1 || true

# --- A) полный happy-path ---------------------------------------------------
echo "==== A) полный цикл bot ===="
set +e
out="$("$ROOT/bin/rbv-run-one.sh" live bot "bot:bots/live:custom_bot_livetest" \
  "$KEY" "bots/live" manual 2>&1)"
rc=$?
set -e
run_dir="$(ls -1dt "$RBV_STATE_DIR"/runs/*/ 2>/dev/null | head -n1 || true)"
run_dir="${run_dir%/}"
checks="${run_dir}/checks.json"
if [[ "$rc" -ne 0 ]]; then
  echo "--- report (tail 60) ---"
  tail -n 60 "${run_dir}/report.txt" 2>/dev/null || printf '%s\n' "${out: -3000}"
  echo "--- end ---"
fi
[[ "$rc" -eq 0 ]] && pass "run-one rc=0" || fail "run-one rc=0" "rc=$rc"

st(){ jq -r --arg n "$1" '[.[]|select(.name==$n)][-1].status // "—"' "$checks" 2>/dev/null; }
dt(){ jq -r --arg n "$1" '[.[]|select(.name==$n)][-1].detail // "—"' "$checks" 2>/dev/null; }

[[ "$(st download)" == "ok" ]] && pass "download ok" || fail "download" "$(dt download)"
[[ "$(st db_restore)" == "ok" ]] && pass "db_restore ok" || fail "db_restore" "$(dt db_restore)"
[[ "$(st db_schema)" == "ok" ]] && pass "db_schema ok" || fail "db_schema" "$(dt db_schema)"
[[ "$(st bot_users)" == "ok" ]] && pass "bot_users ok" || fail "bot_users" "$(dt bot_users)"
[[ "$(st bot_payments)" == "ok" ]] && pass "bot_payments ok" || fail "bot_payments" "$(dt bot_payments)"
[[ "$(dt bot_users)" == *"3/6 таблиц"* ]] && pass "неполный набор users-таблиц не ошибка" \
  || fail "неполный набор users" "$(dt bot_users)"
[[ "$(dt bot_users)" == *"нет: app_settings"* ]] && pass "отсутствующие таблицы перечислены" \
  || fail "список отсутствующих" "$(dt bot_users)"
[[ "$(dt bot_payments)" == *"2/5 таблиц"* ]] && pass "неполный набор payments-таблиц не ошибка" \
  || fail "неполный набор payments" "$(dt bot_payments)"
[[ "$(dt bot_payments)" == *"recurring_yookassa=0"* ]] && pass "пустая таблица платежей не ошибка" \
  || fail "пустая payments-таблица" "$(dt bot_payments)"
[[ "$(st event_freshness)" == "ok" ]] && pass "event_freshness ok" || fail "event_freshness" "$(dt event_freshness)"
[[ "$(st isolation)" == "ok" ]] && pass "isolation ok" || fail "isolation" "$(dt isolation)"
[[ "$(st stack)" == "ok" ]] && pass "stack ok" || fail "stack" "$(dt stack)"

grep -q 'db_schema: db=vpnbot' "${run_dir}/report.txt" \
  && pass "выбрана БД приложения (vpnbot), а не пустая postgres" \
  || fail "выбор БД" "$(grep 'db_schema:' "${run_dir}/report.txt" || true)"
grep -q 'кандидаты: .*vpnbot=5+users' "${run_dir}/report.txt" \
  && pass "кандидаты БД в отчёте" || fail "кандидаты БД" "$(grep 'db_schema:' "${run_dir}/report.txt" || true)"

users="$(jq -r '.user_rows' "${run_dir}/summary.json" 2>/dev/null || echo 0)"
[[ "$users" == "$ROWS" ]] && pass "user_rows=${ROWS}" || fail "user_rows count" "got=$users"
tables="$(jq -r '.db_tables' "${run_dir}/summary.json" 2>/dev/null || echo 0)"
[[ "$tables" == "5" ]] && pass "db_tables=5" || fail "db_tables" "got=$tables"

# baseline должен запомнить строки по каждой таблице — иначе пропажу
# данных не с чем сравнивать на следующей проверке
bl="${RBV_STATE_DIR}/baselines/live/$(printf '%s' 'bot:bots/live:custom_bot_livetest' | sha256sum | awk '{print $1}').json"
[[ -n "$bl" && -f "$bl" ]] && pass "baseline записан" || fail "baseline" "нет файла"
jq -e --argjson n "$ROWS" '.tables.users == $n and .tables.subscriptions == $n
   and .tables.tariffs == 2 and .tables.recurring_yookassa == 0' "$bl" >/dev/null 2>&1 \
  && pass "в baseline строки по каждой таблице" || fail "baseline tables" "$(jq -c '.tables' "$bl" 2>/dev/null)"

grep -q 'заранее созданы роли из дампа' "${run_dir}/report.txt" \
  && pass "роли из дампа созданы заранее" || fail "precreate roles" "нет строки в report"
errs="$(grep -cE 'ERROR' "${run_dir}/psql.err" 2>/dev/null || true)"
errs="$(echo "${errs:-0}" | tr -d '[:space:]')"
[[ "$errs" == "0" ]] && pass "restore без ERROR" || fail "restore ERROR=${errs}" "$(head -c 300 "${run_dir}/psql.err")"

# DATABASE_URL должен указывать на песочницу, а postgres-сервис — вырезан
grep -q 'remnawave-db:5432' "${run_dir}/compose.isolated.yml" \
  && pass "DATABASE_URL → sandbox" || fail "DATABASE_URL rewrite" "нет remnawave-db"
jq -e '(.services|keys) == ["bot"]' "${run_dir}/compose.isolated.yml" >/dev/null \
  && pass "postgres-сервис вырезан" || fail "postgres вырезан" "$(jq -c '.services|keys' "${run_dir}/compose.isolated.yml")"
jq -e '[.services.bot.volumes[]? | (.source? // .)] | map(select(test("pgdata"))) | length == 0' \
  "${run_dir}/compose.isolated.yml" >/dev/null \
  && pass "pgdata-бинды вырезаны" || fail "pgdata бинды" "остались"

# --- A2) следующий бэкап того же бота: данные пропали -----------------------
# Отсутствие таблицы у бота — норма, но если таблица БЫЛА с данными и исчезла,
# или строк стало меньше — это потеря данных, и прогон обязан упасть.
echo "==== A2) пропажа данных относительно прошлой проверки ===="
{
  echo "CREATE DATABASE vpnbot;"
  echo "\\connect vpnbot"
  echo "CREATE TABLE public.users (id bigint NOT NULL, telegram_id bigint, username text, created_at timestamp with time zone, updated_at timestamp with time zone);"
  echo "ALTER TABLE public.users OWNER TO botuser;"
  echo "COPY public.users (id, telegram_id, username, created_at, updated_at) FROM stdin;"
  awk -v n="$(( ROWS / 2 ))" -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=n;i++) printf "%d\t%d\tuser%d\t%s+00\t%s+00\n", i, 100000+i, i, ts, ts}'
  echo '\.'
  echo "CREATE TABLE public.tariffs (id bigint NOT NULL, name text);"
  echo "INSERT INTO public.tariffs VALUES (1,'base'),(2,'pro');"
  echo "CREATE TABLE public.payment_webhook_events (id bigint NOT NULL, provider text, created_at timestamp with time zone);"
  echo "COPY public.payment_webhook_events (id, provider, created_at) FROM stdin;"
  awk -v n="$ROWS" -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=n;i++) printf "%d\tyookassa\t%s+00\n", i, ts}'
  echo '\.'
} | gzip -1 >"$B/postgres_dump.sql.gz"
KEY_LOSS="bots/live/custom_bot_livetest_$(date -u -d '+2 minutes' +%Y%m%d_%H%M%S).tar.gz"
tar -czf "${T}/s3/${KEY_LOSS}" -C "$B" postgres_dump.sql.gz PROFILE.env redis_dump.rdb project_dir.tar.gz
set +e
"$ROOT/bin/rbv-run-one.sh" live bot "bot:bots/live:custom_bot_livetest" \
  "$KEY_LOSS" "bots/live" manual >"$T/a2.log" 2>&1
rc_a2=$?
set -e
run_a2="$(ls -1dt "$RBV_STATE_DIR"/runs/*/ 2>/dev/null | head -n1)"
run_a2="${run_a2%/}"
checks_a2="${run_a2}/checks.json"
st2(){ jq -r --arg n "$1" '[.[]|select(.name==$n)][-1].status // "—"' "$checks_a2" 2>/dev/null; }
dt2(){ jq -r --arg n "$1" '[.[]|select(.name==$n)][-1].detail // "—"' "$checks_a2" 2>/dev/null; }

[[ "$rc_a2" -ne 0 ]] && pass "пропажа данных → прогон FAIL" || fail "пропажа данных" "rc=$rc_a2"
[[ "$(st2 bot_users)" == "fail" ]] && pass "bot_users fail" || fail "bot_users fail" "$(st2 bot_users)"
grep -q "subscriptions: таблица исчезла" "${run_a2}/report.txt" \
  && pass "исчезнувшая таблица названа" || fail "исчезнувшая таблица" "$(grep -c subscriptions "${run_a2}/report.txt")"
grep -qE "users: строк $(( ROWS / 2 )) \(было ${ROWS}\)" "${run_a2}/report.txt" \
  && pass "падение строк users показано с прошлым значением" \
  || fail "падение строк" "$(grep -E '  ❌|  ✅' "${run_a2}/report.txt" | head -5)"
# платежи выросли — их группа обязана остаться зелёной
[[ "$(st2 bot_payments)" == "ok" ]] && pass "выросшая группа платежей осталась ok" \
  || fail "bot_payments" "$(dt2 bot_payments)"

# --- B) внешний kill песочницы ---------------------------------------------
# Ровно то, что делал параллельный `run`/`reclaim` из systemd-тика.
echo "==== B) внешний docker rm -f во время restore ===="
rm -rf "${RBV_STATE_DIR:?}/runs"

# дамп побольше: restore должен идти несколько секунд, чтобы попасть в него
ROWS_B="${RBV_TEST_ROWS_BIG:-800000}"
{
  echo "CREATE TABLE public.users (id bigint NOT NULL, telegram_id bigint, username text, created_at timestamp with time zone, updated_at timestamp with time zone);"
  echo "ALTER TABLE public.users OWNER TO botuser;"
  echo "COPY public.users (id, telegram_id, username, created_at, updated_at) FROM stdin;"
  awk -v n="$ROWS_B" -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=n;i++) printf "%d\t%d\tuser%d\t%s+00\t%s+00\n", i, 100000+i, i, ts, ts}'
  echo '\.'
  echo "CREATE TABLE public.payment_webhook_events (id bigint NOT NULL, provider text, created_at timestamp with time zone);"
  echo "ALTER TABLE public.payment_webhook_events OWNER TO botuser;"
  echo "COPY public.payment_webhook_events (id, provider, created_at) FROM stdin;"
  awk -v ts="$EVENT_TS" 'BEGIN{for(i=1;i<=100;i++) printf "%d\tyookassa\t%s+00\n", i, ts}'
  echo '\.'
  echo "ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);"
} | gzip -1 >"$B/postgres_dump.sql.gz"
KEY_B="bots/live/custom_bot_livebig_${ARCH_TS}.tar.gz"
tar -czf "${T}/s3/${KEY_B}" -C "$B" postgres_dump.sql.gz PROFILE.env redis_dump.rdb project_dir.tar.gz

(
  # ждём, пока restore реально начнётся (строка в report), и сносим песочницу
  for _ in $(seq 1 2400); do
    if grep -rqs 'psql restore: postgres_dump' "${RBV_STATE_DIR}/runs" 2>/dev/null; then
      docker ps -q --filter 'name=rbv_pg_' 2>/dev/null \
        | while IFS= read -r c; do [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1; done
      exit 0
    fi
    sleep 0.1
  done
) >/dev/null 2>&1 &
killer=$!

set +e
RBV_RESTORE_MAX_ATTEMPTS=1 "$ROOT/bin/rbv-run-one.sh" live bot \
  "bot:bots/live:custom_bot_livebig" "$KEY_B" "bots/live" manual >"$T/b.log" 2>&1
rc_b=$?
set -e
kill "$killer" 2>/dev/null || true
wait "$killer" 2>/dev/null || true

run_b="$(ls -1dt "$RBV_STATE_DIR"/runs/*/ 2>/dev/null | head -n1 || true)"
run_b="${run_b%/}"
[[ "$rc_b" -eq 75 ]] && pass "внешний kill → exit 75 (retryable, не в tested)" \
  || fail "exit 75" "rc=$rc_b"
[[ -f "${run_b}/.retryable" ]] && pass "маркер .retryable" || fail ".retryable" "нет файла"
grep -q 'песочницу удалили снаружи' "${run_b}/report.txt" \
  && pass "диагноз: внешнее удаление" || fail "диагноз external" "$(grep -E 'psql restore: итог' "${run_b}/report.txt" || true)"
grep -q 'class=external' "${run_b}/report.txt" \
  && pass "class=external" || fail "class=external" "$(grep -E 'psql restore: итог' "${run_b}/report.txt" || true)"
grep -qE 'OOM|не хватило RAM' "${run_b}/report.txt" \
  && fail "ложный диагноз OOM" "внешний kill выдан за нехватку памяти" \
  || pass "OOM не приписан"
# данные-проверки не должны врать про «нет таблицы users»
grep -q 'users table missing' "${run_b}/report.txt" \
  && fail "ложный users table missing" "на оборванном restore" \
  || pass "нет ложного users table missing"

# --- C) параллельная уборка не должна ломать живой прогон -------------------
# Продовый сценарий один в один: пока идёт restore, стартует уборка
# (раньше — из systemd-тика раз в минуту) и делает docker rm -f rbv_pg_*
# + runs prune keep=0.
echo "==== C) reclaim --docker --force во время restore ===="
rm -rf "${RBV_STATE_DIR:?}/runs"
"$ROOT/bin/rbv-run-one.sh" live bot "bot:bots/live:custom_bot_livebig" \
  "$KEY_B" "bots/live" manual >"$T/c.log" 2>&1 &
runner=$!
reclaimed=0
for _ in $(seq 1 1200); do
  if grep -rqs 'psql restore: postgres_dump' "${RBV_STATE_DIR}/runs" 2>/dev/null; then
    sleep 1
    "$ROOT/bin/rw-backup-verify" reclaim --docker --force >"$T/c.reclaim.log" 2>&1 || true
    reclaimed=1
    break
  fi
  kill -0 "$runner" 2>/dev/null || break
  sleep 0.25
done
set +e
wait "$runner"
rc_c=$?
set -e
[[ "$reclaimed" == "1" ]] && pass "reclaim успел стартовать во время restore" \
  || fail "reclaim во время restore" "не стартовал"
grep -q 'занят живым прогоном' "$T/c.reclaim.log" \
  && pass "reclaim пропустил артефакты живого прогона" \
  || fail "reclaim пропуск" "$(tail -n 20 "$T/c.reclaim.log")"

run_c="$(ls -1dt "$RBV_STATE_DIR"/runs/*/ 2>/dev/null | head -n1 || true)"
run_c="${run_c%/}"
if [[ "$rc_c" -ne 0 ]]; then
  echo "--- report (tail 40) ---"
  tail -n 40 "${run_c}/report.txt" 2>/dev/null || tail -n 40 "$T/c.log"
  echo "--- end ---"
fi
[[ "$rc_c" -eq 0 ]] && pass "прогон пережил параллельную уборку (rc=0)" \
  || fail "прогон пережил уборку" "rc=$rc_c"
[[ -d "$run_c" ]] && pass "runs prune keep=0 не снёс живой run" || fail "живой run удалён" "нет каталога"
st_c="$(jq -r '[.[]|select(.name=="db_restore")][-1].status // "—"' "${run_c}/checks.json" 2>/dev/null)"
[[ "$st_c" == "ok" ]] && pass "db_restore ok несмотря на уборку" || fail "db_restore под уборкой" "$st_c"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
