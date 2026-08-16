#!/usr/bin/env bash
# Песочница Postgres для verify: старт, восстановление дампа, диагностика.
# Source после common.sh. Ожидает от вызывающего: PG_CID, PG_VER, RUN_DIR.
# Вывод шагов — через rbv_say (rbv-run-one подменяет на rep → report.txt).
set -euo pipefail

[[ -n "${__RBV_PG:-}" ]] && return 0
__RBV_PG=1

# Результат последнего restore (читает rbv-run-one):
#   RBV_RESTORE_RC       — rc psql внутри контейнера (или 137/1 при обрыве)
#   RBV_RESTORE_CLASS    — ok | psql_error | oom | external | dead | start_failed
#   RBV_RESTORE_ERRORS   — число строк ERROR в psql.err
#   RBV_RESTORE_ATTEMPTS — сколько попыток сделано
RBV_RESTORE_RC=1
RBV_RESTORE_CLASS="dead"
RBV_RESTORE_ERRORS=0
RBV_RESTORE_ATTEMPTS=0

rbv_pg_alive() {
  [[ -n "${PG_CID:-}" ]] || return 1
  docker inspect -f '{{.State.Running}}' "$PG_CID" 2>/dev/null | grep -qx true
}

# Контейнера нет вовсе (удалён снаружи) → rc=0.
rbv_pg_gone() {
  [[ -n "${PG_CID:-}" ]] || return 0
  ! docker inspect "$PG_CID" >/dev/null 2>&1
}

# status|running|oom|exit одной строкой (или пусто, если контейнера нет).
rbv_pg_state() {
  [[ -n "${PG_CID:-}" ]] || return 0
  docker inspect -f '{{.State.Status}}|{{.State.Running}}|{{.State.OOMKilled}}|{{.State.ExitCode}}' \
    "$PG_CID" 2>/dev/null || true
}

# Почему песочница умерла: oom | external | crash | alive.
# Ключевое отличие: OOMKilled=true — это реально нехватка RAM;
# exit=137 при OOMKilled=false и Status=removing/removed — это внешний
# `docker rm -f` (параллельный reclaim/run/чужие руки), а не OOM.
rbv_pg_kill_reason() {
  local st status running oom code
  if rbv_pg_gone; then
    printf 'external\n'
    return 0
  fi
  st="$(rbv_pg_state)"
  IFS='|' read -r status running oom code <<<"${st:-|||}"
  if [[ "$running" == "true" ]]; then
    printf 'alive\n'
    return 0
  fi
  # kernel OOM killer — единственный источник OOMKilled=true
  if [[ "$oom" == "true" ]]; then
    printf 'oom\n'
    return 0
  fi
  case "$status" in
    removing|removed|dead) printf 'external\n'; return 0 ;;
  esac
  # SIGKILL/SIGTERM без OOMKilled = контейнер прибили снаружи
  # (`docker rm -f` успевает мелькнуть в статусе exited до удаления).
  # Падение самого postgres даёт другой код выхода.
  case "$code" in
    137|143) printf 'external\n'; return 0 ;;
  esac
  printf 'crash\n'
  return 0
}

rbv_pg_diag() {
  local tag="${1:-diag}" reason
  reason="$(rbv_pg_kill_reason)"
  rbv_say "postgres[${tag}]: --- состояние (${reason}) ---"
  if [[ -n "${PG_CID:-}" ]]; then
    if docker inspect "$PG_CID" >/dev/null 2>&1; then
      docker inspect -f 'status={{.State.Status}} running={{.State.Running}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}} error={{.State.Error}}' \
        "$PG_CID" 2>/dev/null | while IFS= read -r _line; do rbv_say "  ${_line}"; done || true
      if docker logs "$PG_CID" >/dev/null 2>&1; then
        rbv_say "  ----- docker logs (tail 25) -----"
        docker logs --tail 25 "$PG_CID" 2>&1 | while IFS= read -r _line; do rbv_say "  ${_line}"; done || true
        rbv_say "  ----- end logs -----"
      fi
    else
      rbv_say "  контейнер ${PG_CID} исчез (удалён снаружи)"
    fi
  fi
  case "$reason" in
    external)
      rbv_say "  ДИАГНОЗ: песочницу удалили снаружи (docker rm -f), это НЕ нехватка RAM."
      rbv_say "  Обычно это параллельный 'rw-backup-verify run/reclaim' (systemd-таймер тикает раз в минуту)."
      rbv_say "  Смотрите: journalctl -u rw-backup-verify.service --since '-10 min'"
      ;;
    oom)
      rbv_say "  ДИАГНОЗ: OOMKilled=true — не хватило RAM. Нужен swap ≥2G на хосте verify."
      ;;
  esac
  if command -v free >/dev/null 2>&1; then
    rbv_say "  mem: $(free -m | awk '/Mem:/{printf "avail=%sMi total=%sMi", $7, $2}')"
  fi
  df -h /var/lib/docker 2>/dev/null | tail -n1 | while IFS= read -r _line; do rbv_say "  disk docker: ${_line}"; done || true
  return 0
}

