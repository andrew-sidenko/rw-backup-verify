#!/usr/bin/env bash
# Один прогон экземпляра с расширенными проверками и TG-отчётом.
# <storage-id> <kind:panel|bot> <instance_id> <s3_key> [parent_dir]
set -euo pipefail
_self="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/checks.sh
source "${SCRIPT_DIR}/../lib/checks.sh"
# shellcheck source=../lib/pg.sh
source "${SCRIPT_DIR}/../lib/pg.sh"

SID="${1:?storage}"
KIND="${2:?kind}"
INST="${3:?instance}"
KEY="${4:?s3-key}"
PARENT="${5:-}"
# manual | schedule | queue — при manual полный schema-diag если нет таблиц/полей
RBV_REASON="${6:-${RBV_REASON:-manual}}"
export RBV_REASON

rbv_load_config
need docker
need jq
need tar
need gzip

J="$(rbv_storage_json "$SID")"
rbv_aws_env "$J"
WD="$(rbv_work_dir)"
# Короткие id: docker hostname ≤63 символов; длинный INST ломал rbv_pg_* (bot «not Running»).
_RBV_SHORT="$(printf '%s' "${KIND}:${INST}" | sha256sum | awk '{print substr($1,1,10)}')"
_RBV_TS="$(date -u +%Y%m%d_%H%M%S)"
RUN_ID="${_RBV_TS}_${KIND}_${_RBV_SHORT}"
RUN_DIR="${WD}/runs/${RUN_ID}"
# docker compose -p: только [a-z0-9_-], длина ≤50
COMPOSE_PROJECT="$(printf 'rbv_%s_%s' "$KIND" "$_RBV_SHORT" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g' | cut -c1-50)"
PG_CID="rbv_pg_${_RBV_SHORT}_${_RBV_TS##*_}"
# запас: если всё же длиннее 63 — обрезать
PG_CID="$(printf '%s' "$PG_CID" | cut -c1-63)"
mkdir -p "$RUN_DIR"
REPORT="${RUN_DIR}/report.txt"
CHECKS_JSON="${RUN_DIR}/checks.json"
: > "$REPORT"
rbv_checks_init "$CHECKS_JSON"

rep() { printf '%s\n' "$*" | tee -a "$REPORT" >&2; }
rep_file() {
  # rep_file <title> <path> [max_lines]
  local title="$1" path="$2" max="${3:-120}"
  local lines=0
  rep "----- ${title} (${path}) -----"
  if [[ ! -f "$path" ]]; then
    rep "  (нет файла)"
    rep "----- end ${title} -----"
    return 0
  fi
  lines="$(wc -l <"$path" 2>/dev/null | tr -d ' ' || echo 0)"
  head -n "$max" "$path" | while IFS= read -r _line || [[ -n "$_line" ]]; do
    rep "  ${_line}"
  done
  if [[ "$lines" =~ ^[0-9]+$ ]] && (( lines > max )); then
    rep "  … (+$((lines - max)) строк; полный файл: ${path})"
  fi
  rep "----- end ${title} -----"
}
# шаги lib/pg.sh пишем и в report, и в stderr
rbv_say() { rep "$*"; }
ok=true
fail_reasons=()

fail_add() {
  ok=false
  fail_reasons+=("$1")
  rep "FAIL $1"
}

# Временный сбой (диск/OOM) — worker НЕ пишет в tested, можно повторить тот же key.
mark_retryable() {
  RBV_RETRYABLE=1
  [[ -n "${RUN_DIR:-}" ]] && mkdir -p "$RUN_DIR" && : >"${RUN_DIR}/.retryable"
}

# PG_CID задан выше (короткое имя ≤63)
COMPOSE_FILE=""
NET_NAME=""
KEEP="${KEEP:-false}"
PROJ_DIR=""
COMPOSE_RAW="${RUN_DIR}/compose.raw.json"
USER_ROWS=0
LAST_EVENT=0
CURR_ARCH_EPOCH=0
PREV_ARCH_EPOCH=0
BASELINE_JSON="{}"
RBV_RETRYABLE=0
RBV_HB_PID=""
RBV_DISK_NEED_KB=0
# строки по таблицам бота → baseline (сравнение на следующей проверке)
TABLE_ROWS_PAIRS=()
TABLE_ROWS_JSON="{}"

# Реестр живого прогона: чужой reclaim/prune (ручной или из параллельного
# tick'а) не должен снести нашу песочницу, compose-проект и runs/<id>.
rbv_active_register "$RUN_DIR" "$PG_CID" "$COMPOSE_PROJECT"

cleanup() {
  # heartbeat restore (иначе sleep-цикл живёт после EXIT)
  if [[ -n "${RBV_HB_PID:-}" ]]; then
    kill "$RBV_HB_PID" 2>/dev/null || true
    wait "$RBV_HB_PID" 2>/dev/null || true
    RBV_HB_PID=""
  fi
  if [[ "$KEEP" != "true" ]]; then
    if [[ -n "${COMPOSE_FILE}" && -f "${COMPOSE_FILE}" ]]; then
      docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    [[ -n "${NET_NAME}" ]] && docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    [[ -n "${PG_CID}" ]] && docker rm -f "$PG_CID" >/dev/null 2>&1 || true
    # свои хвосты после kill/OOM; песочницы чужих живых прогонов не трогаем
    while IFS= read -r _old; do
      [[ -n "$_old" ]] || continue
      rbv_is_protected "$_old" pg_cid && continue
      docker rm -f "$_old" >/dev/null 2>&1 || true
    done < <(docker ps -a --filter 'name=rbv_pg_' --filter 'name=rbv_probe_' \
      --format '{{.Names}}' 2>/dev/null || true)
    # anonymous volumes от stack (redis/pgdata) — иначе копятся в /var/lib/docker/volumes
    docker volume prune -f >/dev/null 2>&1 || true
    # освободить диск для следующего job: dump/extract убрать, report/compose оставить
    if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR}" ]]; then
      # schema-diag → logs (runs prune keep=0 снесёт runs/)
      if [[ -f "${RUN_DIR}/schema-diag.txt" ]]; then
        cp -f "${RUN_DIR}/schema-diag.txt" \
          "$(rbv_work_dir)/logs/schema_${RUN_ID}.txt" 2>/dev/null || true
      fi
      rbv_run_slim "$RUN_DIR"
    fi
    # page cache от dump/archive — иначе avail RAM падает между bot→panel
    rbv_mem_reclaim >/dev/null 2>&1 || true
  fi
  rbv_active_unregister
}
trap cleanup EXIT

# не дать prune снести текущий run
export RBV_PROTECT_RUN="$RUN_DIR"

rep "=== rw-backup-verify ==="
rep "storage=${SID} kind=${KIND} instance=${INST}"
rep "key=${KEY} parent=${PARENT} reason=${RBV_REASON}"
rep "started=$(date -Is)"

# Полный schema-diag в report + logs/ (если нет нужных таблиц/полей).
# Ручной run — весь дамп в report; schedule — файл + краткая сводка.
SCHEMA_DIAG_DONE=0
rbv_emit_schema_diag() {
  local note="$1" line file_run="" file_log=""
  local dump
  if [[ "${SCHEMA_DIAG_DONE}" == "1" ]]; then
    rep "schema diag: уже снят в этом прогоне (${note})"
    return 0
  fi
  SCHEMA_DIAG_DONE=1
  dump="$(rbv_write_schema_diag "$note" 2>/dev/null || true)"
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    case "$line" in
      SCHEMA_DIAG_FILE=*) file_run="${line#SCHEMA_DIAG_FILE=}" ;;
      SCHEMA_DIAG_LOG=*) file_log="${line#SCHEMA_DIAG_LOG=}" ;;
    esac
  done <<<"$dump"
  if [[ "${RBV_REASON}" == "manual" || "${RBV_REASON}" == "queue" ]]; then
    rep "===== SCHEMA DIAG (${note}) — все таблицы/поля для доработки ====="
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
      case "$line" in
        SCHEMA_DIAG_FILE=*|SCHEMA_DIAG_LOG=*) continue ;;
      esac
      [[ -n "${line:-}" ]] && rep "$line"
    done <<<"$dump"
    rep "===== SCHEMA DIAG files: run=${file_run:-?} log=${file_log:-?} ====="
  else
    rep "schema diag (${note}): полный дамп → ${file_log:-${file_run:-?}}"
    echo "$dump" | grep -E '^(  OK|  MISS|TABLE |note:|db=)' | head -n 60 \
      | while IFS= read -r line; do rep "  ${line}"; done
  fi
  [[ -n "$file_log" ]] && rbv_check_add schema_diag ok "см. ${file_log}"
}

