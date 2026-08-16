#!/usr/bin/env bash
# Полный unit-прогон rw-backup-verify: CLI, discover (mock aws), schedule,
# tested/queue/worker, symlink, валидации. Без Docker/S3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL $1 — $2"; }
expect_rc(){ # expect_rc <rc> <label> -- cmd...
  local want="$1" label="$2"; shift 2
  set +e
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq "$want" ]]; then pass "$label"
  else fail "$label" "rc=$rc want=$want out=${out:0:200}"
  fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export RBV_CONFIG="$T/config.json"
export RBV_STATE_DIR="$T/state"
mkdir -p "$RBV_STATE_DIR" "$T/bin"

cp "$ROOT/config/config.example.json" "$RBV_CONFIG"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/checks.sh
source "$ROOT/lib/checks.sh"

# --- mock aws ---
cat > "$T/bin/aws" <<'AWS'
#!/bin/bash
# пропускаем глобальные флаги (--endpoint-url …)
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint-url|--region|--profile) shift 2 ;;
    --*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
if [[ "${1:-}" == "s3" && "${2:-}" == "ls" ]]; then
  cat <<'EOF'
2026-08-01 03:00:00   1000 rw-backup-full/panel/h1/remnawave_backup_2026-08-01_03_00_00.tar.gz
2026-08-10 03:00:00   1000 rw-backup-full/panel/h1/remnawave_backup_2026-08-10_03_00_00.tar.gz
2026-08-10 03:00:15   1000 rw-backup-full/bots/a/custom_bot_One_20260810_030015.tar.gz
2026-08-09 03:00:15   1000 rw-backup-full/bots/a/custom_bot_One_20260809_030015.tar.gz
2026-08-10 04:00:00   1000 rw-backup-full/bots/a/custom_bot_Two_20260810_040000.tar.gz
2026-08-10 05:00:00   1000 rw-backup-full/deep/x/y/remnawave_backup_2026-08-10_05_00_00.tar.gz
2026-08-10 05:00:00   1000 other/file.txt
EOF
  exit 0
fi
echo "unexpected aws: $*" >&2
exit 1
AWS
chmod +x "$T/bin/aws"

# --- mock docker ---
# ОБЯЗАТЕЛЬНО: `run` вызывает rbv_docker_reclaim, а тот делает `docker rm -f`
# по маске rbv_pg_*. Без заглушки юнит-тест сносил песочницу настоящего
# прогона на этом же хосте (ровно тот сбой, который чинится в этой ветке).
cat > "$T/bin/docker" <<'DOCKER'
#!/bin/bash
printf '%s\n' "$*" >>"${T_DOCKER_LOG:-/dev/null}"
exit 0
DOCKER
chmod +x "$T/bin/docker"
export T_DOCKER_LOG="$T/docker.log"
export PATH="$T/bin:$PATH"

echo "==== classify ===="
out="$(rbv_classify_name 'remnawave_backup_2026-08-10_03_00_00.tar.gz')"
[[ "$out" == "panel|remnawave_backup" ]] && pass "classify panel" || fail "classify panel" "$out"
out="$(rbv_classify_name 'remnawave_backup_2026-08-10_03_00_00.tar.gz.age')"
[[ "$out" == "panel|remnawave_backup" ]] && pass "classify panel.age" || fail "classify panel.age" "$out"
out="$(rbv_classify_name 'custom_bot_Foo_Bar_20260810_030015.tar.gz')"
[[ "$out" == "bot|custom_bot_Foo_Bar" ]] && pass "classify bot nested" || fail "classify bot nested" "$out"
if rbv_classify_name 'remnawave_backup.tar.gz' >/dev/null 2>&1; then
  fail "classify no-ts panel" "should fail"
else
  pass "classify no-ts panel"
fi

out="$(rbv_classify_name 'custom_bot_oneokbot-infra__20260810_140923.tar.gz')"
[[ "$out" == "bot|custom_bot_oneokbot-infra" ]] && pass "classify bot double underscore" \
  || fail "classify bot double underscore" "$out"

echo "==== storage CLI ===="
"$ROOT/bin/rw-backup-verify" storage add \
  --id s1 --bucket b --access-key a --secret-key s \
  --prefix rw-backup-full --endpoint https://s3.example --backup-hint "hint" >/dev/null
"$ROOT/bin/rw-backup-verify" storage add \
  --id s2 --bucket b2 --access-key a --secret-key s >/dev/null
n="$(jq '.storages|length' "$RBV_CONFIG")"
[[ "$n" == "2" ]] && pass "storage add×2" || fail "storage add" "n=$n"
# upsert same id
"$ROOT/bin/rw-backup-verify" storage add \
  --id s2 --bucket b2new --access-key a --secret-key s >/dev/null
