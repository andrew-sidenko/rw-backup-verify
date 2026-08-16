#!/usr/bin/env bash
# Параллельные прогоны и защита артефактов живого прогона.
# Регрессия: systemd-тик (раз в минуту) стартовал второй `run --due` поверх
# идущего, а `run`/`reclaim` начинались с docker reclaim → `docker rm -f
# rbv_pg_*` убивал песочницу живого restore (exit=137, oom=false,
# status=removing — выглядело как OOM).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL $1 — $2"; }

T="$(mktemp -d)"
SLEEPER=""
HOLDER=""
cleanup() {
  [[ -n "$SLEEPER" ]] && kill "$SLEEPER" 2>/dev/null || true
  [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

export RBV_CONFIG="$T/config.json"
export RBV_STATE_DIR="$T/state"
mkdir -p "$RBV_STATE_DIR" "$T/bin"
cp "$ROOT/config/config.example.json" "$RBV_CONFIG"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

WD="$(rbv_work_dir)"

echo "==== глобальный лок ===="
if rbv_global_lock 0; then pass "лок взят"; else fail "лок взят" "не удалось"; fi
# второй процесс (лок держим мы) не должен пройти
set +e
out="$(RBV_GLOBAL_LOCK_HELD=0 bash -c '
  set -euo pipefail
  source "'"$ROOT"'/lib/common.sh"
  if rbv_global_lock 0; then echo GOT; else echo BUSY; fi
' 2>&1)"
set -e
[[ "$out" == *BUSY* ]] && pass "второй процесс видит занятый лок" \
  || fail "второй процесс видит занятый лок" "out=$out"
[[ -n "$(rbv_global_lock_owner)" ]] && pass "владелец лока записан" \
  || fail "владелец лока записан" "пусто"

# отпускаем свой лок и убираем «наследование» — дальше проверяем CLI так,
# как её запускает человек/systemd: отдельный процесс, лок держит кто-то другой
exec 8>&-
RBV_GLOBAL_LOCK_HELD=0
export RBV_GLOBAL_LOCK_HELD=0
unset RBV_GLOBAL_LOCK_HELD
# stdout в /dev/null: иначе фоновый держатель не отпускает pipe вызывающего
flock -x "$(rbv_global_lock_file)" -c 'sleep 120' >/dev/null 2>&1 &
HOLDER=$!
for _ in $(seq 1 50); do
  if ! flock -n "$(rbv_global_lock_file)" -c true 2>/dev/null; then break; fi
  sleep 0.1
done
if flock -n "$(rbv_global_lock_file)" -c true 2>/dev/null; then
  fail "внешний держатель лока" "лок свободен"
else
  pass "внешний держатель лока"
fi

echo "==== CLI под занятым локом ===="
"$ROOT/bin/rw-backup-verify" storage add --id s1 --bucket b \
  --access-key a --secret-key s --prefix p >/dev/null
set +e
out="$("$ROOT/bin/rw-backup-verify" run --storage s1 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 && "$out" == *"Уже идёт прогон"* ]] && pass "run отказывается при занятом локе" \
  || fail "run отказывается" "rc=$rc out=${out:0:200}"

set +e
out="$("$ROOT/bin/rw-backup-verify" run --due 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 0 && "$out" == *"расписание пропускаем"* ]] && pass "run --due тихо пропускает" \
  || fail "run --due пропускает" "rc=$rc out=${out:0:200}"

set +e
out="$("$ROOT/bin/rw-backup-verify" reclaim 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 && "$out" == *"убьёт его песочницу"* ]] && pass "reclaim отказывается" \
  || fail "reclaim отказывается" "rc=$rc out=${out:0:200}"

echo "==== очередь без дублей ===="
rm -f "$(rbv_queue_dir)"/*.job
rbv_enqueue_instance s1 bot "bot:p:a" "k/a.tar.gz" "k" manual >/dev/null 2>&1
sleep 0.01
out="$(rbv_enqueue_instance s1 bot "bot:p:a" "k/a.tar.gz" "k" manual 2>&1)"
n="$(find "$(rbv_queue_dir)" -name '*.job' | wc -l | tr -d ' ')"
[[ "$n" == "1" && "$out" == *"уже в очереди"* ]] && pass "тот же архив не дублируется" \
  || fail "дубль в очереди" "n=$n out=$out"
rbv_enqueue_instance s1 bot "bot:p:a" "k/b.tar.gz" "k" manual >/dev/null 2>&1
n="$(find "$(rbv_queue_dir)" -name '*.job' | wc -l | tr -d ' ')"
[[ "$n" == "2" ]] && pass "другой архив ставится в очередь" || fail "другой архив" "n=$n"
rm -f "$(rbv_queue_dir)"/*.job

echo "==== реестр активных прогонов ===="
sleep 300 >/dev/null 2>&1 &
SLEEPER=$!
mkdir -p "$(rbv_active_dir)"
live_run="${WD}/runs/live_run"
mkdir -p "$live_run/extract"
echo dump >"$live_run/extract/postgres_dump.sql.gz"
echo report >"$live_run/report.txt"
jq -nc --argjson pid "$SLEEPER" --arg run "$live_run" \
  --arg pg "rbv_pg_live" --arg proj "rbv_bot_live" \
  '{pid:$pid, run_dir:$run, pg_cid:$pg, compose_project:$proj, started:0}' \
  >"$(rbv_active_dir)/${SLEEPER}.json"
# запись мёртвого pid должна вычищаться сама
jq -nc '{pid:999999, run_dir:"/nonexistent", pg_cid:"rbv_pg_stale", compose_project:"x", started:0}' \
  >"$(rbv_active_dir)/999999.json"

n="$(rbv_active_entries | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] && pass "живые записи=1, мёртвая вычищена" || fail "живые записи" "n=$n"
[[ ! -f "$(rbv_active_dir)/999999.json" ]] && pass "stale-файл удалён" || fail "stale-файл" "остался"

rbv_is_protected "rbv_pg_live" pg_cid && pass "контейнер защищён" || fail "контейнер защищён" "нет"
rbv_is_protected "rbv_pg_other" pg_cid && fail "чужой контейнер" "защищён зря" || pass "чужой контейнер не защищён"
rbv_is_protected "$live_run" run_dir && pass "run_dir защищён" || fail "run_dir защищён" "нет"

echo "==== prune/slim не трогают живой прогон ===="
mkdir -p "${WD}/runs/old_run"
echo report >"${WD}/runs/old_run/report.txt"
n="$(rbv_runs_prune 0)"
n="$(echo "$n" | tr -d '[:space:]')"
[[ -d "$live_run" ]] && pass "runs prune keep=0 сохранил живой run" \
  || fail "runs prune keep=0" "живой run удалён"
[[ ! -d "${WD}/runs/old_run" ]] && pass "runs prune удалил старый run (n=$n)" \
  || fail "runs prune старый" "остался"

rbv_run_slim "$live_run"
[[ -d "$live_run/extract" ]] && pass "slim не тронул extract живого прогона" \
  || fail "slim живого прогона" "extract удалён"

echo "==== docker reclaim не трогает живую песочницу ===="
cat >"$T/bin/docker" <<'DOCKER'
#!/bin/bash
printf '%s\n' "$*" >>"${RBV_DOCKER_LOG}"
args="$*"
case "$args" in
  *'{{.Names}}'*) printf 'rbv_pg_live\nrbv_pg_orphan\n'; exit 0 ;;
  *'com.docker.compose.project'*) printf 'rbv_bot_live\nrbv_bot_orphan\n'; exit 0 ;;
  'network ls'*) printf 'rbv_bot_live_net\nrbv_bot_orphan_net\n'; exit 0 ;;
esac
exit 0
DOCKER
chmod +x "$T/bin/docker"
export RBV_DOCKER_LOG="$T/docker.log"
: >"$RBV_DOCKER_LOG"
PATH="$T/bin:$PATH" rbv_docker_reclaim >/dev/null

grep -q '^rm -f rbv_pg_orphan$' "$RBV_DOCKER_LOG" && pass "reclaim снял осиротевший контейнер" \
  || fail "reclaim осиротевший" "$(cat "$RBV_DOCKER_LOG")"
grep -q '^rm -f rbv_pg_live$' "$RBV_DOCKER_LOG" && fail "reclaim убил живую песочницу" "регрессия!" \
  || pass "reclaim не тронул живую песочницу"
grep -q 'compose -p rbv_bot_orphan down' "$RBV_DOCKER_LOG" && pass "reclaim снял чужой compose" \
  || fail "reclaim compose orphan" "$(cat "$RBV_DOCKER_LOG")"
grep -q 'compose -p rbv_bot_live down' "$RBV_DOCKER_LOG" && fail "reclaim снёс живой compose" "регрессия!" \
  || pass "reclaim не тронул живой compose"
grep -q 'container prune' "$RBV_DOCKER_LOG" && fail "container prune при живом прогоне" "снёс бы упавшие контейнеры стека" \
  || pass "container prune отложен при живом прогоне"

echo "==== reclaim --force чистит только чужое ===="
set +e
out="$(PATH="$T/bin:$PATH" "$ROOT/bin/rw-backup-verify" reclaim --force 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 0 && "$out" == *"не принадлежит живому прогону"* ]] && pass "reclaim --force работает" \
  || fail "reclaim --force" "rc=$rc out=${out:0:300}"
[[ -d "$live_run" ]] && pass "reclaim --force сохранил живой run" || fail "reclaim --force run" "удалён"

echo "==== tick при живом прогоне ===="
set +e
out="$(PATH="$T/bin:$PATH" "$ROOT/bin/rw-backup-verify" tick 2>&1)"; rc=$?
set -e
[[ "$rc" -eq 0 && -z "$out" ]] && pass "tick молча выходит" || fail "tick" "rc=$rc out=${out:0:200}"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