CURR_ARCH_EPOCH="$(rbv_parse_archive_epoch "$(basename "$KEY")")"
BASELINE_JSON="$(rbv_baseline_load "$SID" "$INST")"
PREV_ARCH_EPOCH="$(jq -r '.archive_ts // 0' <<<"$BASELINE_JSON")"
PREV_USER_ROWS="$(jq -r '.user_rows // empty' <<<"$BASELINE_JSON")"

# --- preflight isolation (до download/restore/stack) ------------------------
# Если хост не умеет --internal без egress — все проверки бессмысленны.
_preflight_iso=true
v_pf="$(jq -r '.checks.preflight_isolation // .checks.default.preflight_isolation // true' "$RBV_CONFIG" 2>/dev/null || echo true)"
case "$v_pf" in false|FALSE|0|no|off) _preflight_iso=false ;; esac
if [[ "$_preflight_iso" == true ]]; then
  rep "preflight: isolation (Docker --internal без egress)…"
  set +e
  _pf_detail="$(rbv_preflight_isolation 2>/dev/null)"
  _pf_rc=$?
  set -e
  if [[ $_pf_rc -ne 0 ]]; then
    rbv_check_add isolation fail "preflight: ${_pf_detail:-fail}"
    fail_add "isolation preflight — тесты остановлены"
    rep "FAIL isolation preflight: ${_pf_detail}"
    rep "  исправьте Docker/firewall (сети --internal не должны иметь egress), затем повторите run"
  else
    rep "preflight: isolation OK (${_pf_detail})"
  fi
else
  rep "preflight: isolation пропущен (checks.preflight_isolation=false)"
fi

# --- download / extract -----------------------------------------------------
# Кэш архивов: work_dir/cache/archives/<sid>/<hash>.tar.gz — не качаем повторно.
# Перед скачиванием чистим старые runs/ (архивы уже в cache через hardlink).
if [[ "$ok" != true ]]; then
  rep "skip: download/restore/stack не запускаются (preflight fail)"
else
ARCH_PATH="${RUN_DIR}/archive.tar.gz"
S3_URI="s3://${RBV_BUCKET}/${KEY}"
_keep_runs="$(rbv_cfg '.runs_keep // 2')"
[[ "$_keep_runs" =~ ^[0-9]+$ ]] || _keep_runs=2
_pruned="$(rbv_runs_prune "$_keep_runs" "$RUN_DIR" || echo 0)"
_pruned="$(echo "$_pruned" | tr -d '[:space:]')"
[[ "$_pruned" =~ ^[0-9]+$ ]] || _pruned=0
if (( _pruned > 0 )); then
  rep "disk: удалено старых runs=${_pruned} (keep=${_keep_runs}; архивы в cache)"
fi
# у старых runs убрать extract/sql — иначе после bot не хватит места на panel
rbv_slim_old_runs "$RUN_DIR"
rep "disk: $(rbv_disk_report "$WD")"
_avail_kb="$(rbv_disk_avail_kb "$WD")"
if [[ -n "$_avail_kb" && "$_avail_kb" =~ ^[0-9]+$ ]] && (( _avail_kb < 2097152 )); then
  rep "WARN: свободно <2GiB (${_avail_kb} KiB) — перед restore будет жёсткий prune"
fi

_cache=""
set +e
_cache="$(rbv_cache_ensure "$SID" "$KEY")"
_ce_rc=$?
set -e
if [[ $_ce_rc -eq 0 && -n "$_cache" && -s "$_cache" ]]; then
  rep "download: cache hit $(basename "$KEY") ← ${_cache#"$WD"/}"
  ln -f "$_cache" "$ARCH_PATH" 2>/dev/null || cp -f "$_cache" "$ARCH_PATH"
  if [[ -s "$ARCH_PATH" ]]; then
    rbv_check_add download ok "$(basename "$KEY") (cache)"
  else
    fail_add "download failed (cache copy)"
    rbv_check_add download fail "cache → run copy failed"
  fi
else
  rep "download ${S3_URI}"
  _cache="$(rbv_archive_cache_path "$SID" "$KEY")"
  set +e
  rbv_aws s3 cp "$S3_URI" "$_cache" --only-show-errors 2>"${RUN_DIR}/download.err"
  _dl_rc=$?
  set -e
  if [[ $_dl_rc -ne 0 || ! -s "$_cache" ]]; then
    _err="$(tr '\n' ' ' <"${RUN_DIR}/download.err" 2>/dev/null | head -c 300)"
    if grep -qiE 'No space left|ENOSPC|errno 28' "${RUN_DIR}/download.err" 2>/dev/null; then
      fail_add "download failed: диск заполнен (ENOSPC)"
      rbv_check_add download fail "ENOSPC — runs prune / docker prune"
      mark_retryable
      rep "  ${_err}"
      rep "  → rw-backup-verify runs prune --keep 0"
      rep "  → rw-backup-verify reclaim --docker"
    else
      fail_add "download failed"
      rbv_check_add download fail "не скачался ${S3_URI}"
      [[ -n "$_err" ]] && rep "  ${_err}"
    fi
    rm -f "$_cache" 2>/dev/null || true
    _cache=""
  else
    printf '%s\n' "$KEY" >"${_cache}.key"
    ln -f "$_cache" "$ARCH_PATH" 2>/dev/null || cp -f "$_cache" "$ARCH_PATH"
    rbv_check_add download ok "$(basename "$KEY")"
  fi
fi
# после любого удачного получения архива — в cache только latest (ручной = auto)
if [[ "$ok" == true && -n "${_cache:-}" && -s "${_cache:-}" && "${RBV_CACHE_LATEST:-true}" == true ]]; then
  _cn="$(rbv_cache_prune_latest "$SID" || echo 0)"
  _cn="$(echo "$_cn" | tr -d '[:space:]')"
  [[ "$_cn" =~ ^[0-9]+$ && "$_cn" -gt 0 ]] && rep "cache: prune latest — удалено старых=${_cn}"
fi

base_name="$(basename "$KEY")"
if [[ "$ok" == true && "$base_name" == *.age ]]; then
  need age
  AGE_ID="$(rbv_cfg '.age_identity // empty')"
  if [[ -z "$AGE_ID" || "$AGE_ID" == "null" ]]; then
    fail_add "age identity unset"
    rbv_check_add decrypt fail "age_identity не задан в конфиге"
  elif ! age -d -i "$AGE_ID" -o "${ARCH_PATH}.dec" "$ARCH_PATH" 2>"${RUN_DIR}/age.err"; then
    fail_add "age decrypt failed"
    rbv_check_add decrypt fail "age -d: $(tr '\n' ' ' <"${RUN_DIR}/age.err" | head -c 200)"
  else
    mv -f "${ARCH_PATH}.dec" "$ARCH_PATH"
    rbv_check_add decrypt ok "age"
  fi
fi