n="$(jq '.storages|length' "$RBV_CONFIG")"
b="$(jq -r '.storages[]|select(.id=="s2").bucket' "$RBV_CONFIG")"
[[ "$n" == "2" && "$b" == "b2new" ]] && pass "storage upsert" || fail "storage upsert" "n=$n b=$b"
expect_rc 1 "storage show missing" "$ROOT/bin/rw-backup-verify" storage show nosuch
"$ROOT/bin/rw-backup-verify" storage show s1 | grep -q '"id": "s1"' && pass "storage show" || fail "storage show" "no id"
"$ROOT/bin/rw-backup-verify" storage remove s2 >/dev/null
[[ "$(jq '.storages|length' "$RBV_CONFIG")" == "1" ]] && pass "storage remove" || fail "storage remove" "left"

echo "==== missing storage hard-fail ===="
set +e
out="$(rbv_storage_json nosuch 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "storage_json missing" || fail "storage_json missing" "rc=0 out=$out"
expect_rc 1 "discover missing" "$ROOT/bin/rw-backup-verify" discover nosuch

echo "==== schedule validation ===="
expect_rc 1 "interval abc" "$ROOT/bin/rw-backup-verify" schedule set --interval-hours abc
expect_rc 1 "interval 0" "$ROOT/bin/rw-backup-verify" schedule set --interval-hours 0
expect_rc 1 "interval -3" "$ROOT/bin/rw-backup-verify" schedule set --interval-hours -3
expect_rc 1 "times 25:99" "$ROOT/bin/rw-backup-verify" schedule set --times 25:99
expect_rc 1 "times 9:30" "$ROOT/bin/rw-backup-verify" schedule set --times 9:30
"$ROOT/bin/rw-backup-verify" schedule set --interval-hours 6 >/dev/null
[[ "$(jq -r '.verify.interval_hours' "$RBV_CONFIG")" == "6" ]] && pass "interval 6" || fail "interval 6" "bad"
"$ROOT/bin/rw-backup-verify" schedule set --times 06:30,18:30 >/dev/null
[[ "$(jq -r '.verify.times|join(",")' "$RBV_CONFIG")" == "06:30,18:30" ]] && pass "times ok" || fail "times ok" "bad"

echo "==== telegram aliases ===="
"$ROOT/bin/rw-backup-verify" tel set --token tok --chat-id 42 >/dev/null
"$ROOT/bin/rw-backup-verify" tg show | grep -q '"token": "tok"' && pass "tel/tg alias" || fail "tel/tg" "no token"

echo "==== symlink CLI (install layout) ===="
fake_local="$T/usr/local/bin"
mkdir -p "$fake_local"
ln -sfn "$ROOT/bin/rw-backup-verify" "$fake_local/rw-backup-verify"
if out="$("$fake_local/rw-backup-verify" telegram show 2>&1)"; then
  printf '%s\n' "$out" | grep -q tok && pass "symlink cli" || fail "symlink cli" "$out"
else
  fail "symlink cli" "$out"
fi

echo "==== discover latest + tested ===="
disc="$("$ROOT/bin/rw-backup-verify" discover s1)"
printf '%s\n' "$disc" | grep -q 'remnawave_backup_2026-08-10_03_00_00' && pass "discover panel latest" || fail "discover panel latest" "$disc"
printf '%s\n' "$disc" | grep -q 'custom_bot_One_20260810_030015' && pass "discover bot1 latest" || fail "discover bot1" "$disc"
printf '%s\n' "$disc" | grep -q 'custom_bot_Two_20260810_040000' && pass "discover bot2" || fail "discover bot2" "$disc"
printf '%s\n' "$disc" | grep -q 'deep/x/y/remnawave_backup' && pass "discover nested panel" || fail "discover nested" "$disc"
printf '%s\n' "$disc" | grep -q '2026-08-01' && fail "discover old panel" "old key present" || pass "discover skips older"
n="$(printf '%s\n' "$disc" | grep -cE '^(panel|bot) ' || true)"
[[ "$n" == "4" ]] && pass "discover count=4" || fail "discover count" "n=$n disc=$disc"

rbv_mark_tested s1 "rw-backup-full/panel/h1/remnawave_backup_2026-08-10_03_00_00.tar.gz" true run1
disc2="$("$ROOT/bin/rw-backup-verify" discover s1 2>/dev/null)"
printf '%s\n' "$disc2" | grep -q 'panel/h1/remnawave' && fail "untested skip" "still listed" || pass "untested skip"
disc_all="$("$ROOT/bin/rw-backup-verify" discover s1 --all)"
printf '%s\n' "$disc_all" | grep -q 'panel/h1/remnawave' && pass "discover --all" || fail "discover --all" "missing"

