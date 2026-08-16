#!/usr/bin/env bash
# Общие функции rw-backup-verify (source).
set -euo pipefail

[[ -n "${__RBV_LIB:-}" ]] && return 0
__RBV_LIB=1

RBV_INSTALL_DIR="${RBV_INSTALL_DIR:-/opt/rw-backup-verify}"
RBV_CONFIG="${RBV_CONFIG:-/etc/rw-backup-verify/config.json}"
# RBV_WORK_DIR / RBV_STATE_DIR — опциональные оверрайды (тесты/отладка).

msg() {
  local t="$1"; shift
  local c=""
  case "$t" in
    INFO) c=$'\e[36m' ;;
    OK)   c=$'\e[32m' ;;
    WARN) c=$'\e[33m' ;;
    ERR)  c=$'\e[31m' ;;
  esac
  printf '%s[%s]%s %s\n' "$c" "$t" $'\e[0m' "$*" >&2
  if [[ -n "${RBV_LOG:-}" ]]; then
    # без ANSI в файл
    printf '[%s] %s\n' "$t" "$*" >>"$RBV_LOG" 2>/dev/null || true
  fi
}

need() { command -v "$1" >/dev/null 2>&1 || { msg ERR "Нужен $1"; exit 1; }; }

rbv_load_config() {
  [[ -f "$RBV_CONFIG" ]] || { msg ERR "Нет конфига: $RBV_CONFIG"; exit 1; }
  need jq
}

rbv_cfg() { jq -r "$1" "$RBV_CONFIG"; }

rbv_work_dir() {
  local d
  if [[ -n "${RBV_WORK_DIR:-}" ]]; then
    d="$RBV_WORK_DIR"
  elif [[ -n "${RBV_STATE_DIR:-}" ]]; then
    d="$RBV_STATE_DIR"
  else
    d="$(rbv_cfg '.work_dir // "/var/lib/rw-backup-verify"')"
  fi
  mkdir -p "$d"/{queue,runs,logs,locks,locks/active,cache,tested,cache/archives}
  printf '%s\n' "$d"
}

# Вывод шага: rbv-run-one подменяет на `rep` (report.txt + stderr).
rbv_say() { msg INFO "$*"; }

# --- Глобальный лок: один прогон на хост ------------------------------------
# Таймер тикает раз в минуту; без общего лока `tick → run --due` стартовал
# параллельно ручному прогону, а `run` начинается и заканчивается
# rbv_docker_reclaim → `docker rm -f rbv_pg_*`. Живой restore получал SIGKILL:
# в логе это выглядело как «OOM rc=137», хотя OOMKilled=false, а
# State.Status=removing (подпись внешнего docker rm -f).
# fd 8 наследуется детьми (worker / rbv-run-one) — лок держится весь прогон.
RBV_LOCK_FD=8

rbv_global_lock_file() { printf '%s/locks/global.lock\n' "$(rbv_work_dir)"; }

# $1 = сколько секунд ждать (0/пусто — не ждать). rc=0 взяли, rc=1 занято.
rbv_global_lock() {
  local wait_s="${1:-0}" lock
  # лок уже взят родителем (worker/run-one наследуют fd и переменную)
  [[ "${RBV_GLOBAL_LOCK_HELD:-0}" == "1" ]] && return 0
  need flock
  lock="$(rbv_global_lock_file)"
  eval "exec ${RBV_LOCK_FD}>\"\$lock\"" || return 1
  if [[ "$wait_s" =~ ^[1-9][0-9]*$ ]]; then
    flock -w "$wait_s" "$RBV_LOCK_FD" || return 1
  else
    flock -n "$RBV_LOCK_FD" || return 1
  fi
  RBV_GLOBAL_LOCK_HELD=1
  export RBV_GLOBAL_LOCK_HELD
  printf '%s %s\n' "$$" "${RBV_LOCK_TAG:-?}" >"$(rbv_work_dir)/locks/global.owner" 2>/dev/null || true
  return 0
}

# Кто держит лок (для понятного сообщения вместо тихого выхода).
rbv_global_lock_owner() {
  local f
  f="$(rbv_work_dir)/locks/global.owner"
  [[ -f "$f" ]] && head -n1 "$f" 2>/dev/null || true
}

# --- Реестр активных прогонов ----------------------------------------------
# Второй рубеж на случай ручного `reclaim`/`runs prune` в соседнем терминале:
# чужой процесс не должен трогать контейнеры, compose-проекты и runs/<id>
# живого прогона, даже если лок кто-то обошёл.

rbv_active_dir() { printf '%s/locks/active\n' "$(rbv_work_dir)"; }

# $1=run_dir $2=pg_cid $3=compose_project
rbv_active_register() {
  local d f
  d="$(rbv_active_dir)"
  mkdir -p "$d"
  f="${d}/$$.json"
  jq -nc --argjson pid "$$" --arg run "${1:-}" --arg pg "${2:-}" \
    --arg proj "${3:-}" --argjson ts "$(date +%s)" \
    '{pid:$pid, run_dir:$run, pg_cid:$pg, compose_project:$proj, started:$ts}' \
    >"$f" 2>/dev/null || true
  RBV_ACTIVE_FILE="$f"
}