# Доступная RAM в MiB (0 если не определить).
rbv_mem_avail_mb() {
  local m=0
  if command -v free >/dev/null 2>&1; then
    m="$(free -m | awk '/Mem:/{print $7}')"
  fi
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s\n' "$m"
}

# Параметры postgres под доступную RAM → массив RBV_PG_ARGS.
# Песочница одноразовая: fsync/full_page_writes/synchronous_commit off —
# restore 200–500 M дампа ускоряется в разы и меньше пишет на диск.
# Раньше значения были фиксированно микроскопическими (maintenance_work_mem=32MB),
# из-за чего построение индексов растягивалось на десятки минут.
rbv_pg_tunables() {
  local avail="${1:-0}"
  local shared=64 work=2 maint=64 wal=512 cache=256
  if (( avail >= 6000 )); then
    shared=512; work=16; maint=512; wal=2048; cache=2048
  elif (( avail >= 3000 )); then
    shared=192; work=8; maint=256; wal=1024; cache=1024
  elif (( avail >= 1800 )); then
    shared=128; work=4; maint=128; wal=768; cache=512
  fi
  RBV_PG_ARGS=(
    -c "shared_buffers=${shared}MB"
    -c "work_mem=${work}MB"
    -c "maintenance_work_mem=${maint}MB"
    -c "effective_cache_size=${cache}MB"
    -c "max_wal_size=${wal}MB"
    -c hash_mem_multiplier=1.0
    -c min_wal_size=80MB
    -c checkpoint_completion_target=0.9
    -c wal_buffers=16MB
    -c max_parallel_workers=0
    -c max_parallel_workers_per_gather=0
    -c max_parallel_maintenance_workers=0
    -c autovacuum=off
    -c fsync=off
    -c full_page_writes=off
    -c synchronous_commit=off
    -c jit=off
  )
}