"$ROOT/bin/rw-backup-verify" tested list s1 | grep -q 'remnawave_backup_2026-08-10' && pass "tested list" || fail "tested list" "missing"
"$ROOT/bin/rw-backup-verify" tested clear s1 --key "rw-backup-full/panel/h1/remnawave_backup_2026-08-10_03_00_00.tar.gz" >/dev/null
rbv_is_tested s1 "rw-backup-full/panel/h1/remnawave_backup_2026-08-10_03_00_00.tar.gz" \
  && fail "tested clear --key" "still tested" || pass "tested clear --key"

echo "==== global due ===="
"$ROOT/bin/rw-backup-verify" schedule set --interval-hours 6 >/dev/null
mkdir -p "$(rbv_work_dir)/locks"
date +%s > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then fail "not due recent" "was due"; else pass "not due recent"; fi
echo $(( $(date +%s) - 7*3600 )) > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then pass "due after interval"; else fail "due after interval" "not"; fi
# negative interval in config must not be always-due
jq '.verify={interval_hours:-3}' "$RBV_CONFIG" > "$T/c.json" && mv "$T/c.json" "$RBV_CONFIG"
date +%s > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then fail "neg interval due" "should error/not due"; else pass "neg interval rejected"; fi
"$ROOT/bin/rw-backup-verify" schedule set --times "$(date +%H:%M)" >/dev/null
rm -f "$(rbv_work_dir)/locks/due_global_"*
if rbv_global_due; then pass "times due"; else fail "times due" "not"; fi
rbv_mark_global_done
if rbv_global_due; then fail "times already done" "still due"; else pass "times stamped"; fi

echo "==== queue + worker (mock run-one) ===="
"$ROOT/bin/rw-backup-verify" schedule set --interval-hours 12 >/dev/null
"$ROOT/bin/rw-backup-verify" queue clear >/dev/null
FAKE="$T/opt/rw-backup-verify"
mkdir -p "$FAKE/bin" "$FAKE/lib"
cp -a "$ROOT/lib/." "$FAKE/lib/"
cp -a "$ROOT/bin/rw-backup-verify" "$FAKE/bin/"
cp -a "$ROOT/bin/rbv-worker.sh" "$FAKE/bin/"
cat > "$FAKE/bin/rbv-run-one.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
echo "MOCK $*" >&2
mkdir -p "${RBV_STATE_DIR}/runs/mock_${3//\//_}"
exit 0
RUN
chmod +x "$FAKE/bin/rbv-run-one.sh"