EXTRACT="${RUN_DIR}/extract"
mkdir -p "$EXTRACT"
if [[ "$ok" == true ]]; then
  if ! tar -xzf "$ARCH_PATH" -C "$EXTRACT" 2>"${RUN_DIR}/tar.err"; then
    fail_add "tar extract failed"
  else
    # архив оставляем только в cache/ — из runs/ убрать сразу (ручной повтор = cache hit)
    if [[ -n "${_cache:-}" && -s "$_cache" ]]; then
      rm -f "$ARCH_PATH" 2>/dev/null || true
      rep "archive: только в cache (${_cache#"$WD"/}), из run удалён"
    fi
  fi
fi

SQL=""
REDIS_RDB=""
PROFILE_ENV=""
PG_VER="$(rbv_cfg '.pg_version // "17"')"
POSTGRES_SERVICE="postgres"
REDIS_SERVICE="redis"
RBV_PG_DB_HINT=""
RBV_PG_DB="postgres"

if [[ "$ok" == true ]]; then
  if [[ "$KIND" == "panel" ]]; then
    SQL="$(find "$EXTRACT" -type f \( -name 'dump_*.sql.gz' -o -name 'postgres_dump.sql.gz' \) | head -n1 || true)"
    DIR_TAR="$(find "$EXTRACT" -type f -name 'remnawave_dir_*.tar.gz' | head -n1 || true)"
    if [[ -n "$DIR_TAR" ]]; then
      PROJ_DIR="${RUN_DIR}/project"
      mkdir -p "$PROJ_DIR"
      tar -xzf "$DIR_TAR" -C "$PROJ_DIR" || true
      if [[ "$(find "$PROJ_DIR" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]; then
        inner="$(find "$PROJ_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
        [[ -n "$inner" ]] && PROJ_DIR="$inner"
      fi
    fi
  else
    SQL="$(find "$EXTRACT" -type f -name 'postgres_dump.sql.gz' | head -n1 || true)"
    [[ -n "$SQL" ]] || SQL="$(find "$EXTRACT" -type f -name 'dump_*.sql.gz' | head -n1 || true)"
    REDIS_RDB="$(find "$EXTRACT" -type f -name 'redis_dump.rdb' | head -n1 || true)"
    PROFILE_ENV="$(find "$EXTRACT" -type f -name 'PROFILE.env' | head -n1 || true)"
    DIR_TAR="$(find "$EXTRACT" -type f -name 'project_dir.tar.gz' | head -n1 || true)"
    if [[ -n "$PROFILE_ENV" ]]; then
      set +u
      # shellcheck disable=SC1090
      source "$PROFILE_ENV"
      set -u
      POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
      REDIS_SERVICE="${REDIS_SERVICE:-redis}"
      RBV_PG_DB_HINT="${POSTGRES_DB:-${DB_NAME:-${POSTGRES_DATABASE:-}}}"
      [[ -n "$RBV_PG_DB_HINT" ]] && rep "PROFILE: POSTGRES_DB hint=${RBV_PG_DB_HINT}"
    fi
    if [[ -n "$DIR_TAR" ]]; then
      pe="${RUN_DIR}/project_extract"
      mkdir -p "$pe"
      rep "extract project_dir.tar.gz…"
      tar -xzf "$DIR_TAR" -C "$pe"
      # pipefail+head → SIGPIPE(141) у tar; || true обязателен
      project_top="$(tar -tzf "$DIR_TAR" 2>/dev/null | head -n1 | cut -d/ -f1 || true)"
      if [[ -n "$project_top" && -d "$pe/$project_top" ]]; then
        PROJ_DIR="$pe/$project_top"
      else
        PROJ_DIR="$pe"
      fi
      if [[ -n "$REDIS_RDB" && -f "$REDIS_RDB" ]]; then
        mkdir -p "${PROJ_DIR}/volumes/redis"
        cp -f "$REDIS_RDB" "${PROJ_DIR}/volumes/redis/dump.rdb"
        chmod 644 "${PROJ_DIR}/volumes/redis/dump.rdb" || true
      fi
      rep "project_dir=${PROJ_DIR}"
    fi
  fi
  [[ -n "$SQL" ]] || fail_add "no sql dump"
  [[ -n "$SQL" ]] && rep "sql_dump=$(basename "$SQL") size=$(du -h "$SQL" 2>/dev/null | awk '{print $1}')"
fi

# --- DB restore + data checks -----------------------------------------------
# Песочница PG и restore — в lib/pg.sh (rbv_pg_start / rbv_pg_restore).
# Там же классификация сбоя (oom | external | psql_error | disk) и маркер
# завершения psql: без него оборванный restore рапортовал rc=0 с половиной
# таблиц, а дальше падал на «users table missing».
# Тюнинг PG под RAM — rbv_pg_tunables (lib/pg.sh); типовой хост verify 2–4 GiB.
DB_TABLES=0
if [[ "$ok" == true ]]; then
  # PG_CID уже задан при старте скрипта (короткое имя)
  ready=false
  accept=false

  # место под restore: ~4× .sql.gz, минимум 1.5 GiB (см. rbv_disk_need_for_sql)
  _sql_b=0
  [[ -n "${SQL:-}" && -f "${SQL:-}" ]] && _sql_b="$(stat -c%s "$SQL" 2>/dev/null || wc -c <"$SQL" | tr -d ' ')"
  _need_kb="$(rbv_disk_need_for_sql "${_sql_b:-0}")"
  [[ "$_need_kb" =~ ^[0-9]+$ ]] || _need_kb="$(rbv_disk_floor_kb)"
  _est_kb="$(rbv_disk_estimate_for_sql "${_sql_b:-0}")"
  _av_kb="$(rbv_disk_avail_kb "$WD")"
  if [[ "$_av_kb" =~ ^[0-9]+$ && "$_est_kb" =~ ^[0-9]+$ ]] && (( _av_kb < _est_kb )); then
    rep "WARN disk: свободно $(( _av_kb / 1024 ))MiB, restore этого дампа обычно требует ≈$(( _est_kb / 1024 ))MiB (SQL+индексы+WAL)"
  fi
  if ! rbv_ensure_disk_kb "$_need_kb" "$RUN_DIR"; then
    _av="$(rbv_disk_avail_kb "$WD")"
    fail_add "мало места на диске (avail=${_av:-?}KiB need=${_need_kb}KiB)"
    rbv_check_add db_schema fail "ENOSPC: свободно ${_av:-?} KiB, нужно ≥${_need_kb}"
    mark_retryable
    rep "FAIL disk: $(rbv_disk_report "$WD") — НЕ в tested (retryable)"
    rep "  → rw-backup-verify reclaim --docker"
  fi

  if [[ "$ok" == true ]] && rbv_pg_start init; then
    ready=true
    accept=true
  elif [[ "$ok" == true ]]; then
    fail_add "postgres not ready"
    mark_retryable
    rep "  → проверьте RAM/swap (free -h) и: docker logs ${PG_CID}"
  fi

  if [[ "$ok" == true && "$ready" == true && "$accept" == true ]]; then
    # сбросить page cache перед тяжёлым restore (после extract архива)
    _mr="$(rbv_mem_reclaim 2>/dev/null || true)"
    [[ -n "$_mr" ]] && rep "$_mr"
    RBV_DISK_NEED_KB="$_need_kb"
    _max_restore="${RBV_RESTORE_MAX_ATTEMPTS:-3}"
    [[ "$_max_restore" =~ ^[1-9][0-9]*$ ]] || _max_restore=3
    rbv_pg_restore "$SQL" "$_max_restore" || true
    _psql_rc="${RBV_RESTORE_RC:-1}"
    sql_errs="${RBV_RESTORE_ERRORS:-0}"
    rep "psql restore: итог class=${RBV_RESTORE_CLASS} rc=${_psql_rc} попыток=${RBV_RESTORE_ATTEMPTS} ERROR=${sql_errs}"
    case "${RBV_RESTORE_CLASS}" in
      ok)
        rbv_check_add db_restore ok "дамп применён полностью (ERROR=${sql_errs})"
        ;;
      external)
        rbv_check_add db_restore fail "песочницу удалили снаружи (docker rm -f) — restore не завершён"
        fail_add "restore прерван: песочницу удалили снаружи"
        mark_retryable
        rep "  → это НЕ нехватка RAM. Скорее всего параллельный прогон/уборка."
        rep "  → journalctl -u rw-backup-verify.service --since '-15 min'"
        ;;
      oom)
        rbv_check_add db_restore fail "OOMKilled — не хватило RAM"
        fail_add "restore прерван: OOM"
        mark_retryable
        rep "  → добавьте swap ≥2G: fallocate -l 2G /swapfile && mkswap /swapfile && swapon /swapfile"
        ;;
      disk)
        rbv_check_add db_restore fail "ENOSPC во время restore"
        fail_add "restore прерван: нет места на диске"
        mark_retryable
        ;;
      start_failed|dead)
        rbv_check_add db_restore fail "песочница не поднялась / упала во время restore"
        fail_add "restore прерван: postgres недоступен"
        mark_retryable
        ;;
      *)
        rbv_check_add db_restore fail "psql rc=${_psql_rc} (ERROR=${sql_errs})"
        fail_add "psql restore rc=${_psql_rc}"
        ;;
    esac
    if rbv_pg_alive; then
      # без $(…): выбранная БД должна остаться в текущей оболочке
      rbv_select_app_db "${RBV_PG_DB_HINT}" >/dev/null
      DB_TABLES="${RBV_PG_TABLES:-0}"
      [[ "$DB_TABLES" =~ ^[0-9]+$ ]] || DB_TABLES=0
    else
      DB_TABLES=0
      RBV_PG_DB="postgres"
      rbv_pg_diag "post-restore-dead"
    fi

    # Пустая схема после «успешного» restore = битый/пустой дамп, повтор не
    # поможет. Обрыв/OOM/внешний kill уже отработаны ретраями в rbv_pg_restore.
    if (( DB_TABLES < 1 )) && [[ "${RBV_RESTORE_CLASS}" == "ok" ]]; then
      rep "psql restore: дамп применён без ошибок, но пользовательских таблиц нет — проверьте сам архив"
    fi

    rep "db_schema: db=${RBV_PG_DB:-postgres} user_tables=${DB_TABLES} (кандидаты: ${RBV_PG_DB_LIST:-—})"
    if (( DB_TABLES < 1 )); then
      dbs="?"
      if rbv_pg_alive; then
        dbs="$(docker exec "$PG_CID" psql -U postgres -d postgres -Atc \
          "SELECT string_agg(datname, ',') FROM pg_database WHERE NOT datistemplate" 2>/dev/null || echo "?")"
      else
        rbv_pg_diag "empty-schema-dead"
      fi
      _extra=" restore=${RBV_RESTORE_CLASS}"
      _av="$(rbv_disk_avail_kb "$WD")"
      fail_add "empty schema (dbs=${dbs} sql_errors=${sql_errs}${_extra})"
      rbv_check_add db_schema fail "user tables=0 (dbs=${dbs}, sql_errors=${sql_errs}${_extra}, disk=${_av:-?}KiB)"
      if [[ -s "${RUN_DIR}/psql.err" ]]; then
        rep "----- psql.err (tail) -----"
        tail -n 15 "${RUN_DIR}/psql.err" | while IFS= read -r _line; do rep "  ${_line}"; done
        rep "----- end -----"
      fi
      rep "disk now: $(rbv_disk_report "$WD")"
    else
      rbv_check_add db_schema ok "db=${RBV_PG_DB} tables=${DB_TABLES}"
    fi

    # user_rows: не пусто + ≥ предыдущей проверки (один toggle)
    # bot → строго public.users; panel → эвристика.
    # На оборванном restore таблиц просто ещё нет — не выдаём это за потерю
    # данных в бэкапе (именно так «users table missing» маскировал внешний kill).
    if [[ "${RBV_RESTORE_CLASS}" != "ok" ]]; then
      rep "data-проверки: пропуск — restore не завершён (${RBV_RESTORE_CLASS})"
      rbv_check_enabled "$KIND" user_rows \
        && rbv_check_add user_rows skip "restore не завершён (${RBV_RESTORE_CLASS})"
      rbv_check_enabled "$KIND" event_freshness \
        && rbv_check_add event_freshness skip "restore не завершён (${RBV_RESTORE_CLASS})"
    elif [[ "$KIND" == "bot" ]]; then
      # Бот: две группы данных вместо одной public.users.
      # Нет таблицы — не ошибка (у бота нет такой функции); ошибка — если
      # таблица была в прошлой проверке и исчезла или строк стало меньше.
      _groups_found=0
      for _grp in users payments; do
        _chk="bot_${_grp}"
        rbv_check_enabled bot "$_chk" || { rbv_check_add "$_chk" skip "отключено"; continue; }
        _gstatus=""; _gdetail=""; _gsum=0; _gfound=""
        rep "----- ${_grp}: таблицы бота -----"
        while IFS='|' read -r _kind1 _f2 _f3 _f4 _f5; do
          case "$_kind1" in
            TABLE)
              case "$_f5" in
                gone) rep "  ❌ ${_f2}: таблица исчезла (было строк: ${_f4})" ;;
                drop) rep "  ❌ ${_f2}: строк ${_f3} (было ${_f4})" ;;
                ok)   rep "  ✅ ${_f2}: строк ${_f3} (было ${_f4})" ;;
                new)  rep "  ✅ ${_f2}: строк ${_f3} (первая проверка)" ;;
                empty) rep "  ⚪ ${_f2}: пустая" ;;
                absent) rep "  ⚪ ${_f2}: нет у этого бота" ;;
              esac
              if [[ "$_f3" =~ ^[0-9]+$ ]]; then
                TABLE_ROWS_PAIRS+=("${_f2}=${_f3}")
                # users отдельно — им же меряется монотонность в TG-отчёте
                [[ "$_f2" == "users" ]] && USER_ROWS="$_f3"
              fi
              ;;
            SUMMARY)
              _gstatus="$_f2"; _gfound="$_f3"; _gsum="$_f4"; _gdetail="$_f5"
              ;;
          esac
        done < <(rbv_bot_group_report "$_grp" "$BASELINE_JSON")
        rep "----- end ${_grp} -----"
        case "$_gstatus" in
          ok)
            _groups_found=$((_groups_found + 1))
            rbv_check_add "$_chk" ok "$_gdetail" "" "$_gsum"
            ;;
          fail)
            _groups_found=$((_groups_found + 1))
            rbv_check_add "$_chk" fail "$_gdetail" "" "$_gsum"
            fail_add "${_grp}: данные пропали (${_gfound})"
            ;;
          *)
            rbv_check_add "$_chk" skip "нет таблиц группы у этого бота (${_gfound})"
            rep "${_grp}: таблиц этой группы нет — для этого бота это норма"
            ;;
        esac
      done
      # ни одной таблицы из обеих групп = не тот дамп / не та БД
      if (( _groups_found == 0 )); then
        fail_add "нет ни одной таблицы бота (ни users-, ни payments-группы)"
        rbv_emit_schema_diag "bot: ни одной таблицы из групп users/payments"
      fi
      rep "bot: users=${USER_ROWS} (было ${PREV_USER_ROWS:-—})"
      if (( ${#TABLE_ROWS_PAIRS[@]} > 0 )); then
        TABLE_ROWS_JSON="$(printf '%s\n' "${TABLE_ROWS_PAIRS[@]}" \
          | jq -R -s 'split("\n") | map(select(length > 0) | split("="))
                      | map({(.[0]): (.[1] | tonumber)}) | add // {}')"
      fi
    elif rbv_check_enabled "$KIND" user_rows; then
      utbl="$(rbv_find_users_table "$KIND" || true)"
      if [[ -z "$utbl" ]]; then
        if [[ "$KIND" == "bot" ]]; then
          rbv_check_add user_rows fail "таблица public.users не найдена"
          fail_add "users table missing"
          rbv_emit_schema_diag "bot: нет public.users"
        else
          rbv_check_add user_rows skip "таблица users не найдена"
          rep "user_rows: skip (нет таблицы)"
          rbv_emit_schema_diag "panel: users table not found"
        fi
      else
        USER_ROWS="$(rbv_count_table "$utbl" || true)"
        [[ "$USER_ROWS" =~ ^[0-9]+$ ]] || USER_ROWS=0
        if (( USER_ROWS < 1 )); then
          rbv_check_add user_rows fail "users(${utbl})=0" "${PREV_USER_ROWS:-}" "$USER_ROWS"
          fail_add "users empty"
        elif [[ -n "$PREV_USER_ROWS" && "$PREV_USER_ROWS" =~ ^[0-9]+$ ]]; then
          if (( USER_ROWS < PREV_USER_ROWS )); then
            rbv_check_add user_rows fail \
              "users меньше предыдущей проверки" "$PREV_USER_ROWS" "$USER_ROWS"
            fail_add "user_rows ${USER_ROWS}<${PREV_USER_ROWS}"
          else
            rbv_check_add user_rows ok \
              "users(${utbl})=${USER_ROWS} ≥ prev" "$PREV_USER_ROWS" "$USER_ROWS"
          fi
        else
          rbv_check_add user_rows ok \
            "users(${utbl})=${USER_ROWS} (первый baseline)" "" "$USER_ROWS"
        fi
        rep "user_rows=${USER_ROWS} table=${utbl:-?}"
      fi
    fi

    # event freshness (relative to backup window + skew)
    # bot → самая свежая дата среди платёжных таблиц, что есть у бота
    # (иначе среди пользовательских); panel → users/nodes.
    if [[ "${RBV_RESTORE_CLASS}" == "ok" ]] && rbv_check_enabled "$KIND" event_freshness; then
      _ev_out="$(rbv_max_event_epoch "$KIND" | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      _ev_src=""
      LAST_EVENT=0
      case "$_ev_out" in
        missing|nofields)
          if [[ "$KIND" == "bot" ]]; then
            # нет ни одной даты ни в платежах, ни у пользователей — у такого
            # бота свежесть просто нечем мерить, это не потеря данных
            rbv_check_add event_freshness skip \
              "нет timestamp-колонок в таблицах бота"
            rep "event_freshness: skip — у этого бота нет дат в users/payments"
          else
            rbv_check_add event_freshness skip "нет timestamp-колонок событий"
            rbv_emit_schema_diag "panel: event timestamp fields missing"
          fi
          ;;
        *)
          LAST_EVENT="${_ev_out%%|*}"
          if [[ "$_ev_out" == *"|"* ]]; then
            _ev_src="${_ev_out#*|}"
          fi
          [[ "$LAST_EVENT" =~ ^[0-9]+$ ]] || LAST_EVENT=0
          skew="$(rbv_skew_sec)"
          if [[ "${LAST_EVENT:-0}" -eq 0 ]]; then
            if [[ "$KIND" == "bot" ]]; then
              rbv_check_add event_freshness skip \
                "таблицы бота есть, но дат в них нет (src=${_ev_src:-?})"
              rep "event_freshness: skip — таблицы есть, дат нет (src=${_ev_src:-?})"
            else
              rbv_check_add event_freshness skip "нет timestamp-колонок событий"
            fi
          elif [[ "${CURR_ARCH_EPOCH:-0}" -eq 0 ]]; then
            rbv_check_add event_freshness skip "не разобрать TS архива"
          else
            if [[ "${PREV_ARCH_EPOCH:-0}" -gt 0 ]]; then
              local_lo=$(( PREV_ARCH_EPOCH - skew ))
            else
              local_lo=$(( CURR_ARCH_EPOCH - skew - 86400*30 ))
            fi
            local_hi=$(( CURR_ARCH_EPOCH + skew ))
            if (( LAST_EVENT < local_lo || LAST_EVENT > local_hi )); then
              rbv_check_add event_freshness fail \
                "событие вне окна [prev−skew … curr+skew] (skew=${skew}s, src=${_ev_src:-?})" \
                "$(date -u -d "@${PREV_ARCH_EPOCH}" +%F_%T 2>/dev/null || echo "$PREV_ARCH_EPOCH")" \
                "event=$(date -u -d "@${LAST_EVENT}" +%F_%T 2>/dev/null || echo "$LAST_EVENT"); arch=$(date -u -d "@${CURR_ARCH_EPOCH}" +%F_%T 2>/dev/null || echo "$CURR_ARCH_EPOCH")"
              fail_add "event_freshness out of window"
            else
              rbv_check_add event_freshness ok \
                "событие в окне бекапов (±${skew}s TZ lag, src=${_ev_src:-?})" \
                "prev_arch=${PREV_ARCH_EPOCH}" "event=${LAST_EVENT}/arch=${CURR_ARCH_EPOCH}"
            fi
          fi
          ;;
      esac
      rep "event_freshness: last_event=${LAST_EVENT:-0} src=${_ev_src:-?} raw=${_ev_out}"
    fi
  fi
fi

# --- stack (= up + stability) + isolation / ports ---------------------------
STACK_OK="skip"
STACK_DETAIL=""
SETTLE="$(rbv_cfg '.settle_seconds // 25')"
SAMPLE_CID=""

if [[ "$ok" == true && -n "${PROJ_DIR:-}" ]] && rbv_check_enabled "$KIND" stack; then
  CF=""
  for c in "${PROJ_DIR}/docker-compose.yml" "${PROJ_DIR}/docker-compose.yaml" \
           "${PROJ_DIR}/compose.yml" "${PROJ_DIR}/compose.yaml"; do
    [[ -f "$c" ]] && { CF="$c"; break; }
  done
  if [[ -z "$CF" ]]; then
    rbv_check_add stack skip "compose не найден"
    rep "stack: compose не найден — skip"
    # всё равно покажем, что лежит в бэкапе
    {
      echo "# search compose under PROJ_DIR=${PROJ_DIR:-?}"
      find "${PROJ_DIR:-/nonexistent}" -maxdepth 4 \( \
        -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' \
      \) 2>/dev/null | sort || true
    } >"${RUN_DIR}/compose.files.txt" || true
    if [[ -s "${RUN_DIR}/compose.files.txt" ]]; then
      rep "----- compose search in backup -----"
      while IFS= read -r _line; do rep "  ${_line}"; done <"${RUN_DIR}/compose.files.txt"
      rep "----- end -----"
    fi
  else
    rep "stack: compose=${CF}"
    rep "stack: project_dir=${PROJ_DIR}"
    rep "stack: compose project=${COMPOSE_PROJECT}"

    # --- дамп compose из бэкапа (оригинал) + вспомогательные файлы ---
    # (rep_file определён выше)

    # копия оригинального compose из архива
    _bext="yml"
    [[ "$CF" == *.yaml ]] && _bext="yaml"
    BACKUP_COMPOSE_COPY="${RUN_DIR}/compose.from-backup.${_bext}"
    cp -f "$CF" "$BACKUP_COMPOSE_COPY"
    rep_file "compose FROM BACKUP (raw)" "$BACKUP_COMPOSE_COPY" 200

    {
      echo "# infra files in project_dir (compose / env / Dockerfile)"
      find "$PROJ_DIR" -maxdepth 3 \( \
        -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' \
        -o -name '.env' -o -name '.env.*' -o -name 'Dockerfile*' \
        -o -name '*.override.yml' -o -name '*.override.yaml' \
      \) 2>/dev/null | sort
    } >"${RUN_DIR}/compose.files.txt" || true
    rep_file "compose.files" "${RUN_DIR}/compose.files.txt" 80

    if [[ -f "${PROJ_DIR}/.env" ]]; then
      # ключи без значений
      awk -F= '
        /^[[:space:]]*#/ {next}
        NF && $1 !~ /^[[:space:]]*$/ {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
          if ($1 != "") print $1
        }
      ' "${PROJ_DIR}/.env" 2>/dev/null | head -n 120 >"${RUN_DIR}/compose.env.keys.txt" || true
      # .env с маскированными значениями (для ручной правки инфры)
      awk -F= '
        /^[[:space:]]*#/ || NF==0 {print; next}
        {
          k=$1; sub(/^[^=]*=/, "")
          v=$0
          if (k ~ /(PASS|SECRET|TOKEN|KEY|URL|URI|DSN)/) {
            if (v ~ /:\/\//) {
              gsub(/:\/\/[^@\/]+@/, "://***@", v)
              gsub(/:[^:@\/]+@/, ":***@", v)
            } else if (length(v) > 0) { v="***" }
          }
          print k "=" v
        }
      ' "${PROJ_DIR}/.env" 2>/dev/null | rbv_mask_secrets >"${RUN_DIR}/compose.env.masked" || true
      if [[ -s "${RUN_DIR}/compose.env.keys.txt" ]]; then
        rep "stack: .env keys ($(wc -l <"${RUN_DIR}/compose.env.keys.txt" | tr -d ' ')): $(tr '\n' ',' <"${RUN_DIR}/compose.env.keys.txt" | head -c 500)"
      fi
      rep_file "compose.env.masked (from backup)" "${RUN_DIR}/compose.env.masked" 80
    fi

    NET_NAME="${COMPOSE_PROJECT}_net"
    docker network create --internal "$NET_NAME" >/dev/null
    COMPOSE_FILE="${RUN_DIR}/compose.isolated.yml"

    # .env + stub для ${BACKEND_IMAGE:?…} и т.п. (swarm/bot часто без image в архиве)
    COMPOSE_ENV="${RUN_DIR}/compose.env.effective"
    STUB_VARS="$(rbv_compose_prepare_env "$PROJ_DIR" "$CF" "$COMPOSE_ENV" | tr -d '\n')"
    if [[ -n "${STUB_VARS// }" ]]; then
      rep "stack: WARN stub env (нет в бэкапе): ${STUB_VARS}"
      rep "  → образы задаются при деплое; stack up будет skip, если image=rbv-missing/*"
    fi
    rbv_mask_secrets <"$COMPOSE_ENV" >"${RUN_DIR}/compose.env.effective.masked" 2>/dev/null || true

    # Резолв compose из каталога проекта
    set +e
    (
      cd "$PROJ_DIR" || exit 1
      cf_arg="$CF"
      case "$CF" in
        "$PROJ_DIR"/*) cf_arg="${CF#"$PROJ_DIR"/}" ;;
      esac
      docker compose --env-file "$COMPOSE_ENV" -f "$cf_arg" config --format json
    ) >"$COMPOSE_RAW" 2>"${RUN_DIR}/compose.cfg.err"
    cfg_rc=$?
    set -e

    # resolved YAML из бэкапа
    set +e
    (
      cd "$PROJ_DIR" || exit 1
      cf_arg="$CF"
      case "$CF" in
        "$PROJ_DIR"/*) cf_arg="${CF#"$PROJ_DIR"/}" ;;
      esac
      docker compose --env-file "$COMPOSE_ENV" -f "$cf_arg" config
    ) >"${RUN_DIR}/compose.from-backup.resolved.yml" 2>>"${RUN_DIR}/compose.cfg.err"
    set -e
    if [[ -s "${RUN_DIR}/compose.from-backup.resolved.yml" ]]; then
      rbv_mask_secrets <"${RUN_DIR}/compose.from-backup.resolved.yml" \
        >"${RUN_DIR}/compose.from-backup.resolved.masked.yml"
      rep_file "compose FROM BACKUP (resolved+masked)" "${RUN_DIR}/compose.from-backup.resolved.masked.yml" 200
    fi

    if [[ $cfg_rc -ne 0 || ! -s "$COMPOSE_RAW" ]]; then
      rbv_check_add stack fail "compose config failed"
      fail_add "compose config"
      rep "stack: compose config failed — см. ${RUN_DIR}/compose.cfg.err"
      if [[ -s "${RUN_DIR}/compose.cfg.err" ]]; then
        rep_file "compose.cfg.err" "${RUN_DIR}/compose.cfg.err" 40
      fi
      rep "stack: оригинал из бэкапа: ${BACKUP_COMPOSE_COPY}"
      rep "stack: effective env: ${COMPOSE_ENV}"
      rep "stack: править инфру → скопируйте compose/env из ${RUN_DIR}/ и перезапустите"
    else
      # Убираем postgres-сервис (его заменяет наш PG_CID) и переписываем
      # DATABASE_URL/DB_HOST/REDIS_HOST → sandbox.
      jq --arg net "$NET_NAME" --arg pgsvc "${POSTGRES_SERVICE}" --arg pgdb "${RBV_PG_DB:-postgres}" '
        def fix_pg_url:
          if type != "string" then .
          elif (test("(?i)^postgres(ql)?://") | not) then .
          elif test("@") then
            (capture("(?<pre>.*://[^/@]+@)[^/?#]+(?::(?<port>[0-9]+))?(?:/(?<db>[^/?#]*))?(?<q>[?#].*)?") // null) as $m
            | if $m then "\($m.pre)remnawave-db:5432/\($pgdb)\($m.q // "")" else . end
          else
            (capture("(?<pre>.*://)[^/?#]+(?::(?<port>[0-9]+))?(?:/(?<db>[^/?#]*))?(?<q>[?#].*)?") // null) as $m
            | if $m then "\($m.pre)remnawave-db:5432/\($pgdb)\($m.q // "")" else . end
          end;
        def fix_env:
          if type == "object" then
            with_entries(
              if (.key | test("(?i)^(DATABASE_URL|DIRECT_URL|POSTGRES_URL|SQLALCHEMY_DATABASE_URL|DATABASE_URI)$"))
              then .value |= fix_pg_url
              elif (.key | test("(?i)^(POSTGRES_HOST|PGHOST|DB_HOST|DATABASE_HOST)$"))
              then .value = "remnawave-db"
              elif (.key | test("(?i)^(POSTGRES_PORT|PGPORT|DB_PORT|DATABASE_PORT)$"))
              then .value = "5432"
              elif (.key | test("(?i)^(POSTGRES_DB|PGDATABASE|DB_NAME|DATABASE_NAME)$"))
              then .value = $pgdb
              elif (.key | test("(?i)^(REDIS_HOST|REDIS_URL)$"))
              then .value = (if (.key|test("URL")) then ("redis://remnawave-redis:6379") else "remnawave-redis" end)
              else . end
            )
          elif type == "array" then
            map(
              if type == "string" and test("=") then
                (index("=") as $i | .[0:$i] as $k | .[$i+1:] as $v |
                  if ($k | test("(?i)^(DATABASE_URL|DIRECT_URL|POSTGRES_URL|SQLALCHEMY_DATABASE_URL|DATABASE_URI)$"))
                  then "\($k)=\($v | fix_pg_url)"
                  elif ($k | test("(?i)^(POSTGRES_HOST|PGHOST|DB_HOST|DATABASE_HOST)$"))
                  then "\($k)=remnawave-db"
                  elif ($k | test("(?i)^(POSTGRES_PORT|PGPORT|DB_PORT|DATABASE_PORT)$"))
                  then "\($k)=5432"
                  elif ($k | test("(?i)^(POSTGRES_DB|PGDATABASE|DB_NAME|DATABASE_NAME)$"))
                  then "\($k)=\($pgdb)"
                  elif ($k | test("(?i)^REDIS_HOST$"))
                  then "\($k)=remnawave-redis"
                  elif ($k | test("(?i)^REDIS_URL$"))
                  then "\($k)=redis://remnawave-redis:6379"
                  else .
                  end)
              else . end
            )
          else . end;
        .networks = {"rbv": {"name": $net, "external": true}}
        | .services = (.services | to_entries | map(
            .value |= (
              del(.ports, .container_name, .env_file, .network_mode, .links, .deploy)
              | .networks = {"rbv": {}}
              | .restart = "no"
              | if .environment then .environment |= fix_env else . end
              | if .volumes then
                  .volumes |= map(select(
                    (type=="object" and ((.source // "") | contains("docker.sock") | not)
                      and ((.source // "") | test("(^|/)\\.env$") | not)
                      and ((.source // "") | test("(?i)(^|/)pgdata(/|$)|/var/lib/postgresql|pg_wal") | not)
                      and ((.target // .destination // "") | test("(?i)/var/lib/postgresql|pg_wal|(^|/)pgdata(/|$)") | not))
                    or (type=="string" and (contains("docker.sock") | not)
                      and (test("(^|:)/\\.env$|\\.env:") | not)
                      and (test("(?i)(^|/)pgdata(/|:|$)|/var/lib/postgresql|pg_wal") | not))
                  ))
                else . end
            )
            | {key: .key, value: .value}
          ) | from_entries)
        | .services |= with_entries(
            select(
              (.key != $pgsvc)
              and ((.value.image // "") | test("postgres"; "i") | not)
            )
          )
        | if .volumes then
            .volumes |= with_entries(select(.value.external != true))
          else . end
      ' "$COMPOSE_RAW" > "$COMPOSE_FILE"

      # Сводка сервисов: backup vs isolated
      jq -r '
        .services // {} | to_entries[] |
        "\(.key)\timage=\(.value.image // "-")\tports=\((.value.ports // [])|tostring)"
      ' "$COMPOSE_RAW" 2>/dev/null >"${RUN_DIR}/compose.services.backup.txt" || true
      jq -r '
        .services // {} | to_entries[] |
        "\(.key)\timage=\(.value.image // "-")"
      ' "$COMPOSE_FILE" 2>/dev/null >"${RUN_DIR}/compose.services.isolated.txt" || true
      rep_file "services FROM BACKUP" "${RUN_DIR}/compose.services.backup.txt" 40
      rep_file "services ISOLATED (sandbox)" "${RUN_DIR}/compose.services.isolated.txt" 40

      # человекочитаемый isolated YAML
      set +e
      docker compose -f "$COMPOSE_FILE" config \
        >"${RUN_DIR}/compose.isolated.resolved.yml" 2>"${RUN_DIR}/compose.isolated.cfg.err"
      set -e
      if [[ -s "${RUN_DIR}/compose.isolated.resolved.yml" ]]; then
        rbv_mask_secrets <"${RUN_DIR}/compose.isolated.resolved.yml" \
          >"${RUN_DIR}/compose.isolated.masked.yml"
        rep_file "compose ISOLATED (resolved+masked)" "${RUN_DIR}/compose.isolated.masked.yml" 200
      else
        rep_file "compose ISOLATED (json)" "$COMPOSE_FILE" 120
      fi
      rep "stack: файлы для правки: ${RUN_DIR}/compose.from-backup* ${RUN_DIR}/compose.isolated*"

      # Показать, куда ушли DB URL (без пароля)
      db_urls="$(jq -r '
        .services // {} | to_entries[] | .value.environment
        | if type=="object" then to_entries[] | select(.key|test("(?i)DATABASE_URL|DIRECT_URL|DB_HOST|REDIS_HOST")) | "\(.key)=\(.value)"
          elif type=="array" then .[] | select(test("(?i)^(DATABASE_URL|DIRECT_URL|DB_HOST|REDIS_HOST)="))
          else empty end
      ' "$COMPOSE_FILE" 2>/dev/null | rbv_mask_secrets | head -n 12 || true)"
      if [[ -n "$db_urls" ]]; then
        rep "stack: DB/Redis env после rewrite:"
        while IFS= read -r _line; do [[ -n "$_line" ]] && rep "  ${_line}"; done <<<"$db_urls"
      else
        rep "stack: WARN — DATABASE_URL/DB_HOST не найдены в compose environment (проверьте env_file)"
      fi

      # Нет реальных образов (BACKEND_IMAGE не в бэкапе) → stack skip, не fail
      _missing_img="$(jq -r '.services // {} | to_entries[] | .value.image // empty' "$COMPOSE_FILE" 2>/dev/null \
        | grep -E 'rbv-missing' || true)"
      if [[ -n "$_missing_img" ]]; then
        STACK_OK="skip"
        STACK_DETAIL="нет образов в бэкапе (stubs: ${STUB_VARS:-?})"
        rbv_check_add stack skip "$STACK_DETAIL"
        rep "stack: SKIP compose up — в архиве нет BACKEND_IMAGE/CABINET_IMAGE (задаются при деплое)"
        rep "stack: stub images:"
        while IFS= read -r _line; do [[ -n "$_line" ]] && rep "  ${_line}"; done <<<"$_missing_img"
        rep "stack: data-проверки (schema/users) уже пройдены; для stack положите image tags в .env бэкапа"
        if rbv_check_enabled "$KIND" isolation; then
          rbv_check_add isolation skip "нет stack up"
        fi
        if rbv_check_enabled "$KIND" backend_ports; then
          rbv_check_add backend_ports skip "нет stack up"
        fi
      else
      docker network disconnect "$NET_NAME" "$PG_CID" 2>/dev/null || true
      docker network connect \
        --alias db --alias postgres --alias remnawave-db --alias postgresql \
        --alias remnawave_db --alias database \
        --alias "${POSTGRES_SERVICE}" \
        "$NET_NAME" "$PG_CID" 2>/dev/null \
        || docker network connect "$NET_NAME" "$PG_CID" || true

      rep "stack: compose pull (новые теги из бэкапа) + up -d (project=${COMPOSE_PROJECT}, сеть ${NET_NAME})…"
      set +e
      # образы храним; при смене тега в compose — докачиваем (не prune images)
      docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" pull \
        >"${RUN_DIR}/compose.pull.out" 2>"${RUN_DIR}/compose.pull.err"
      docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" up -d --no-build \
        >"${RUN_DIR}/compose.up.out" 2>"${RUN_DIR}/compose.up.err"
      up_rc=$?
      set -e
      if [[ -s "${RUN_DIR}/compose.pull.out" ]]; then
        rep_file "compose pull" "${RUN_DIR}/compose.pull.out" 20
      fi
      if [[ -s "${RUN_DIR}/compose.up.out" ]]; then
        rep_file "compose up stdout" "${RUN_DIR}/compose.up.out" 40
      fi
      if [[ $up_rc -ne 0 ]]; then
        STACK_OK="fail"
        STACK_DETAIL="compose up rc=${up_rc}"
        err_snip="$(tail -n 8 "${RUN_DIR}/compose.up.err" 2>/dev/null | tr '\n' ' ' | head -c 500)"
        rbv_check_add stack fail "$STACK_DETAIL: ${err_snip}"
        fail_add "stack up failed: ${err_snip}"
        rep "stack up FAILED — полный лог: ${RUN_DIR}/compose.up.err"
        rep_file "compose.up.err" "${RUN_DIR}/compose.up.err" 40
      else
        rep "stack: settle ${SETTLE}с…"
        _left="$SETTLE"
        while (( _left > 0 )); do
          _step=5
          (( _left < _step )) && _step=$_left
          sleep "$_step"
          _left=$((_left - _step))
          if (( _left > 0 )); then
            rep "stack: settle, осталось ~${_left}с"
          fi
        done
        running="$(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
        total="$(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -q 2>/dev/null | wc -l | tr -d ' ')"
        STACK_DETAIL="containers ${running}/${total}"
        SAMPLE_CID="$(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -q 2>/dev/null | head -n1 || true)"
        # предпочитаем app-контейнер (не redis) для isolation sample
        while IFS= read -r _cid; do
          [[ -n "$_cid" ]] || continue
          _svc="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$_cid" 2>/dev/null || true)"
          if [[ "$_svc" != *redis* && "$_svc" != *valkey* ]]; then
            SAMPLE_CID="$_cid"
            break
          fi
        done < <(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -q 2>/dev/null || true)
        rep "stack: после settle ${STACK_DETAIL}"

        # всегда пишем ps + логи в run dir и в отчёт (для ручной корректировки)
        docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -a \
          >"${RUN_DIR}/compose.ps.txt" 2>&1 || true
        rep_file "compose ps" "${RUN_DIR}/compose.ps.txt" 40
        {
          echo "=== compose ps ==="
          cat "${RUN_DIR}/compose.ps.txt" 2>/dev/null || true
          echo
          while IFS= read -r _cid; do
            [[ -n "$_cid" ]] || continue
            _name="$(docker inspect -f '{{.Name}}' "$_cid" 2>/dev/null | sed 's#^/##')"
            echo "=== logs: ${_name} (tail 60) ==="
            docker logs --tail 60 "$_cid" 2>&1 || true
            echo
          done < <(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -aq 2>/dev/null || true)
        } >"${RUN_DIR}/compose.logs.txt" 2>&1 || true
        rep_file "compose logs (tail)" "${RUN_DIR}/compose.logs.txt" 100

        if [[ "${running:-0}" -lt 1 ]]; then
          STACK_OK="fail"
          rbv_check_add stack fail "после up: $STACK_DETAIL"
          fail_add "no running containers"
        else
          STACK_OK="ok"
          # isolation СРАЗУ после up/settle — до stability (180с) и ports
          if rbv_check_enabled "$KIND" isolation; then
            rep "check isolation (до stability)…"
            if ! rbv_check_isolation "$SAMPLE_CID"; then
              STACK_OK="fail"
              fail_add "isolation leak — дальнейшие stack-тесты остановлены"
              rbv_check_add stack skip "остановлено: isolation fail"
              if rbv_check_enabled "$KIND" backend_ports; then
                rbv_check_add backend_ports skip "остановлено: isolation fail"
              fi
            fi
          else
            rbv_check_add isolation skip "отключено"
          fi

          if [[ "$STACK_OK" == "ok" ]]; then
            stab="$(rbv_stability_sec)"
            rep "stack: stability window ${stab}с…"
            if ! rbv_check_stability "${COMPOSE_PROJECT}" "$COMPOSE_FILE" "$stab"; then
              STACK_OK="fail"
              fail_add "stack stability"
              {
                echo "=== compose ps (after stability fail) ==="
                docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -a 2>&1 || true
                echo
                while IFS= read -r _cid; do
                  [[ -n "$_cid" ]] || continue
                  _name="$(docker inspect -f '{{.Name}}' "$_cid" 2>/dev/null | sed 's#^/##')"
                  echo "=== logs: ${_name} (tail 80) ==="
                  docker logs --tail 80 "$_cid" 2>&1 || true
                  echo
                done < <(docker compose -f "$COMPOSE_FILE" -p "${COMPOSE_PROJECT}" ps -aq 2>/dev/null || true)
              } >"${RUN_DIR}/compose.logs.txt" 2>&1 || true
              rep_file "compose logs after fail" "${RUN_DIR}/compose.logs.txt" 120
            fi
          fi

          if [[ "$STACK_OK" == "ok" ]] && rbv_check_enabled "$KIND" backend_ports; then
            rep "check backend_ports…"
            if ! rbv_check_backend_ports "$NET_NAME" "$COMPOSE_RAW" "${COMPOSE_PROJECT}"; then
              fail_add "backend_ports"
            fi
          elif [[ "$STACK_OK" == "ok" ]] && ! rbv_check_enabled "$KIND" backend_ports; then
            rbv_check_add backend_ports skip "отключено"
          fi
        fi
      fi
      fi  # missing images vs real up
    fi
  fi
elif ! rbv_check_enabled "$KIND" stack; then
  rbv_check_add stack skip "отключено"
  rep "stack: отключено в checks"
fi

fi  # ok after preflight — download/restore/stack

# --- save baseline (только при успехе данных) ------------------------------
if [[ "$ok" == true || "$USER_ROWS" -gt 0 ]]; then
  new_base="$(jq -n \
    --argjson ur "${USER_ROWS:-0}" \
    --argjson at "${CURR_ARCH_EPOCH:-0}" \
    --argjson le "${LAST_EVENT:-0}" \
    --arg key "$KEY" \
    --argjson ts "$(date +%s)" \
    --argjson tables "${DB_TABLES:-0}" \
    --argjson rows "${TABLE_ROWS_JSON:-\{\}}" \
    '{user_rows:$ur, archive_ts:$at, last_event_epoch:$le, archive_key:$key, tested_at:$ts, db_tables:$tables, tables:$rows}')"
  # обновляем baseline всегда при успешном DB restore (даже если stack fail) —
  # иначе монотонность users не сдвинется после починки стека
  if [[ "${DB_TABLES:-0}" -gt 0 ]]; then
    rbv_baseline_save "$SID" "$INST" "$new_base"
  fi
fi

ended="$(date -Is)"
rep "finished=${ended} result=$([[ $ok == true ]] && echo OK || echo FAIL)"

# --- Telegram ---------------------------------------------------------------
TG_LINE="$(rbv_tg_for_storage "$SID")"
IFS='|' read -r TOK CHAT THREAD <<<"$TG_LINE"
body="$(rbv_format_tg_report "$SID" "$KIND" "$INST" "$KEY" "$ok")"
body+=$'\n'"⏱ ${ended}"
if [[ -n "$TOK" && -n "$CHAT" ]]; then
  rep "telegram: отправка в chat=${CHAT} thread=${THREAD:-—}"
else
  rep "telegram: ПРОПУСК — нет token/chat_id (rw-backup-verify telegram show)"
fi

notify_ok="$(rbv_cfg '.notify_on_success // true')"
if [[ "$ok" != true ]] || [[ "$notify_ok" == "true" ]]; then
  rbv_tg_send_long "$TOK" "$CHAT" "$body" "$THREAD"
  if [[ "$ok" != true && -n "${COMPOSE_FILE}" && -f "${COMPOSE_FILE}" ]]; then
    rbv_tg_send_logs "$TOK" "$CHAT" "$THREAD" "${COMPOSE_PROJECT}" "$COMPOSE_FILE"
  fi
fi

# CHECKS_JSON уже = ${RUN_DIR}/checks.json — не cp сам в себя
jq -n \
  --arg sid "$SID" --arg kind "$KIND" --arg inst "$INST" --arg key "$KEY" \
  --argjson ok "$ok" --argjson tables "${DB_TABLES:-0}" --argjson users "${USER_ROWS:-0}" \
  --slurpfile checks "$CHECKS_JSON" \
  '{storage:$sid,kind:$kind,instance:$inst,archive:$key,ok:$ok,db_tables:$tables,user_rows:$users,checks:$checks[0]}' \
  > "${RUN_DIR}/summary.json"

if [[ "$ok" == true ]]; then
  exit 0
fi
# 75 = EX_TEMPFAIL: worker не помечает tested (можно повторить тот же архив)
if [[ "${RBV_RETRYABLE:-0}" == "1" || -f "${RUN_DIR}/.retryable" ]]; then
  exit 75
fi
exit 1