# Поднять чистую песочницу. $1 — причина (init|retry-N|schema-retry). rc=0 если готова.
rbv_pg_start() {
  local why="${1:-init}"
  local wait_s=120
  local shm=256m
  local mem_avail
  mem_avail="$(rbv_mem_avail_mb)"
  (( mem_avail >= 6000 )) && shm=512m

  docker rm -f "$PG_CID" >/dev/null 2>&1 || true
  # чужие rbv_pg_* после OOM/crash занимают RAM — снять, но НЕ трогать песочницы
  # живых прогонов (иначе повторяем баг, который убивал restore)
  local _old
  while IFS= read -r _old; do
    [[ -n "$_old" && "$_old" != "$PG_CID" ]] || continue
    rbv_is_protected "$_old" pg_cid && continue
    docker rm -f "$_old" >/dev/null 2>&1 || true
  done < <(docker ps -a --filter "name=rbv_pg_" --format '{{.Names}}' 2>/dev/null || true)
  rbv_mem_reclaim >/dev/null 2>&1 || true

  rbv_pg_tunables "$mem_avail"
  rbv_say "postgres: старт image=postgres:${PG_VER}-alpine name=${PG_CID} shm=${shm} mem_avail=${mem_avail}Mi (${why})"
  rbv_say "postgres: tuning $(printf '%s\n' "${RBV_PG_ARGS[@]}" | grep -E '^(shared_buffers|work_mem|maintenance_work_mem|max_wal_size)=' | tr '\n' ' ')(fsync=off — песочница одноразовая)"
  if (( mem_avail > 0 && mem_avail < 1500 )); then
    rbv_say "WARN: мало RAM (${mem_avail}Mi) — restore крупных dump может получить SIGKILL(137); нужен swap ≥2G"
  fi
  # `cmd || rc=$?` вместо set +e/set -e: иначе функция включает errexit обратно
  # и ломает вызывающего, который его специально выключил.
  local run_rc=0
  # БЕЗ -v: PGDATA в слое контейнера (на хост ничего не пишем).
  docker run -d --name "$PG_CID" --shm-size="$shm" \
    --label rbv.role=sandbox-pg \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    "postgres:${PG_VER}-alpine" "${RBV_PG_ARGS[@]}" \
    >"${RUN_DIR}/pg.run.out" 2>"${RUN_DIR}/pg.run.err" || run_rc=$?
  if [[ $run_rc -ne 0 ]]; then
    rbv_say "postgres: docker run rc=${run_rc}"
    tail -n 30 "${RUN_DIR}/pg.run.err" 2>/dev/null | while IFS= read -r _line; do rbv_say "  ${_line}"; done || true
    rbv_pg_diag "run-fail"
    return 1
  fi
  sleep 1
  if ! rbv_pg_alive; then
    rbv_say "postgres: контейнер сразу не Running"
    docker logs "$PG_CID" 2>&1 | tail -n 40 | while IFS= read -r _line; do rbv_say "  log: ${_line}"; done || true
    rbv_pg_diag "not-running"
    return 1
  fi

  rbv_say "postgres: жду pg_isready (до ${wait_s}с)…"
  local i ready=false
  for i in $(seq 1 "$wait_s"); do
    if docker exec "$PG_CID" pg_isready -U postgres >/dev/null 2>&1; then
      ready=true
      rbv_say "postgres: ready (${i}с)"
      break
    fi
    if ! rbv_pg_alive; then
      rbv_say "postgres: контейнер умер на ожидании ready (${i}с)"
      rbv_pg_diag "died-wait"
      return 1
    fi
    (( i % 15 == 0 )) && rbv_say "postgres: ещё не ready (${i}/${wait_s}с)…"
    sleep 1
  done
  [[ "$ready" == true ]] || { rbv_pg_diag "not-ready"; return 1; }

  local accept=false
  for i in $(seq 1 60); do
    if docker exec "$PG_CID" psql -U postgres -d postgres -Atc 'SELECT 1' >/dev/null 2>&1; then
      accept=true
      rbv_say "postgres: принимает запросы (${i}с)"
      break
    fi
    if ! rbv_pg_alive; then
      rbv_say "postgres: контейнер умер на SELECT 1"
      rbv_pg_diag "died-select"
      return 1
    fi
    sleep 1
  done
  [[ "$accept" == true ]] || { rbv_pg_diag "no-select"; return 1; }
  return 0
}

# Роли из дампа (OWNER TO / GRANT … TO / SET SESSION AUTHORIZATION).
# Без них psql сыплет `role "x" does not exist` на каждом ALTER … OWNER TO.
# Читаем только «голову» дампа: владельцы объектов там уже встречаются,
# а разжимать 1.5–2 GiB целиком ради этого незачем.
# $1 = путь к .sql.gz на хосте. stdout: имена ролей.
rbv_pg_roles_in_dump() {
  local sql="$1"
  [[ -f "$sql" ]] || return 0
  # head закрывает pipe → gzip получает SIGPIPE(141); под pipefail это rc≠0,
  # поэтому весь разбор — в subshell без pipefail (иначе ломаем вызывающего).
  (
    set +o pipefail
    gzip -dc "$sql" 2>/dev/null | head -n 80000 \
      | grep -E '^(ALTER|GRANT|REVOKE|CREATE SCHEMA|SET SESSION AUTHORIZATION)' \
      | grep -oE '(OWNER TO|AUTHORIZATION|TO)[[:space:]]+"?[A-Za-z_][A-Za-z0-9_$-]*"?[[:space:]]*;?$' \
      | awk '{print $NF}' \
      | tr -d '";' \
      | grep -vixE 'postgres|public|current_user|session_user|none|to|group' \
      | sort -u
  ) 2>/dev/null || true
  return 0
}