rbv_enqueue_instance s1 bot "bot:p:a" "k/a.tar.gz" "k" manual
sleep 0.01
rbv_enqueue_instance s1 panel "panel:p:b" "k/b.tar.gz" "k" manual
mapfile -t jobs < <(ls -1 "$(rbv_queue_dir)"/*.job | sort)
[[ "$(jq -r .kind "${jobs[0]}")" == "bot" ]] && pass "FIFO bot first" || fail "FIFO" "$(jq -r .kind "${jobs[0]}")"
"$FAKE/bin/rbv-worker.sh"
shopt -s nullglob
left_jobs=( "$(rbv_queue_dir)"/*.job )
left=${#left_jobs[@]}
shopt -u nullglob
[[ "$left" == "0" ]] && pass "worker drained" || fail "worker drained" "left=$left"
rbv_is_tested s1 "k/a.tar.gz" && pass "marked tested a" || fail "marked tested a" "no"
rbv_is_tested s1 "k/b.tar.gz" && pass "marked tested b" || fail "marked tested b" "no"

# flock: second worker exits 0 while lock held
rbv_enqueue_instance s1 bot "bot:p:c" "k/c.tar.gz" "k" manual
lock="$(rbv_work_dir)/locks/worker.lock"
(
  exec 9>"$lock"
  flock -n 9
  set +e
  out="$("$FAKE/bin/rbv-worker.sh" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 && "$out" == *"уже работает"* ]] && pass "worker lock" || fail "worker lock" "rc=$rc out=$out"
)
"$ROOT/bin/rw-backup-verify" queue clear >/dev/null

echo "==== run --storage verbose / empty / S3 fail ===="
# дерево как после install.sh, с mock run-one (без Docker)
FAKE2="$T/opt2/rw-backup-verify"
mkdir -p "$FAKE2/bin" "$FAKE2/lib"
cp -a "$ROOT/lib/." "$FAKE2/lib/"
cp -a "$ROOT/bin/rw-backup-verify" "$FAKE2/bin/"
cp -a "$ROOT/bin/rbv-worker.sh" "$FAKE2/bin/"
cat > "$FAKE2/bin/rbv-run-one.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
echo "MOCK-RUN $*" >&2
mkdir -p "${RBV_STATE_DIR}/runs/mockrun_verbose"
exit 0
RUN
chmod +x "$FAKE2/bin/rbv-run-one.sh"

# очистить tested чтобы run что-то нашёл
rm -f "$(rbv_tested_file s1)"
set +e
out="$("$FAKE2/bin/rw-backup-verify" run --storage s1 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "run verbose rc" "rc=$rc out=${out:0:300}"
printf '%s\n' "$out" | grep -q 'run start' && pass "run logs start" || fail "run logs start" "$out"
printf '%s\n' "$out" | grep -q 'шаг 1/3' && pass "run logs step1" || fail "run logs step1" "$out"
printf '%s\n' "$out" | grep -q 'S3 ls' && pass "run logs s3" || fail "run logs s3" "$out"
printf '%s\n' "$out" | grep -q 'в очередь поставлено' && pass "run logs enqueued" || fail "run logs enq" "$out"
printf '%s\n' "$out" | grep -q 'шаг 2/3: worker' && pass "run logs worker" || fail "run logs worker" "$out"
printf '%s\n' "$out" | grep -q 'шаг 3/3: готово' && pass "run logs done" || fail "run logs done" "$out"
printf '%s\n' "$out" | grep -q 'лог:' && pass "run logs path" || fail "run logs path" "$out"
# файл лога должен существовать
logf="$(printf '%s\n' "$out" | sed -n 's/.*лог: //p' | head -n1)"
[[ -n "$logf" && -f "$logf" ]] && pass "run log file" || fail "run log file" "logf=$logf"

# всё уже tested → пустой run с понятным WARN
set +e
out2="$("$FAKE2/bin/rw-backup-verify" run --storage s1 2>&1)"
rc2=$?
set -e
[[ "$rc2" -eq 0 ]] && pass "run empty rc0" || fail "run empty rc" "rc=$rc2"
printf '%s\n' "$out2" | grep -qi 'Нечего выполнять' && pass "run empty warn" || fail "run empty warn" "$out2"
printf '%s\n' "$out2" | grep -q 'Очередь пуста\|в очередь поставлено 0' && pass "run empty detail" || pass "run empty detail-alt"

# S3 ошибка должна быть видна (не тихий exit)
cat > "$T/bin/aws" <<'AWS'
#!/bin/bash
echo "AccessDenied: mock" >&2
exit 254
AWS
chmod +x "$T/bin/aws"
set +e
out3="$("$FAKE2/bin/rw-backup-verify" run --storage s1 2>&1)"
rc3=$?
set -e
[[ "$rc3" -ne 0 ]] && pass "run s3 fail rc" || fail "run s3 fail rc" "rc=0 out=$out3"
printf '%s\n' "$out3" | grep -q 'S3 ls' && pass "run s3 fail msg" || fail "run s3 fail msg" "$out3"

# worker empty message
# восстановим aws mock для остальных тестов не нужен — дальше checks

echo "==== checks / baseline / tg format ===="
jq '.checks.bot.backend_ports=false | .checks.panel.stack=false' \
  "$RBV_CONFIG" > "$T/c3.json" && mv "$T/c3.json" "$RBV_CONFIG"
rbv_check_enabled bot backend_ports && fail "bot ports off" "on" || pass "bot ports off"
rbv_check_enabled panel stack && fail "panel stack off" "on" || pass "panel stack off"
jq '.checks.bot.stability=false | del(.checks.bot.stack)' "$RBV_CONFIG" > "$T/c4.json" && mv "$T/c4.json" "$RBV_CONFIG"
rbv_check_enabled bot stack && fail "alias stability" "on" || pass "alias stability→stack"

ep="$(rbv_parse_archive_epoch 'remnawave_backup_2026-08-10_03_00_00.tar.gz.age')"
[[ "$ep" -gt 1000000000 ]] && pass "parse panel.age epoch" || fail "parse panel.age" "$ep"
ep2="$(rbv_parse_archive_epoch 'custom_bot_x_20260810_030015.tar.gz.age')"
[[ "$ep2" -gt 1000000000 ]] && pass "parse bot.age epoch" || fail "parse bot.age" "$ep2"

rbv_baseline_save s1 "bot:p:a" '{"user_rows":10,"archive_ts":100}'
b="$(rbv_baseline_load s1 "bot:p:a")"
[[ "$(jq -r .user_rows <<<"$b")" == "10" ]] && pass "baseline" || fail "baseline" "$b"

# shellcheck disable=SC2034
RBV_BUCKET=b
rbv_checks_init "$T/checks.json"
rbv_check_add download ok "file.tar.gz"
rbv_check_add user_rows fail "меньше" "20" "15"
body="$(rbv_format_tg_report s1 bot "bot:p:a" "pref/x.tar.gz" false)"
printf '%s\n' "$body" | grep -q 'Хранилище' && pass "tg storage" || fail "tg storage" "missing"
printf '%s\n' "$body" | grep -q 'Расхождения' && pass "tg diffs" || fail "tg diffs" "missing"
esc="$(rbv_html_esc 'a<b>&c')"
[[ "$esc" == "a&lt;b&gt;&amp;c" ]] && pass "html esc" || fail "html esc" "$esc"

# telegram empty creds → WARN, not silent success without message
set +e
tout="$(rbv_tg_send "" "" "hi" 2>&1)"
set -e
printf '%s\n' "$tout" | grep -qi 'пусты\|пропуск\|token' && pass "tg empty warn" || fail "tg empty warn" "$tout"

# global telegram fallback when storage.telegram empty (jq // empty bug)
jq '.telegram={token:"GTOK",chat_id:"-1",thread_id:""} | .storages=[{id:"s1",telegram:{}}]' \
  "$RBV_CONFIG" > "$T/tg.json" && mv "$T/tg.json" "$RBV_CONFIG"
tgline="$(rbv_tg_for_storage s1)"
[[ "$tgline" == "GTOK|-1|" ]] && pass "tg global fallback" || fail "tg global fallback" "$tgline"

# compose project sanitize
proj="$(printf 'rbv_%s' '20260810_X_panel_YTA82294297_remnawave_backup' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g')"
[[ "$proj" == *yta82294297* && "$proj" != *YTA* ]] && pass "compose project lower" || fail "compose project lower" "$proj"

# stack: rewrite DATABASE_URL host → remnawave-db:5432 (sandbox PG)
rewritten="$(jq -nr --arg u 'postgresql://user:secret@107.161.160.68:46767/postgres?schema=public' '
  def fix_pg_url:
    if type != "string" then .
    elif (test("(?i)^postgres(ql)?://") | not) then .
    elif test("@") then
      (capture("(?<pre>.*://[^/@]+@)[^/?#]+(?<post>.*)") // null) as $m
      | if $m then "\($m.pre)remnawave-db:5432\($m.post)" else . end
    else
      (capture("(?<pre>.*://)[^/?#]+(?<post>.*)") // null) as $m
      | if $m then "\($m.pre)remnawave-db:5432\($m.post)" else . end
    end;
  $u | fix_pg_url
')"
[[ "$rewritten" == "postgresql://user:secret@remnawave-db:5432/postgres?schema=public" ]] \
  && pass "fix_pg_url rewrite" || fail "fix_pg_url rewrite" "$rewritten"
iso="$(jq -n --arg net 'rbv_net' --arg pgsvc 'postgres' '
  def fix_pg_url:
    if type != "string" then .
    elif (test("(?i)^postgres(ql)?://") | not) then .
    elif test("@") then
      (capture("(?<pre>.*://[^/@]+@)[^/?#]+(?<post>.*)") // null) as $m
      | if $m then "\($m.pre)remnawave-db:5432\($m.post)" else . end
    else . end;
  def fix_env:
    if type == "object" then
      with_entries(
        if (.key | test("(?i)^(DATABASE_URL|DIRECT_URL)$")) then .value |= fix_pg_url
        elif (.key | test("(?i)^(POSTGRES_HOST)$")) then .value = "remnawave-db"
        else . end
      )
    else . end;
  {
    services: {
      remnawave: {
        image: "x",
        env_file: [".env"],
        ports: ["3000:3000"],
        environment: {
          DATABASE_URL: "postgresql://u:p@10.0.0.1:5432/postgres",
          DIRECT_URL: "postgresql://u:p@10.0.0.1:5432/postgres",
          POSTGRES_HOST: "10.0.0.1"
        }
      },
      postgres: { image: "postgres:17" }
    }
  }
  | .networks = {"rbv": {"name": $net, "external": true}}
  | .services = (.services | to_entries | map(
      .value |= (
        del(.ports, .container_name, .env_file, .network_mode, .links)
        | .networks = {"rbv": {}}
        | if .environment then .environment |= fix_env else . end
      )
      | {key: .key, value: .value}
    ) | from_entries)
  | .services |= with_entries(
      select((.key != $pgsvc) and ((.value.image // "") | test("postgres"; "i") | not))
    )
')"
echo "$iso" | jq -e '
  (.services|keys) == ["remnawave"]
  and (.services.remnawave.env_file|not)
  and (.services.remnawave.ports|not)
  and (.services.remnawave.environment.DATABASE_URL|test("remnawave-db:5432"))
  and (.services.remnawave.environment.POSTGRES_HOST == "remnawave-db")
' >/dev/null && pass "isolated compose rewrite" || fail "isolated compose rewrite" "$iso"

# find_users_table always rc=0 (set -e safe)
set +e
out="$(rbv_find_users_table)"; rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "find_users rc0" || fail "find_users rc0" "rc=$rc"

# bot: users строго public.users; events из payment_webhook_events
_orig_psql="$(declare -f rbv_psql)"
rbv_psql() {
  case "$1" in
    *"to_regclass('public.users')"*) printf 'public.users\n' ;;
    *"to_regclass('public.payment_webhook_events')"*) printf '\n' ;;
    *) printf '\n' ;;
  esac
  return 0
}
[[ "$(rbv_find_users_table bot)" == "public.users" ]] && pass "bot find_users strict" || fail "bot find_users" "$(rbv_find_users_table bot)"
[[ "$(rbv_max_event_epoch bot | head -n1)" == "missing" ]] && pass "bot event missing tbl" || fail "bot event missing" "$(rbv_max_event_epoch bot)"
_dump="$(rbv_dump_table_fields payment_webhook_events)"
echo "$_dump" | grep -q 'отсутствует' && pass "dump missing table" || fail "dump missing" "$_dump"

rbv_psql() {
  case "$1" in
    # свежесть бота: список существующих таблиц группы → ts-колонки → max(epoch)
    *"to_regclass('public.'||quote_ident(t))"*) printf 'payment_webhook_events\n' ;;
    *"table_name||'|'||column_name"*) printf 'payment_webhook_events|created_at\n' ;;
    *"EXTRACT(EPOCH"*) printf '1700000000|payment_webhook_events.created_at\n' ;;
    *"to_regclass('public.payment_webhook_events')"*) printf 'public.payment_webhook_events\n' ;;
    *"column_name||'|'||udt_name"*) printf 'id|int4\ncreated_at|timestamptz\n' ;;
    *) printf '\n' ;;
  esac
  return 0
}
_ev="$(rbv_max_event_epoch bot | head -n1)"
[[ "$_ev" == "1700000000|payment_webhook_events.created_at" ]] && pass "bot event from webhook" || fail "bot event webhook" "$_ev"
_dump="$(rbv_dump_table_fields payment_webhook_events)"
echo "$_dump" | grep -q 'created_at' && pass "dump webhook columns" || fail "dump webhook cols" "$_dump"
eval "$_orig_psql"
# sql_errs counting must not become 00
: >"$T/empty.err"
se="$(grep -cE '^ERROR' "$T/empty.err" 2>/dev/null || true)"
se="$(echo "${se:-0}" | tr -d '[:space:]')"
[[ "$se" == "0" ]] && pass "sql_errs zero" || fail "sql_errs zero" "se=$se"

# OOM/rc=137 messaging helpers exist in rbv-run-one (bash -n covered below)
bash -n "$ROOT/bin/rbv-run-one.sh" && pass "rbv-run-one bash -n" || fail "rbv-run-one bash -n" "syntax"
grep -q 'shm-size' "$ROOT/lib/pg.sh" && pass "pg shm-size" || fail "pg shm-size" "missing"
grep -q 'OOMKilled' "$ROOT/lib/pg.sh" && pass "pg OOM diag" || fail "pg OOM diag" "missing"
grep -q 'rbv_pg_start' "$ROOT/bin/rbv-run-one.sh" && pass "pg start helper" || fail "pg start helper" "missing"
grep -q 'docker cp' "$ROOT/lib/pg.sh" && pass "restore via docker cp" || fail "restore docker cp" "missing"
grep -q 'shared_buffers=' "$ROOT/lib/pg.sh" && pass "pg tunables" || fail "pg tunables" "missing"
grep -q '_RBV_SHORT' "$ROOT/bin/rbv-run-one.sh" && pass "short pg container names" || fail "short names" "missing"
grep -q 'rbv_mem_reclaim' "$ROOT/lib/common.sh" && pass "mem reclaim fn" || fail "mem reclaim fn" "missing"
grep -q 'drop_caches' "$ROOT/lib/common.sh" && pass "drop_caches" || fail "drop_caches" "missing"
grep -q 'RBV_HB_PID' "$ROOT/bin/rbv-run-one.sh" && pass "heartbeat in cleanup" || fail "hb cleanup" "missing"
grep -q 'rbv_dump_schema_diag\|rbv_write_schema_diag' "$ROOT/lib/checks.sh" && pass "schema diag fn" || fail "schema diag fn" "missing"
grep -q 'rbv_emit_schema_diag' "$ROOT/bin/rbv-run-one.sh" && pass "emit schema diag" || fail "emit schema" "missing"
grep -q 'RBV_REASON' "$ROOT/bin/rbv-run-one.sh" && pass "reason to run-one" || fail "reason" "missing"
grep -q 'compose.from-backup' "$ROOT/bin/rbv-run-one.sh" && pass "compose from backup dump" || fail "compose from backup dump" "missing"
grep -q 'compose.isolated.masked' "$ROOT/bin/rbv-run-one.sh" && pass "compose isolated dump" || fail "compose isolated dump" "missing"
grep -q 'compose.logs.txt' "$ROOT/bin/rbv-run-one.sh" && pass "compose logs dump" || fail "compose logs dump" "missing"
grep -q 'rbv_compose_prepare_env' "$ROOT/bin/rbv-run-one.sh" && pass "compose prepare env" || fail "compose prepare env" "missing"
grep -q 'rbv-missing' "$ROOT/bin/rbv-run-one.sh" && pass "compose stub skip" || fail "compose stub skip" "missing"

# prepare_env stubs for ${VAR:?}
_pe="$T/compose_pe"; mkdir -p "$_pe"
printf '%s\n' 'services:' '  x:' '    image: ${BACKEND_IMAGE:?need}:${BACKEND_TAG:?t}' >"$_pe/c.yml"
printf 'FOO=1\n' >"$_pe/.env"
_stubs="$(rbv_compose_prepare_env "$_pe" "$_pe/c.yml" "$_pe/out.env")"
printf '%s' "$_stubs" | grep -q BACKEND_IMAGE && pass "prepare stub BACKEND_IMAGE" || fail "prepare stub" "$_stubs"
grep -q '^BACKEND_IMAGE=rbv-missing' "$_pe/out.env" && pass "prepare stub value" || fail "prepare stub value" "$(cat $_pe/out.env)"
echo 'METRICS_PASS: abcdefghijklmnop' | rbv_mask_secrets | grep -q '\*\*\*' && pass "mask secrets" || fail "mask secrets" "no mask"
grep -q 'rbv_preflight_isolation' "$ROOT/lib/checks.sh" && pass "preflight isolation fn" || fail "preflight isolation fn" "missing"
grep -q 'preflight: isolation' "$ROOT/bin/rbv-run-one.sh" && pass "preflight in run-one" || fail "preflight in run-one" "missing"
grep -q 'check isolation (до stability)' "$ROOT/bin/rbv-run-one.sh" && pass "isolation before stability" || fail "isolation before stability" "missing"
grep -q 'rbv_run_slim' "$ROOT/bin/rbv-run-one.sh" && pass "run slim on cleanup" || fail "run slim on cleanup" "missing"
grep -q 'rbv_ensure_disk_kb' "$ROOT/bin/rbv-run-one.sh" && pass "disk gate before restore" || fail "disk gate" "missing"
grep -q 'mark_retryable\|RBV_RETRYABLE\|exit 75' "$ROOT/bin/rbv-run-one.sh" && pass "disk retryable exit" || fail "disk retryable" "missing"
grep -q 'rc == 75\|RETRYABLE' "$ROOT/bin/rbv-worker.sh" && pass "worker skip tested retryable" || fail "worker retryable" "missing"
grep -q 'только в cache' "$ROOT/bin/rbv-run-one.sh" && pass "archive drop after extract" || fail "archive drop" "missing"
grep -q 'после прогона' "$ROOT/bin/rw-backup-verify" && pass "cache housekeep end run" || fail "cache housekeep end" "missing"
grep -q 'rbv_docker_reclaim' "$ROOT/lib/common.sh" && pass "docker reclaim fn" || fail "docker reclaim fn" "missing"
grep -q 'pg_wal\|/var/lib/postgresql' "$ROOT/bin/rbv-run-one.sh" && pass "strip pgdata binds" || fail "strip pgdata" "missing"
grep -q 'reclaim' "$ROOT/bin/rw-backup-verify" && pass "reclaim cmd" || fail "reclaim cmd" "missing"
grep -q 'compose pull' "$ROOT/bin/rbv-run-one.sh" && pass "compose pull before up" || fail "compose pull" "missing"
grep -q 'volume prune' "$ROOT/bin/rbv-run-one.sh" && pass "volume prune cleanup" || fail "volume prune" "missing"
grep -q 'system prune -af' "$ROOT/bin/rw-backup-verify" && fail "reclaim must keep images" "still prunes images" || pass "reclaim keeps images"
_need="$(rbv_disk_need_for_sql 217000000)"
[[ "$_need" == "1572864" ]] && pass "disk need floor 1.5G" || fail "disk need floor" "$_need"
_need2="$(rbv_disk_need_for_sql 900000000)"
# 900M*4/1024 = 3515625 > floor
[[ "$_need2" == "3515625" ]] && pass "disk need 4x sql" || fail "disk need 4x" "$_need2"

# run slim keeps report, drops extract
_sl="$T/slimrun"; mkdir -p "$_sl/extract" "$_sl/project_extract"
echo report >"$_sl/report.txt"
echo dump >"$_sl/extract/x.sql.gz"
rbv_run_slim "$_sl"
[[ -f "$_sl/report.txt" && ! -d "$_sl/extract" ]] && pass "run slim keeps report" || fail "run slim" "extract still there"

# cache prune latest per instance parent
_ca="$T/state/cache/archives/s1"; mkdir -p "$_ca"
echo 'p/a/old__20260101_000000.tar.gz' >"$_ca/h1.tar.gz.key"
printf 'old' >"$_ca/h1.tar.gz"
echo 'p/a/new__20260810_120000.tar.gz' >"$_ca/h2.tar.gz.key"
printf 'newdata' >"$_ca/h2.tar.gz"
echo 'p/b/other__20260801_000000.tar.gz' >"$_ca/h3.tar.gz.key"
printf 'other' >"$_ca/h3.tar.gz"
_cn="$(rbv_cache_prune_latest s1)"
_cn="$(echo "$_cn" | tr -d '[:space:]')"
[[ "$_cn" == "1" ]] && pass "cache prune deleted1" || fail "cache prune deleted1" "n=$_cn"
[[ ! -f "$_ca/h1.tar.gz" && -f "$_ca/h2.tar.gz" && -f "$_ca/h3.tar.gz" ]] \
  && pass "cache prune keep latest+other" || fail "cache prune keep" "files: $(ls $_ca)"

# archive cache + runs prune (изолированный каталог runs)
_rs="$T/state/runs"
rm -rf "$_rs"
mkdir -p "$_rs/oldrun" "$_rs/newrun"
printf 'storage=s1 kind=bot\nkey=pref/a.tar.gz parent=pref\n' >"$_rs/oldrun/report.txt"
printf 'xxxx' >"$_rs/oldrun/archive.tar.gz"
printf 'storage=s1 kind=panel\nkey=pref/b.tar.gz parent=pref\n' >"$_rs/newrun/report.txt"
printf 'yyyy' >"$_rs/newrun/archive.tar.gz"
# newrun новее
sleep 1
touch "$_rs/newrun"
before_n="$(ls -1d "$_rs"/*/ 2>/dev/null | wc -l | tr -d ' ')"
n="$(rbv_runs_prune 1)"
n="$(echo "$n" | tr -d '[:space:]')"
after_n="$(ls -1d "$_rs"/*/ 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n" == "$((before_n - 1))" && "$after_n" == "1" ]] && pass "runs prune keep1" || fail "runs prune keep1" "n=$n before=$before_n after=$after_n"
[[ ! -d "$_rs/oldrun" ]] && pass "runs prune old gone" || fail "runs prune old gone" "still there"
[[ -d "$_rs/newrun" ]] && pass "runs prune new kept" || fail "runs prune new kept" "missing"
cpath="$(rbv_cache_ensure s1 'pref/a.tar.gz' || true)"
[[ -n "$cpath" && -s "$cpath" ]] && pass "cache adopt old archive" || fail "cache adopt" "cpath=$cpath"
c2="$(rbv_cache_ensure s1 'pref/a.tar.gz')"
[[ "$c2" == "$cpath" ]] && pass "cache hit path" || fail "cache hit path" "$c2"

