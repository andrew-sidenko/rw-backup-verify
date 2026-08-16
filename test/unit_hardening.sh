#!/usr/bin/env bash
# Регрессии на «тихие» ловушки bash в rw-backup-verify.
# Главная: библиотечная функция делала set +e … set -e и ВКЛЮЧАЛА errexit
# обратно вызывающему, который его выключил. Из-за этого rbv-run-one молча
# умирал сразу после сбоя restore — в отчёт не попадал ни диагноз, ни итог.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL $1 — $2"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export RBV_CONFIG="$T/config.json"
export RBV_STATE_DIR="$T/state"
mkdir -p "$RBV_STATE_DIR"
cp "$ROOT/config/config.example.json" "$RBV_CONFIG"

echo "==== bash -n ===="
for f in "$ROOT"/bin/rbv-run-one.sh "$ROOT"/bin/rbv-worker.sh \
         "$ROOT"/bin/rw-backup-verify "$ROOT"/lib/common.sh \
         "$ROOT"/lib/checks.sh "$ROOT"/lib/pg.sh "$ROOT"/install.sh; do
  bash -n "$f" && pass "bash -n $(basename "$f")" || fail "bash -n $(basename "$f")" "syntax"
done

echo "==== библиотеки не включают errexit обратно ===="
# статически: внутри функций lib/*.sh не должно быть голого `set -e`
bad=""
for f in "$ROOT"/lib/*.sh; do
  n="$(grep -cE '^[[:space:]]+set -e[[:space:]]*$' "$f" || true)"
  n="$(echo "${n:-0}" | tr -d '[:space:]')"
  [[ "$n" == "0" ]] || bad+="$(basename "$f")($n) "
done
[[ -z "$bad" ]] && pass "нет set -e внутри функций lib/" || fail "set -e внутри lib/" "$bad"

# функционально: errexit должен остаться выключенным после вызова функций,
# и вызывающий обязан пережить их ненулевой rc
out="$(bash -c '
  set -euo pipefail
  export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
  source "'"$ROOT"'/lib/common.sh"
  source "'"$ROOT"'/lib/pg.sh"
  PG_CID="rbv_pg_nonexistent_zzz"
  RUN_DIR="'"$T"'"
  PG_VER=17
  set +e
  rbv_pg_restore_sql "/nonexistent/dump.sql.gz"
  echo "rc=$?"
  case "$-" in *e*) echo "ERREXIT-BACK";; *) echo "ERREXIT-OFF";; esac
  rbv_pg_kill_reason
  echo ALIVE
' 2>/dev/null)"
[[ "$out" == *"ERREXIT-OFF"* ]] && pass "restore_sql не включает errexit" \
  || fail "restore_sql errexit" "$out"
[[ "$out" == *ALIVE* ]] && pass "вызывающий пережил сбой restore_sql" \
  || fail "вызывающий пережил сбой" "$out"
[[ "$out" == *external* ]] && pass "исчезнувший контейнер = external" \
  || fail "kill_reason external" "$out"

echo "==== классификация смерти песочницы ===="
# `docker rm -f` успевает мелькнуть статусом exited(137) до удаления —
# это внешний kill, а не OOM и не падение postgres
mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'DOCKER'
#!/bin/bash
[[ "$1" == "inspect" && "$*" != *"-f"* ]] && exit "${RBV_MOCK_MISSING:-0}"
if [[ "$1" == "inspect" ]]; then
  [[ "${RBV_MOCK_MISSING:-0}" != "0" ]] && exit 1
  printf '%s\n' "${RBV_MOCK_STATE}"
  exit 0
fi
exit 0
DOCKER
chmod +x "$T/bin/docker"
reason_for() {
  RBV_MOCK_STATE="$1" RBV_MOCK_MISSING="${2:-0}" PATH="$T/bin:$PATH" bash -c '
    set -euo pipefail
    export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
    source "'"$ROOT"'/lib/common.sh"; source "'"$ROOT"'/lib/pg.sh"
    PG_CID=rbv_pg_x; rbv_pg_kill_reason'
}
[[ "$(reason_for 'running|true|false|0')" == "alive" ]] && pass "жив → alive" || fail "alive" "$(reason_for 'running|true|false|0')"
[[ "$(reason_for 'exited|false|true|137')" == "oom" ]] && pass "OOMKilled → oom" || fail "oom" "$(reason_for 'exited|false|true|137')"
[[ "$(reason_for 'removing|false|false|137')" == "external" ]] && pass "removing → external" || fail "removing" "$(reason_for 'removing|false|false|137')"
[[ "$(reason_for 'exited|false|false|137')" == "external" ]] && pass "exited(137) без OOM → external" \
  || fail "exited 137" "$(reason_for 'exited|false|false|137')"
[[ "$(reason_for 'exited|false|false|1')" == "crash" ]] && pass "exited(1) → crash" || fail "crash" "$(reason_for 'exited|false|false|1')"
[[ "$(reason_for 'x|x|x|x' 1)" == "external" ]] && pass "контейнер исчез → external" || fail "gone" "$(reason_for 'x|x|x|x' 1)"

echo "==== выбор БД приложения ===="
# 1) выбранная БД обязана пережить вызов (никаких $(…) у вызывающего)
# 2) берём БД с public.users, а не первую непустую (pg_dumpall: postgres пустой,
#    приложение живёт в vpnbot)
cat >"$T/bin/docker" <<'DOCKER'
#!/bin/bash
q="${*: -1}"
case "$q" in
  *"FROM pg_database WHERE NOT datistemplate ORDER BY"*) printf 'postgres\nvpnbot\n' ;;
  *"pg_stat_user_tables"*)
      case "$*" in *"-d vpnbot"*) echo 23 ;; *) echo 0 ;; esac ;;
  *"to_regclass('public.users')"*)
      case "$*" in *"-d vpnbot"*) echo 1 ;; *) echo 0 ;; esac ;;
esac
exit 0
DOCKER
chmod +x "$T/bin/docker"
out="$(PATH="$T/bin:$PATH" bash -c '
  set -euo pipefail
  export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
  source "'"$ROOT"'/lib/common.sh"; source "'"$ROOT"'/lib/checks.sh"
  PG_CID=rbv_pg_x
  rbv_select_app_db "" >/dev/null
  echo "db=${RBV_PG_DB} tables=${RBV_PG_TABLES} list=${RBV_PG_DB_LIST}"')"
[[ "$out" == *"db=vpnbot"* ]] && pass "выбрана БД с public.users" || fail "выбор БД" "$out"
[[ "$out" == *"tables=23"* ]] && pass "число таблиц из выбранной БД" || fail "число таблиц" "$out"
[[ "$out" == *"vpnbot=23+users"* ]] && pass "список кандидатов в отчёт" || fail "кандидаты" "$out"

echo "==== rbv_pg_tunables ===="
out="$(bash -c '
  set -euo pipefail
  export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
  source "'"$ROOT"'/lib/common.sh"; source "'"$ROOT"'/lib/pg.sh"
  rbv_pg_tunables 1000; printf "%s\n" "${RBV_PG_ARGS[@]}" | tr "\n" " "; echo
  rbv_pg_tunables 8000; printf "%s\n" "${RBV_PG_ARGS[@]}" | tr "\n" " "; echo
')"
low="$(printf '%s\n' "$out" | head -n1)"
high="$(printf '%s\n' "$out" | tail -n1)"
[[ "$low" == *"shared_buffers=64MB"* ]] && pass "low-mem tunables" || fail "low-mem tunables" "$low"
[[ "$high" == *"shared_buffers=512MB"* ]] && pass "big-mem tunables" || fail "big-mem tunables" "$high"
[[ "$low" == *"fsync=off"* && "$high" == *"fsync=off"* ]] && pass "fsync=off (одноразовая песочница)" \
  || fail "fsync=off" "$low"

echo "==== declare -A под set -u ===="
# rbv_cache_prune_latest использует ассоциативные массивы
out="$(bash -c '
  set -euo pipefail
  export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
  source "'"$ROOT"'/lib/common.sh"
  rbv_cache_prune_latest ""
' 2>&1)"
[[ "$out" == "0" ]] && pass "cache prune на пустом кэше" || fail "cache prune пустой" "$out"

echo "==== pipefail + head в разборе дампа ===="
# head закрывает pipe → gzip получает SIGPIPE(141); под pipefail это rc≠0
printf 'ALTER TABLE public.x OWNER TO botuser;\nGRANT ALL ON TABLE public.x TO reader;\n' \
  | gzip >"$T/d.sql.gz"
out="$(bash -c '
  set -euo pipefail
  export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
  source "'"$ROOT"'/lib/common.sh"; source "'"$ROOT"'/lib/pg.sh"
  rbv_pg_roles_in_dump "'"$T"'/d.sql.gz" | tr "\n" ","
  case "$-" in *o*) : ;; esac
  echo OK
')"
[[ "$out" == *"botuser"* ]] && pass "роль OWNER TO найдена" || fail "роль OWNER TO" "$out"
[[ "$out" == *"reader"* ]] && pass "роль GRANT TO найдена" || fail "роль GRANT TO" "$out"
[[ "$out" == *OK* ]] && pass "разбор дампа не рвёт pipefail" || fail "pipefail в разборе" "$out"

echo "==== disk gate ===="
out="$(bash -c '
  set -euo pipefail
  export RBV_CONFIG="'"$RBV_CONFIG"'" RBV_STATE_DIR="'"$RBV_STATE_DIR"'"
  source "'"$ROOT"'/lib/common.sh"
  echo "need=$(rbv_disk_need_for_sql 217000000) est=$(rbv_disk_estimate_for_sql 217000000)"
')"
[[ "$out" == "need=1572864 est=3178710" ]] && pass "порог и оценка места" || fail "порог места" "$out"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