# Создать недостающие роли перед restore. rc=0 всегда.
rbv_pg_precreate_roles() {
  local sql="$1" role created=0 list=""
  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    docker exec "$PG_CID" psql -U postgres -d postgres -v ON_ERROR_STOP=0 -Atc \
      "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${role}') THEN CREATE ROLE \"${role}\" LOGIN SUPERUSER; END IF; END\$\$;" \
      >/dev/null 2>&1 || continue
    created=$((created + 1))
    list+="${role} "
  done < <(rbv_pg_roles_in_dump "$sql")
  if (( created > 0 )); then
    rbv_say "postgres: заранее созданы роли из дампа (${created}): ${list% }"
  fi
  return 0
}

# Один проход restore .sql.gz внутрь контейнера.
# Без host-pipe (`gzip | docker exec -i`) — docker cp + gzip|psql внутри.
# В psql.err пишется маркер RBV_PSQL_RC=<rc>: если его нет, restore оборвали
# (контейнер убит / exec потерян), и rc самого docker exec доверять нельзя —
# именно так «прерванный» прогон раньше рапортовал rc=0 с половиной таблиц.
# $1 = .sql.gz на хосте. rc = rc psql (или 1 при обрыве).
rbv_pg_restore_sql() {
  local sql="$1"
  local remote="/tmp/rbv_dump.sql.gz"
  local err="${RUN_DIR}/psql.err"
  : >"$err"
  RBV_PG_MARKER_SEEN=0
  [[ -n "${PG_CID:-}" && -f "$sql" ]] || return 1
  if ! docker cp "$sql" "${PG_CID}:${remote}" 2>>"$err"; then
    rbv_say "postgres: docker cp дампа не удался"
    return 1
  fi
  local exec_rc=0
  docker exec "$PG_CID" sh -c \
    "set -o pipefail 2>/dev/null; gzip -dc '${remote}' | psql -q -U postgres -d postgres -v ON_ERROR_STOP=0; rc=\$?; echo \"RBV_PSQL_RC=\${rc}\" >&2" \
    >/dev/null 2>>"$err" || exec_rc=$?
  docker exec "$PG_CID" rm -f "$remote" >/dev/null 2>&1 || true
  local marker
  marker="$(grep -oE '^RBV_PSQL_RC=[0-9]+$' "$err" 2>/dev/null | tail -n1 || true)"
  if [[ -n "$marker" ]]; then
    RBV_PG_MARKER_SEEN=1
    return "${marker#RBV_PSQL_RC=}"
  fi
  return "$exec_rc"
}

# Сводка по ERROR в psql.err: сколько и какие (топ-5 различных).
rbv_pg_error_summary() {
  local err="${RUN_DIR}/psql.err" n
  n="$(grep -cE '^(psql:)?.*\bERROR\b' "$err" 2>/dev/null || true)"
  n="$(echo "${n:-0}" | tr -d '[:space:]')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  RBV_RESTORE_ERRORS="$n"
  (( n > 0 )) || return 0
  rbv_say "psql restore: строк ERROR=${n} (полный лог: ${err})"
  grep -E '\bERROR\b' "$err" 2>/dev/null \
    | sed -E 's/.*ERROR: */ERROR: /; s/"[^"]*"/"…"/g' \
    | sort | uniq -c | sort -rn | head -n 5 \
    | while IFS= read -r _l; do rbv_say "  ${_l}"; done || true
  return 0
}

# Прогресс restore: суммарный размер всех БД кластера, а не только `postgres`.
# Дампы pg_dumpall создают свою БД и делают \connect — прогресс в `postgres`
# всё время показывал бы «0 таблиц».
rbv_pg_progress() {
  docker exec "$PG_CID" psql -U postgres -d postgres -Atc \
    "SELECT string_agg(datname||' '||pg_size_pretty(pg_database_size(datname)), ', ' ORDER BY pg_database_size(datname) DESC) FROM pg_database WHERE NOT datistemplate" \
    2>/dev/null | tr -d '\r' | head -n1 || true
}