rbv_active_unregister() {
  [[ -n "${RBV_ACTIVE_FILE:-}" ]] && rm -f "$RBV_ACTIVE_FILE" 2>/dev/null || true
  RBV_ACTIVE_FILE=""
  return 0
}

# Записи живых прогонов (файлы мёртвых pid удаляем). stdout: json по строке.
rbv_active_entries() {
  local d f pid
  d="$(rbv_active_dir)"
  [[ -d "$d" ]] || return 0
  for f in "$d"/*.json; do
    [[ -f "$f" ]] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    # свой же прогон не защищаем от самого себя
    [[ "$pid" == "$$" ]] && continue
    cat "$f"
  done
  return 0
}

# $1 = поле (run_dir|pg_cid|compose_project); stdout: значения живых прогонов.
rbv_active_field() {
  local k="$1"
  rbv_active_entries | jq -r --arg k "$k" '.[$k] // empty' 2>/dev/null || true
  return 0
}

# rbv_is_protected <значение> <поле> → rc=0 если принадлежит живому прогону.
rbv_is_protected() {
  local v="${1:-}" k="${2:-}" x
  [[ -n "$v" && -n "$k" ]] || return 1
  while IFS= read -r x; do
    [[ -n "$x" ]] || continue
    [[ "${v%/}" == "${x%/}" ]] && return 0
  done < <(rbv_active_field "$k")
  return 1
}

# --- Archive cache / disk ---------------------------------------------------

# Стабильный id ключа S3 → имя файла в cache/archives/<sid>/<id>.tar.gz
rbv_cache_key_id() {
  printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$1" | md5sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$1" | cksum | awk '{print $1}'
}

rbv_archive_cache_path() {
  local sid="$1" key="$2" wd id
  wd="$(rbv_work_dir)"
  id="$(rbv_cache_key_id "$key")"
  mkdir -p "${wd}/cache/archives/${sid}"
  printf '%s/cache/archives/%s/%s.tar.gz\n' "$wd" "$sid" "$id"
}

rbv_disk_avail_kb() {
  local p="${1:-/}"
  df -Pk "$p" 2>/dev/null | awk 'NR==2{print $4}'
}

# Скопировать/hardlink найденные archive.tar.gz из runs/ в cache (по key= в report.txt).
# Возвращает путь кэша если удалось обеспечить файл для $key; иначе пусто.
rbv_cache_ensure() {
  local sid="$1" key="$2"
  local dest wd d arch line
  dest="$(rbv_archive_cache_path "$sid" "$key")"
  if [[ -s "$dest" ]]; then
    printf '%s\n' "$dest"
    return 0
  fi
  wd="$(rbv_work_dir)"
  # 1) runs с тем же key в report
  for d in "$wd"/runs/*/; do
    [[ -d "$d" ]] || continue
    arch="${d}archive.tar.gz"
    [[ -s "$arch" ]] || continue
    if [[ -f "${d}report.txt" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          "key=${key} "*|"key=${key}")
            ln -f "$arch" "$dest" 2>/dev/null || cp -f "$arch" "$dest"
            if [[ -s "$dest" ]]; then
              printf '%s\n' "$key" >"${dest}.key"
              printf '%s\n' "$dest"
              return 0
            fi
            ;;
        esac
      done <"${d}report.txt"
    fi
  done
  # 2) fallback: единственный archive с тем же basename в runs
  local bn hits=0 hit=""
  bn="$(basename "$key")"
  bn="${bn%.age}"
  for d in "$wd"/runs/*/; do
    arch="${d}archive.tar.gz"
    [[ -s "$arch" ]] || continue
    # грубая эвристика: report содержит basename
    if [[ -f "${d}report.txt" ]] && grep -Fq "$bn" "${d}report.txt" 2>/dev/null; then
      hits=$((hits + 1))
      hit="$arch"
    fi
  done
  if [[ "$hits" -eq 1 && -n "$hit" ]]; then
    ln -f "$hit" "$dest" 2>/dev/null || cp -f "$hit" "$dest"
    if [[ -s "$dest" ]]; then
      printf '%s\n' "$key" >"${dest}.key"
      printf '%s\n' "$dest"
      return 0
    fi
  fi
  return 1
}

# Epoch из имени архива (для сортировки cache); 0 если не разобрали.
rbv_cache_name_epoch() {
  local name="$1" y m d H M S
  if [[ "$name" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})_([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    H="${BASH_REMATCH[4]}"; M="${BASH_REMATCH[5]}"; S="${BASH_REMATCH[6]}"
    date -u -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null && return 0
  fi
  if [[ "$name" =~ _([0-9]{8})_([0-9]{6})\.tar\.gz ]]; then
    local ds="${BASH_REMATCH[1]}" ts="${BASH_REMATCH[2]}"
    y="${ds:0:4}"; m="${ds:4:2}"; d="${ds:6:2}"
    H="${ts:0:2}"; M="${ts:2:2}"; S="${ts:4:2}"
    date -u -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null && return 0
  fi
  echo 0
}

# В cache оставить только последний архив на экземпляр (dirname S3 key).
# $1 = optional storage-id (пусто = все). stdout: сколько файлов удалено.
rbv_cache_prune_latest() {
  local only_sid="${1:-}"
  local wd cdir sid dir f key parent ep best_ep best_f n=0
  local -A best_path best_epoch
  wd="$(rbv_work_dir)"
  cdir="${wd}/cache/archives"
  [[ -d "$cdir" ]] || { echo 0; return 0; }

  # collect: group = sid|parent → best file
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    sid="$(basename "$(dirname "$f")")"
    [[ -n "$only_sid" && "$sid" != "$only_sid" ]] && continue
    key=""
    [[ -f "${f}.key" ]] && key="$(head -n1 "${f}.key" 2>/dev/null || true)"
    [[ -n "$key" ]] || key="$(basename "$f")"
    parent="$(dirname "$key")"
    [[ "$parent" == "." ]] && parent="$key"
    ep="$(rbv_cache_name_epoch "$(basename "$key")")"
    [[ "$ep" =~ ^[0-9]+$ ]] || ep=0
    if (( ep == 0 )); then
      ep="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    fi
    local g="${sid}|${parent}"
    if [[ -z "${best_epoch[$g]:-}" ]] || (( ep > best_epoch[$g] )); then
      best_epoch[$g]="$ep"
      best_path[$g]="$f"
    fi
  done < <(find "$cdir" -type f -name '*.tar.gz' 2>/dev/null || true)

  # delete non-best
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    sid="$(basename "$(dirname "$f")")"
    [[ -n "$only_sid" && "$sid" != "$only_sid" ]] && continue
    key=""
    [[ -f "${f}.key" ]] && key="$(head -n1 "${f}.key" 2>/dev/null || true)"
    [[ -n "$key" ]] || key="$(basename "$f")"
    parent="$(dirname "$key")"
    [[ "$parent" == "." ]] && parent="$key"
    local g="${sid}|${parent}"
    if [[ -n "${best_path[$g]:-}" && "$f" != "${best_path[$g]}" ]]; then
      rm -f "$f" "${f}.key" 2>/dev/null || true
      n=$((n + 1))
    fi
  done < <(find "$cdir" -type f -name '*.tar.gz' 2>/dev/null || true)

  # orphan .key
  while IFS= read -r f; do
    [[ -f "${f%.key}" ]] || { rm -f "$f" 2>/dev/null || true; }
  done < <(find "$cdir" -type f -name '*.tar.gz.key' 2>/dev/null || true)

  echo "$n"
}

# Перед удалением runs — перенести все архивы в cache (hardlink).
rbv_cache_adopt_all_runs() {
  local wd d arch line key sid dest
  wd="$(rbv_work_dir)"
  for d in "$wd"/runs/*/; do
    [[ -d "$d" ]] || continue
    arch="${d}archive.tar.gz"
    [[ -s "$arch" ]] || continue
    key=""
    if [[ -f "${d}report.txt" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          key=*)
            key="${line#key=}"
            key="${key%% *}"
            break
            ;;
        esac
      done <"${d}report.txt"
    fi
    [[ -n "$key" ]] || continue
    # sid из имени run или storage= в report
    sid=""
    if [[ -f "${d}report.txt" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          storage=*)
            sid="${line#storage=}"
            sid="${sid%% *}"
            break
            ;;
        esac
      done <"${d}report.txt"
    fi
    [[ -n "$sid" ]] || sid="_unknown"
    dest="$(rbv_archive_cache_path "$sid" "$key")"
    if [[ ! -s "$dest" ]]; then
      ln -f "$arch" "$dest" 2>/dev/null || cp -f "$arch" "$dest" 2>/dev/null || true
      [[ -s "$dest" ]] && printf '%s\n' "$key" >"${dest}.key"
    fi
  done
}

# Удалить старые runs/, оставив N новейших. Сначала adopt архивов в cache.
# $1=keep $2=optional protect dir (никогда не удалять).
# stdout: сколько удалено.
rbv_runs_prune() {
  local keep="${1:-2}"
  local protect="${2:-${RBV_PROTECT_RUN:-}}"
  local wd runs_dir n=0 i=0 d
  wd="$(rbv_work_dir)"
  runs_dir="${wd}/runs"
  [[ -d "$runs_dir" ]] || { echo 0; return 0; }
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=2
  protect="${protect%/}"
  rbv_cache_adopt_all_runs
  i=0
  n=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    d="${d%/}"
    if [[ -n "$protect" && "$d" == "$protect" ]]; then
      i=$((i + 1))
      continue
    fi
    # каталог живого прогона (другой процесс) — не трогать даже при keep=0
    if rbv_is_protected "$d" run_dir; then
      i=$((i + 1))
      continue
    fi
    i=$((i + 1))
    if (( i > keep )); then
      rm -rf "$d"
      n=$((n + 1))
    fi
  done < <(ls -1dt "$runs_dir"/*/ 2>/dev/null || true)
  echo "$n"
}

rbv_disk_report() {
  local p="${1:-$(rbv_work_dir)}"
  df -h "$p" 2>/dev/null | tail -n1 || true
}

# Удалить тяжёлые артефакты прогона (дамп/extract), оставить report/compose/checks.
# Архив в cache/ не трогаем (hardlink).
rbv_run_slim() {
  local d="${1:?}"
  [[ -d "$d" ]] || return 0
  # чужой живой прогон: его dump/extract ещё нужны для restore
  rbv_is_protected "$d" run_dir && return 0
  rm -rf "${d}/extract" "${d}/project_extract" "${d}/project" 2>/dev/null || true
  rm -f "${d}/archive.tar.gz" 2>/dev/null || true
  find "$d" -maxdepth 3 -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.rdb' -o -name '*.tar' \) \
    ! -name 'compose.*' -delete 2>/dev/null || true
}

# Slim всех runs кроме protect (текущий RUN_DIR).
rbv_slim_old_runs() {
  local protect="${1:-}"
  local wd d
  wd="$(rbv_work_dir)"
  for d in "$wd"/runs/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    if [[ -n "$protect" ]]; then
      [[ "$d" == "$protect" ]] && continue
    fi
    rbv_run_slim "$d"
  done
}

# Освободить RAM после тестов: контейнеры уже сняты; сбросить page cache
# (чтение dump 200–500M оставляет данные в buff/cache — free «avail» падает,
# хотя процессов rbv нет). stdout: краткий статус; rc=0.
rbv_mem_reclaim() {
  sync 2>/dev/null || true
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    # 1=pagecache 2=dentries/inodes 3=оба
    echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
  fi
  if command -v free >/dev/null 2>&1; then
    free -m | awk '/Mem:/{printf "mem reclaim: avail=%sMi total=%sMi buff/cache=%sMi\n", $7, $2, $6}'
  else
    echo "mem reclaim: ok"
  fi
  return 0
}

# Убрать leftover Docker от verify после тестов.
# Политика: контейнеры/сети/volumes удаляем; ОБРАЗЫ оставляем (pull при смене тега).
# PG sandbox без -v → PGDATA в слое контейнера; compose anonymous volumes — через down -v + prune.
# stdout: число снятых контейнеров/проектов; rc=0.
rbv_docker_reclaim() {
  local n=0 name proj net
  # ВАЖНО: контейнеры/сети/проекты живого прогона не трогаем. Раньше здесь был
  # безусловный `docker rm -f` по маске rbv_pg_* — параллельный tick сносил
  # песочницу работающего restore (exit=137, oom=false, status=removing).
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if rbv_is_protected "$name" pg_cid; then
      msg INFO "reclaim: пропуск ${name} — занят живым прогоном"
      continue
    fi
    docker rm -f "$name" >/dev/null 2>&1 && n=$((n + 1)) || true
  done < <(docker ps -a --filter 'name=rbv_pg_' --filter 'name=rbv_probe_' \
    --filter 'name=rbv_iso_' --filter 'name=rbv_preflight_' \
    --format '{{.Names}}' 2>/dev/null || true)
  while IFS= read -r proj; do
    [[ -n "$proj" ]] || continue
    if rbv_is_protected "$proj" compose_project; then
      msg INFO "reclaim: пропуск compose ${proj} — занят живым прогоном"
      continue
    fi
    docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
    n=$((n + 1))
  done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
    | grep -E '^rbv' | sort -u | grep -v '^$' || true)
  while IFS= read -r net; do
    [[ -n "$net" ]] || continue
    rbv_is_protected "${net%_net}" compose_project && continue
    docker network rm "$net" >/dev/null 2>&1 || true
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^rbv|_net$' || true)
  # dangling volumes (после down -v / rm контейнеров) — главный потребитель диска
  docker volume prune -f >/dev/null 2>&1 || true
  # container prune снёс бы упавшие контейнеры чужого стека до сбора логов
  if [[ -z "$(rbv_active_entries)" ]]; then
    docker container prune -f >/dev/null 2>&1 || true
  fi
  echo "$n"
  return 0
}

# Минимум свободно под restore (KiB). 1.5 GiB — на хостах ~50G с кэшем/Docker
# жёсткие 3 GiB часто блокировали прогон при живом 4×sql.gz.
rbv_disk_floor_kb() {
  echo 1572864
}

# Жёсткий порог (блокирует прогон): max(4×size, floor). stdout KiB.
rbv_disk_need_for_sql() {
  local sql_b="${1:-0}" floor need
  floor="$(rbv_disk_floor_kb)"
  need="$floor"
  if [[ "$sql_b" =~ ^[0-9]+$ ]] && (( sql_b > 0 )); then
    need=$(( sql_b * 4 / 1024 ))
    (( need < floor )) && need=$floor
  fi
  echo "$need"
}

# Реалистичная оценка «сколько съест restore» (KiB): распакованный SQL ≈ 7×gz,
# плюс данные+индексы в PGDATA и WAL, плюс сам gz внутри контейнера.
# Меньше этого прогон обычно доходит до ENOSPC уже на индексах — предупреждаем,
# но НЕ блокируем (блокирует только rbv_disk_need_for_sql).
rbv_disk_estimate_for_sql() {
  local sql_b="${1:-0}"
  if [[ "$sql_b" =~ ^[0-9]+$ ]] && (( sql_b > 0 )); then
    echo $(( sql_b * 15 / 1024 ))
  else
    rbv_disk_floor_kb
  fi
}

# Нужно ≥ need_kb свободно под restore. При нехватке — slim + prune(+cache).
# $1=need_kb $2=protect_run_dir
# rc=0 если после попыток хватает (или need неизвестен); rc=1 если всё ещё мало.
rbv_ensure_disk_kb() {
  local need="${1:-}" protect="${2:-}"
  local wd avail floor
  wd="$(rbv_work_dir)"
  floor="$(rbv_disk_floor_kb)"
  [[ "$need" =~ ^[0-9]+$ ]] || need="$floor"
  avail="$(rbv_disk_avail_kb "$wd")"
  [[ "$avail" =~ ^[0-9]+$ ]] || return 0
  if (( avail >= need )); then
    return 0
  fi
  msg WARN "disk: свободно ${avail} KiB < нужно ${need} KiB — slim/prune"
  rbv_slim_old_runs "$protect"
  # только текущий run (protect через RBV_PROTECT_RUN / $2)
  rbv_runs_prune 0 "$protect" >/dev/null || true
  if [[ "${RBV_CACHE_LATEST:-true}" == true ]]; then
    rbv_cache_prune_latest "" >/dev/null || true
  fi
  avail="$(rbv_disk_avail_kb "$wd")"
  [[ "$avail" =~ ^[0-9]+$ ]] || return 0
  if (( avail >= need )); then
    return 0
  fi
  return 1
}

# Собрать env для `docker compose config`: .env + значения из дерева проекта
# + заглушки для ${VAR:?required}, иначе swarm/bot compose падает на BACKEND_IMAGE.
# $1=project_dir $2=compose_file $3=out_env_file
# stdout: stub-переменные через пробел; rc=0.
rbv_compose_prepare_env() {
  local proj="$1" cf="$2" out="$3"
  local stubs=() var val found line
  : >"$out"
  if [[ -f "${proj}/.env" ]]; then
    cat "${proj}/.env" >>"$out"
    printf '\n' >>"$out"
  fi

  _rbv_env_has() {
    local k="$1" v
    v="$(grep -E "^[[:space:]]*${k}=" "$out" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [[ -n "$v" && "$v" != *'${'* ]]
  }

  _rbv_env_set() {
    printf '%s=%s\n' "$1" "$2" >>"$out"
  }

  # кандидаты: обязательные ${VAR:?…} и IMAGE/TAG из compose
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    _rbv_env_has "$var" && continue

    found=""
    while IFS= read -r line; do
      [[ "$line" == *=* ]] || continue
      val="${line#*=}"
      val="${val%\"}"; val="${val#\"}"
      val="${val%\'}"; val="${val#\'}"
      [[ -z "$val" || "$val" == *'${'* || "$val" == *':?'* ]] && continue
      found="$val"
      break
    done < <(grep -RhoE "^[[:space:]]*${var}=[^[:space:]#]+" "$proj" 2>/dev/null | head -n 20 || true)

    if [[ -n "$found" ]]; then
      _rbv_env_set "$var" "$found"
      continue
    fi

    case "$var" in
      *_TAG|TAG|VERSION) val="latest" ;;
      *_IMAGE|*_REPO|IMAGE)
        val="rbv-missing/$(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-')"
        ;;
      *) val="rbv-missing" ;;
    esac
    _rbv_env_set "$var" "$val"
    stubs+=("$var")
  done < <(
    {
      grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\?[^}]*\}' "$cf" 2>/dev/null || true
      grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}' "$cf" 2>/dev/null || true
      grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$cf" 2>/dev/null || true
    } | sed -E 's/^\$\{([A-Za-z0-9_]+).*/\1/' | sort -u \
      | grep -E '(_IMAGE|_TAG|_REPO|^BACKEND|^CABINET|^APP_|_VERSION$)' || true
  )

  printf '%s\n' "${stubs[*]}"
}

# Маскировка секретов в yaml/env тексте (stdin→stdout).
rbv_mask_secrets() {
  sed -E \
    -e 's#(://[^:/@"'"'"']+:)[^@/]+@#\1***@#g' \
    -e 's#((PASSWORD|SECRET|TOKEN|KEY|PASS|PRIVATE)[_A-Z0-9]*[[:space:]]*[=:][[:space:]]*["_]?)[^[:space:]#"'"'"']{6,}#\1***#gI' \
    -e 's#((PASSWORD|SECRET|TOKEN|KEY|PASS)[_A-Z0-9]*[[:space:]]*:[[:space:]]*)[^[:space:]#"'"'"']+#\1***#gI'
}

# --- Telegram ---------------------------------------------------------------

rbv_tg_send() {
  local token="$1" chat="$2" text="$3" thread="${4:-}"
  if [[ -z "$token" || -z "$chat" ]]; then
    msg WARN "Telegram: token/chat_id пусты — сообщение не отправлено (rw-backup-verify telegram set …)"
    return 0
  fi
  need curl
  need jq
  local -a form=(-F "chat_id=${chat}" -F "text=${text}" -F "parse_mode=HTML")
  [[ -n "$thread" ]] && form+=(-F "message_thread_id=${thread}")
  local a resp ok
  for a in 1 2 3; do
    resp=""
    resp="$(curl -sS -m 25 "https://api.telegram.org/bot${token}/sendMessage" "${form[@]}" 2>/dev/null)" || true
    ok="$(jq -r '.ok // false' <<<"$resp" 2>/dev/null || echo false)"
    if [[ "$ok" == "true" ]]; then
      return 0
    fi
    msg WARN "Telegram API попытка ${a}/3: $(jq -c '{ok,error_code,description}' <<<"$resp" 2>/dev/null || printf '%s' "${resp:0:200}")"
    sleep $((a * 2))
  done
  msg WARN "Telegram: не удалось отправить"
  return 0
}

rbv_tg_for_storage() {
  local sid="$1"
  local tok chat thr
  # Важно: // empty в jq даёт НОЛЬ значений → ветка as $t|… не выполняется,
  # глобальный .telegram молча теряется. Всегда // "".
  tok="$(jq -r --arg id "$sid" '
    (([.storages[] | select(.id==$id) | .telegram.token // ""][0]) // "") as $t
    | if ($t|length)>0 then $t else (.telegram.token // "") end
  ' "$RBV_CONFIG")"
  chat="$(jq -r --arg id "$sid" '
    (([.storages[] | select(.id==$id) | .telegram.chat_id // ""][0]) // "") as $c
    | if ($c|length)>0 then $c else (.telegram.chat_id // "") end
  ' "$RBV_CONFIG")"
  thr="$(jq -r --arg id "$sid" '
    (([.storages[] | select(.id==$id) | .telegram.thread_id // ""][0]) // "") as $h
    | if ($h|length)>0 then $h else (.telegram.thread_id // "") end
  ' "$RBV_CONFIG")"
  printf '%s|%s|%s\n' "$tok" "$chat" "$thr"
}

# --- S3 helpers -------------------------------------------------------------

rbv_storage_json() {
  local sid="$1" j
  # jq select по пустому совпадению даёт exit 0 и пустой stdout — проверяем явно.
  j="$(jq -c --arg id "$sid" '.storages[] | select(.id==$id)' "$RBV_CONFIG" 2>/dev/null || true)"
  if [[ -z "$j" ]]; then
    msg ERR "Хранилище не найдено: $sid"
    exit 1
  fi
  printf '%s\n' "$j"
}

rbv_aws_env() {
  local j="$1"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_EC2_METADATA_DISABLED
  AWS_ACCESS_KEY_ID="$(jq -r '.access_key' <<<"$j")"
  AWS_SECRET_ACCESS_KEY="$(jq -r '.secret_key' <<<"$j")"
  AWS_DEFAULT_REGION="$(jq -r '.region // "us-east-1"' <<<"$j")"
  AWS_EC2_METADATA_DISABLED=true
  local ep
  ep="$(jq -r '.endpoint // empty' <<<"$j")"
  RBV_AWS_ENDPOINT=()
  [[ -n "$ep" ]] && RBV_AWS_ENDPOINT=(--endpoint-url "$ep")
  RBV_BUCKET="$(jq -r '.bucket' <<<"$j")"
  RBV_PREFIX="$(jq -r '.prefix // ""' <<<"$j" | sed 's:/*$::')"
}

rbv_aws() {
  need aws
  aws "${RBV_AWS_ENDPOINT[@]}" "$@"
}

# Классификация имени файла → kind|family
# kind: panel|bot
# family: remnawave_backup | custom_bot_<ProjectSafe>
# (family = экземпляр внутри одной папки; у ботов проект в имени файла)
rbv_classify_name() {
  local name="$1"
  if [[ "$name" =~ ^remnawave_backup_.*\.tar\.gz(\.age)?$ ]]; then
    printf 'panel|remnawave_backup\n'
    return 0
  fi
  if [[ "$name" =~ ^custom_bot_(.+)_([0-9]{8}_[0-9]{6})\.tar\.gz(\.age)?$ ]]; then
    local fam="${BASH_REMATCH[1]}"
    # custom_bot_foo__20260810_… → fam=foo_ → убрать хвостовые _
    fam="$(sed -E 's/_+$//' <<<"$fam")"
    printf 'bot|custom_bot_%s\n' "$fam"
    return 0
  fi
  # fallback: custom_bot_X_... без строгого TS
  if [[ "$name" =~ ^custom_bot_(.+)\.tar\.gz(\.age)?$ ]]; then
    local stem="${BASH_REMATCH[1]}"
    # убрать хвостовой _YYYYMMDD_HHMMSS если есть
    stem="$(sed -E 's/_[0-9]{8}_[0-9]{6}$//' <<<"$stem")"
    stem="$(sed -E 's/_+$//' <<<"$stem")"
    printf 'bot|custom_bot_%s\n' "$stem"
    return 0
  fi
  return 1
}

# Рекурсивный листинг архивов под prefix.
# stdout lines: relative_key (от корня bucket, без s3://)
# Учитывает и корень prefix, и любую вложенность.
# Ошибки aws НЕ глотаем — иначе run выглядит как «ничего не произошло».
rbv_list_all_archive_keys() {
  local base="${RBV_PREFIX}"
  local uri="s3://${RBV_BUCKET}/"
  [[ -n "$base" ]] && uri="s3://${RBV_BUCKET}/${base}/"
  local err out rc
  err="$(mktemp)"; out="$(mktemp)"
  # `|| rc=$?`, а не set +e/set -e: функция не должна включать errexit
  # обратно вызывающему, который его выключил
  rc=0
  rbv_aws s3 ls "$uri" --recursive >"$out" 2>"$err" || rc=$?
  if (( rc != 0 )); then
    msg ERR "S3 ls ${uri} rc=${rc}: $(tr '\n' ' ' <"$err" | head -c 400)"
    rm -f "$err" "$out"
    return 1
  fi
  local n
  n="$(wc -l <"$out" | tr -d ' ')"
  msg INFO "S3 ls ${uri} — объектов: ${n}"
  awk '{print $4}' "$out" \
    | grep -E '(^|/)(remnawave_backup_|custom_bot_)[^/]*\.tar\.gz(\.age)?$' \
    || true
  rm -f "$err" "$out"
}

# Discover: для каждого экземпляра (папка + family) — latest архив.
# stdout: kind|instance_id|s3_key|parent_dir
# instance_id стабилен: "<kind>:<parent_dir>:<family>"
# untested_only=true: пропустить уже протестированные ключи
rbv_discover() {
  local sid="$1"
  local untested_only="${2:-false}"
  local j key name parent kind family inst
  j="$(rbv_storage_json "$sid")"
  rbv_aws_env "$j"

  local tmp keys_file
  tmp="$(mktemp)"
  keys_file="$(mktemp)"
  if ! rbv_list_all_archive_keys >"$keys_file"; then
    rm -f "$tmp" "$keys_file"
    return 1
  fi

  local arch_n=0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    arch_n=$((arch_n + 1))
    name="$(basename "$key")"
    parent="$(dirname "$key")"
    [[ "$parent" == "." ]] && parent=""
    kind=""; family=""
    IFS='|' read -r kind family < <(rbv_classify_name "$name" || true)
    [[ -n "$kind" ]] || continue
    # sortkey = имя файла (TS в имени → лексикографический latest корректен)
    printf '%s\t%s\t%s\t%s\t%s\n' "${parent}|${family}" "$name" "$key" "$parent" "$kind" >> "$tmp"
  done <"$keys_file"
  rm -f "$keys_file"

  if [[ ! -s "$tmp" ]]; then
    msg WARN "Discover ${sid}: архивов panel/bot не найдено (ключей по маске=${arch_n})"
    rm -f "$tmp"
    return 0
  fi

  local latest_file
  latest_file="$(mktemp)"
  sort -t$'\t' -k1,1 -k2,2 "$tmp" \
    | awk -F'\t' '
      {
        g=$1
        if (g != prev) {
          if (prev != "") print last
          prev=g
        }
        last=$0
      }
      END { if (prev != "") print last }
    ' >"$latest_file"
  rm -f "$tmp"

  local out_n=0 skip_n=0
  while IFS=$'\t' read -r _grp name key parent kind; do
    [[ -n "${key:-}" ]] || continue
    family="$(rbv_classify_name "$name" | cut -d'|' -f2)"
    inst="${kind}:${parent}:${family}"
    if [[ "$untested_only" == "true" ]] && rbv_is_tested "$sid" "$key"; then
      skip_n=$((skip_n + 1))
      msg INFO "skip tested: ${key}"
      continue
    fi
    out_n=$((out_n + 1))
    printf '%s|%s|%s|%s\n' "$kind" "$inst" "$key" "$parent"
  done <"$latest_file"
  rm -f "$latest_file"

  msg INFO "Discover ${sid}: latest=${out_n} skip_tested=${skip_n} (untested_only=${untested_only})"
}

# --- Tested registry --------------------------------------------------------

rbv_tested_file() {
  printf '%s/tested/%s.json\n' "$(rbv_work_dir)" "$1"
}

rbv_is_tested() {
  local sid="$1" key="$2"
  local f
  f="$(rbv_tested_file "$sid")"
  [[ -f "$f" ]] || return 1
  jq -e --arg k "$key" '.[$k] != null' "$f" >/dev/null 2>&1
}

rbv_mark_tested() {
  local sid="$1" key="$2" ok="$3" run_id="${4:-}"
  local f tmp
  f="$(rbv_tested_file "$sid")"
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || echo '{}' > "$f"
  tmp="$(mktemp)"
  jq --arg k "$key" --argjson ok "$ok" --arg r "$run_id" --argjson ts "$(date +%s)" \
    '.[$k] = {ok:$ok, tested_at:$ts, run_id:$r}' "$f" > "$tmp"
  mv -f "$tmp" "$f"
}

# --- Global schedule --------------------------------------------------------

# Глобальная частота (не per-storage):
#   verify.interval_hours  ИЛИ  verify.times ["HH:MM",...]
# fallback: interval_hours=12
rbv_global_due() {
  local now_epoch now_hm last interval times t
  now_epoch="$(date +%s)"
  now_hm="$(date +%H:%M)"
  local marker
  marker="$(rbv_work_dir)/locks/last_run_global"
  last=0
  [[ -f "$marker" ]] && last="$(cat "$marker" 2>/dev/null || echo 0)"

  interval="$(rbv_cfg '.verify.interval_hours // empty')"
  if [[ -n "$interval" && "$interval" != "null" && "$interval" != "" ]]; then
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || {
      msg ERR "verify.interval_hours должно быть целым > 0 (сейчас: ${interval})"
      return 1
    }
    local need=$(( interval * 3600 ))
    (( now_epoch - last >= need )) && return 0
    return 1
  fi

  times="$(jq -r '.verify.times // [] | .[]' "$RBV_CONFIG" 2>/dev/null || true)"
  if [[ -z "$times" ]]; then
    # дефолт: каждые 12ч
    (( now_epoch - last >= 43200 )) && return 0
    return 1
  fi
  while IFS= read -r t; do
    [[ "$t" == "$now_hm" ]] || continue
    local stamp done_m
    stamp="$(date +%Y%m%d%H%M)"
    done_m="$(rbv_work_dir)/locks/due_global_${stamp}"
    [[ -f "$done_m" ]] && return 1
    return 0
  done <<<"$times"
  return 1
}

rbv_mark_global_done() {
  local stamp
  stamp="$(date +%Y%m%d%H%M)"
  date +%s > "$(rbv_work_dir)/locks/last_run_global"
  : > "$(rbv_work_dir)/locks/due_global_${stamp}"
}

rbv_queue_dir() { printf '%s/queue\n' "$(rbv_work_dir)"; }

# Job = один экземпляр (архив) для теста. FIFO по timestamp в имени файла.
rbv_enqueue_instance() {
  local sid="$1" kind="$2" inst="$3" key="$4" parent="$5" reason="${6:-manual}"
  local qd ts f safe old
  qd="$(rbv_queue_dir)"
  mkdir -p "$qd"
  # тот же архив уже в очереди (например, хвост прерванного прогона) —
  # второй раз его гонять незачем
  for old in "$qd"/*.job; do
    [[ -f "$old" ]] || continue
    if jq -e --arg s "$sid" --arg k "$key" \
         '.storage == $s and .key == $k' "$old" >/dev/null 2>&1; then
      msg INFO "уже в очереди, пропуск: ${sid} ${key}"
      return 0
    fi
  done
  ts="$(date +%s%N)"
  safe="$(printf '%s' "$inst" | tr '/:' '__')"
  f="${qd}/${ts}_${sid}_${safe}.job"
  jq -nc \
    --arg sid "$sid" --arg kind "$kind" --arg inst "$inst" \
    --arg key "$key" --arg parent "$parent" --arg reason "$reason" \
    --argjson enq "$(date +%s)" \
    '{storage:$sid,kind:$kind,instance:$inst,key:$key,parent:$parent,reason:$reason,enqueued_at:$enq}' \
    > "$f"
  msg INFO "В очередь: ${sid} ${kind} ${inst} → $(basename "$f")"
}

# Обход всех хранилищ: discover untested latest → enqueue
rbv_enqueue_all_untested() {
  local reason="${1:-schedule}"
  local sid
  mapfile -t ids < <(jq -r '.storages[].id' "$RBV_CONFIG")
  for sid in "${ids[@]}"; do
    msg INFO "Discover ${sid} (deep, untested latest)…"
    while IFS='|' read -r kind inst key parent; do
      [[ -n "$key" ]] || continue
      rbv_enqueue_instance "$sid" "$kind" "$inst" "$key" "$parent" "$reason"
    done < <(rbv_discover "$sid" true)
  done
}

rbv_queue_lock() {
  local lock
  lock="$(rbv_work_dir)/locks/worker.lock"
  exec 9>"$lock"
  flock -n 9 || { exec 9>&-; return 1; }
  return 0
}

rbv_queue_unlock() {
  # fd 9 закрывается при выходе процесса, но явный unlock — при ошибках/short-circuit
  exec 9>&- 2>/dev/null || true
  return 0
}

# --- Config mutate ----------------------------------------------------------

rbv_save_config() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; msg ERR "Битый JSON"; exit 1; }
  mv -f "$tmp" "$RBV_CONFIG"
  chmod 600 "$RBV_CONFIG"
}