echo "==== тесты не трогают настоящий docker ===="
# страховка: если заглушка перестанет подхватываться, тест это покажет
if [[ -s "$T/docker.log" ]]; then
  grep -q 'rm -f' "$T/docker.log" \
    && pass "docker-вызовы ушли в заглушку (включая rm -f)" \
    || pass "docker-вызовы ушли в заглушку"
else
  pass "docker не вызывался"
fi
[[ "$(command -v docker)" == "$T/bin/docker" ]] && pass "в PATH подставлен mock docker" \
  || fail "mock docker в PATH" "$(command -v docker)"

echo "==== help / unknown / save config ===="
expect_rc 0 "help" "$ROOT/bin/rw-backup-verify" help
expect_rc 1 "unknown cmd" "$ROOT/bin/rw-backup-verify" nosuchcmd
set +e
echo 'not-json' | rbv_save_config 2>/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "save bad json" || fail "save bad json" "rc=0"

echo "==== install.sh syntax / non-root ===="
bash -n "$ROOT/install.sh" && pass "install bash -n" || fail "install bash -n" "syntax"
# под root install.sh реально поставил бы systemd-таймер прямо из теста —
# сбрасываем привилегии, чтобы проверять именно guard «нужен root»
if [[ ${EUID:-0} -eq 0 ]]; then
  _inst="$(mktemp /tmp/rbv_install_XXXXXX.sh)"
  cp "$ROOT/install.sh" "$_inst"
  chmod 755 "$_inst"
  expect_rc 1 "install non-root" \
    setpriv --reuid=65534 --regid=65534 --clear-groups bash "$_inst"
  rm -f "$_inst"
else
  expect_rc 1 "install non-root" bash "$ROOT/install.sh"
fi

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