# Полный restore с пересозданием песочницы при внешнем kill/OOM.
# $1 = .sql.gz, $2 = число попыток (по умолчанию 3).
# Выставляет RBV_RESTORE_{RC,CLASS,ERRORS,ATTEMPTS}. rc=0 если restore дошёл до конца.
rbv_pg_restore() {
  local sql="$1" attempts="${2:-3}"
  local a rc reason hb
  RBV_RESTORE_RC=1
  RBV_RESTORE_CLASS="dead"
  RBV_RESTORE_ERRORS=0
  RBV_RESTORE_ATTEMPTS=0

  for a in $(seq 1 "$attempts"); do
    RBV_RESTORE_ATTEMPTS="$a"
    if ! rbv_pg_alive; then
      rbv_say "psql restore: песочница не жива перед попыткой ${a}/${attempts} — пересоздаю"
      if ! rbv_pg_start "retry-${a}"; then
        RBV_RESTORE_CLASS="start_failed"
        RBV_RESTORE_RC=1
        return 1
      fi
    fi
    rbv_pg_precreate_roles "$sql"

    rbv_say "psql restore: $(basename "$sql") ($(du -h "$sql" 2>/dev/null | awk '{print $1}')) — попытка ${a}/${attempts}"
    (
      t=0
      while sleep 15; do
        t=$((t + 15))
        rbv_say "psql restore: идёт… ${t}с ($(rbv_pg_progress))"
      done
    ) &
    hb=$!
    RBV_HB_PID="$hb"
    rc=0
    rbv_pg_restore_sql "$sql" || rc=$?
    kill "$hb" 2>/dev/null || true
    wait "$hb" 2>/dev/null || true
    RBV_HB_PID=""
    RBV_RESTORE_RC="$rc"

    reason="$(rbv_pg_kill_reason)"
    if [[ "${RBV_PG_MARKER_SEEN:-0}" != "1" ]]; then
      # psql не досказал свой rc → restore оборвали
      case "$reason" in
        external)
          RBV_RESTORE_CLASS="external"
          rbv_say "psql restore: ОБОРВАН — песочницу удалили снаружи (попытка ${a}/${attempts})"
          ;;
        oom)
          RBV_RESTORE_CLASS="oom"
          rbv_say "psql restore: ОБОРВАН — OOMKilled (попытка ${a}/${attempts})"
          ;;
        alive)
          RBV_RESTORE_CLASS="psql_error"
          rbv_say "psql restore: exec оборван, но контейнер жив (rc=${rc}, попытка ${a}/${attempts})"
          ;;
        *)
          RBV_RESTORE_CLASS="dead"
          rbv_say "psql restore: ОБОРВАН — postgres упал (rc=${rc}, попытка ${a}/${attempts})"
          ;;
      esac
      rbv_pg_diag "restore-${a}"
      if (( a < attempts )); then
        rbv_ensure_disk_kb "${RBV_DISK_NEED_KB:-0}" "${RUN_DIR}" || true
        rbv_mem_reclaim >/dev/null 2>&1 || true
        rbv_say "psql restore: пересоздаю песочницу и повторяю…"
        rbv_pg_start "retry-${a}" || true
        continue
      fi
      return 1
    fi

    rbv_pg_error_summary
    if grep -qiE 'No space left|ENOSPC' "${RUN_DIR}/psql.err" 2>/dev/null; then
      RBV_RESTORE_CLASS="disk"
      rbv_say "psql restore: на диске нет места (ENOSPC)"
      return 1
    fi
    if (( rc == 0 )); then
      RBV_RESTORE_CLASS="ok"
      rbv_say "psql restore: завершён полностью (rc=0, ERROR=${RBV_RESTORE_ERRORS})"
      return 0
    fi
    RBV_RESTORE_CLASS="psql_error"
    rbv_say "psql restore: psql вернул rc=${rc} (ERROR=${RBV_RESTORE_ERRORS})"
    return 1
  done
  return 1
}
