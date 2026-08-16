#!/usr/bin/env bash
# Проверки экземпляра: toggles, baseline, rows/events, stability, ports, TG-отчёт.
# Source после common.sh.
set -euo pipefail

[[ -n "${__RBV_CHECKS:-}" ]] && return 0
__RBV_CHECKS=1

# --- toggles ----------------------------------------------------------------

rbv_check_enabled() {
  # rbv_check_enabled <kind> <name>  → 0 если включено (default true)
  # Важно: jq `false // x` даёт x — нельзя использовать // для булевых.
  # Алиасы (старые имена → новые): db_rows|user_rows_monotonic→user_rows,
  # stack_up|stability→stack.
  local kind="$1" name="$2"
  local names=("$name")
  case "$name" in
    user_rows) names=(user_rows user_rows_monotonic db_rows) ;;
    stack)     names=(stack stack_up stability) ;;
  esac
  local n v
  for n in "${names[@]}"; do
    v="$(jq -r --arg k "$kind" --arg n "$n" '
      if (.checks[$k] | type)=="object" and (.checks[$k] | has($n)) then .checks[$k][$n]|tostring
      elif (.checks.default | type)=="object" and (.checks.default | has($n)) then .checks.default[$n]|tostring
      else "__missing__" end
    ' "$RBV_CONFIG" 2>/dev/null || echo "__missing__")"
    if [[ "$v" != "__missing__" ]]; then
      case "$v" in
        false|FALSE|0|no|off) return 1 ;;
        *) return 0 ;;
      esac
    fi
  done
  # ни одного ключа нет — default on
  return 0
}

rbv_skew_sec() {
  local h
  h="$(jq -r '.checks.timezone_skew_hours // 14' "$RBV_CONFIG" 2>/dev/null || echo 14)"
  [[ "$h" =~ ^[0-9]+$ ]] || h=14
  echo $(( h * 3600 ))
}

rbv_stability_sec() {
  local s
  s="$(jq -r '.checks.stability_seconds // 180' "$RBV_CONFIG" 2>/dev/null || echo 180)"
  [[ "$s" =~ ^[0-9]+$ ]] || s=180
  echo "$s"
}

# --- archive timestamp from filename (epoch, UTC best-effort) ---------------

rbv_parse_archive_epoch() {
  local name="$1" y m d H M S
  # remnawave_backup_2026-08-10_03_00_00.tar.gz
  if [[ "$name" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})_([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    H="${BASH_REMATCH[4]}"; M="${BASH_REMATCH[5]}"; S="${BASH_REMATCH[6]}"
    date -u -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null && return 0
  fi
  # custom_bot_X_20260810_030015.tar.gz
  if [[ "$name" =~ _([0-9]{8})_([0-9]{6})\.tar\.gz ]]; then
    local ds="${BASH_REMATCH[1]}" ts="${BASH_REMATCH[2]}"
    y="${ds:0:4}"; m="${ds:4:2}"; d="${ds:6:2}"
    H="${ts:0:2}"; M="${ts:2:2}"; S="${ts:4:2}"
    date -u -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null && return 0
  fi
  echo 0
}

# --- baseline per instance --------------------------------------------------

rbv_baseline_path() {
  local sid="$1" inst="$2"
  local safe
  safe="$(printf '%s' "$inst" | sha256sum | awk '{print $1}')"
  printf '%s/baselines/%s/%s.json\n' "$(rbv_work_dir)" "$sid" "$safe"
}

rbv_baseline_load() {
  local f
  f="$(rbv_baseline_path "$1" "$2")"
  [[ -f "$f" ]] || { echo '{}'; return 0; }
  cat "$f"
}

rbv_baseline_save() {
  local sid="$1" inst="$2" json="$3"
  local f dir
  f="$(rbv_baseline_path "$sid" "$inst")"
  dir="$(dirname "$f")"
  mkdir -p "$dir"
  printf '%s\n' "$json" > "$f"
}

# --- DB helpers (PG_CID must be set; RBV_PG_DB — целевая БД после restore) -

rbv_psql() {
  docker exec "$PG_CID" psql -U postgres -d "${RBV_PG_DB:-postgres}" -Atc "$1" 2>/dev/null || true
}

# Выбрать БД приложения. Дампы ботов — как правило pg_dumpall: в `postgres`
# остаётся служебная мелочь (23 таблицы мониторинга), а приложение живёт в
# своей БД (vpnbot и т.п.). Раньше брали первую непустую и почти всегда
# попадали в `postgres` → «users table missing» при целом бэкапе.
# Берём самую содержательную: сначала та, где есть public.users, затем по числу
# таблиц; явная подсказка (POSTGRES_DB из PROFILE.env) имеет приоритет.
# ВАЖНО: вызывать БЕЗ подстановки `$(…)`. Функция выставляет RBV_PG_DB /
# RBV_PG_TABLES / RBV_PG_DB_LIST в текущей оболочке, а в подоболочке они
# умирают вместе с ней — из-за этого выбранная БД («vpnbot») терялась, все
# дальнейшие запросы шли в пустую `postgres`, и целый бэкап получал
# «users table missing».
# $1 — подсказка. stdout: число таблиц (для логов).
rbv_select_app_db() {
  local hint="${1:-}" db tables users score
  local best_db="postgres" best_score=-1 best_tables=0
  RBV_PG_DB="postgres"
  RBV_PG_TABLES=0
  RBV_PG_DB_LIST=""
  _rbv_db_tables() {
    docker exec "$PG_CID" psql -U postgres -d "$1" -Atc \
      "SELECT count(*) FROM pg_stat_user_tables" 2>/dev/null | tr -d '[:space:]' || echo 0
  }
  _rbv_db_has_users() {
    local r
    r="$(docker exec "$PG_CID" psql -U postgres -d "$1" -Atc \
      "SELECT CASE WHEN to_regclass('public.users') IS NULL THEN 0 ELSE 1 END" 2>/dev/null \
      | tr -d '[:space:]' || echo 0)"
    [[ "$r" == "1" ]] && echo 1 || echo 0
  }
  while IFS= read -r db; do
    db="$(echo "${db:-}" | tr -d '[:space:]')"
    [[ -n "$db" ]] || continue
    tables="$(_rbv_db_tables "$db")"
    [[ "$tables" =~ ^[0-9]+$ ]] || tables=0
    (( tables > 0 )) || continue
    users="$(_rbv_db_has_users "$db")"
    score=$(( users * 1000000 + tables ))
    [[ -n "$hint" && "$db" == "$hint" ]] && score=$(( score + 2000000 ))
    RBV_PG_DB_LIST+="${db}=${tables}$( ((users)) && printf '+users')  "
    if (( score > best_score )); then
      best_score=$score
      best_db="$db"
      best_tables=$tables
    fi
  done < <(docker exec "$PG_CID" psql -U postgres -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname='postgres' DESC, datname" 2>/dev/null || true)
  RBV_PG_DB_LIST="${RBV_PG_DB_LIST%  }"
  if (( best_score < 0 )); then
    printf '0\n'
    return 0
  fi
  RBV_PG_DB="$best_db"
  RBV_PG_TABLES="$best_tables"
  printf '%s\n' "$best_tables"
  return 0
}

# to_regclass → schema.table или пусто; всегда rc=0.
rbv_regclass() {
  local name="$1" c
  c="$(rbv_psql "SELECT to_regclass('${name}');")"
  c="$(echo "$c" | tr -d '[:space:]')"
  if [[ -n "$c" && "$c" != "null" ]]; then
    printf '%s\n' "$c"
  fi
  return 0
}

# Колонки таблицы: name|udt_name (по одной на строку). $1 = bare table name (public).
rbv_table_columns() {
  local tbl="$1"
  rbv_psql "SELECT column_name||'|'||udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' ORDER BY ordinal_position;"
  return 0
}

# В отчёт: список полей таблицы (или «таблица отсутствует»).
# Печатает в stdout; вызывающий пишет в report.
rbv_dump_table_fields() {
  local bare="$1" reg cols
  reg="$(rbv_regclass "public.${bare}")"
  if [[ -z "$reg" ]]; then
    printf '%s: (таблица отсутствует)\n' "$bare"
    return 0
  fi
  cols="$(rbv_table_columns "$bare")"
  if [[ -z "$(echo "$cols" | tr -d '[:space:]')" ]]; then
    printf '%s (%s): (колонки не прочитались)\n' "$bare" "$reg"
    return 0
  fi
  printf '%s (%s) columns:\n' "$bare" "$reg"
  while IFS='|' read -r n t || [[ -n "${n:-}" ]]; do
    [[ -n "${n:-}" ]] || continue
    printf '  - %s (%s)\n' "$n" "${t:-?}"
  done <<<"$cols"
  return 0
}

# Полный дамп схемы для ручной доработки проверок (все таблицы + поля + rows).
# stdout: текст; rc=0. Нужны PG_CID / RBV_PG_DB.
rbv_dump_schema_diag() {
  local t n cols ts_cols expect
  printf '=== SCHEMA DIAG ===\n'
  printf 'db=%s  time=%s\n' "${RBV_PG_DB:-postgres}" "$(date -Is)"
  printf '\n-- databases --\n'
  rbv_psql "SELECT datname||' | '||pg_catalog.pg_encoding_to_char(encoding)||' | '||datcollate FROM pg_database WHERE NOT datistemplate ORDER BY 1;" \
    | while IFS= read -r line || [[ -n "${line:-}" ]]; do
        [[ -n "${line:-}" ]] && printf '  %s\n' "$line"
      done
  printf '\n-- expected bot core tables --\n'
  for expect in users subscriptions tariffs app_settings \
      cabinet_email_verification_codes cabinet_site_visits \
      payments payment_intents payment_webhook_events \
      recurring_yookassa recurring_robokassa; do
    if [[ -n "$(rbv_regclass "public.${expect}")" ]]; then
      n="$(rbv_count_table "public.${expect}")"
      ts_cols="$(rbv_table_ts_columns "$expect" | tr '\n' ',' | sed 's/,$//')"
      printf '  OK   %-42s rows=%-8s ts=[%s]\n' "$expect" "$n" "${ts_cols:-}"
    else
      printf '  MISS %-42s\n' "$expect"
    fi
  done
  printf '\n-- all public user tables --\n'
  while IFS= read -r t || [[ -n "${t:-}" ]]; do
    t="$(echo "${t:-}" | tr -d '[:space:]')"
    [[ -n "$t" ]] || continue
    n="$(rbv_count_table "public.${t}")"
    ts_cols="$(rbv_table_ts_columns "$t" | tr '\n' ',' | sed 's/,$//')"
    printf '\nTABLE %s  rows=%s  ts_cols=[%s]\n' "$t" "$n" "${ts_cols:-}"
    cols="$(rbv_table_columns "$t")"
    if [[ -z "$(echo "$cols" | tr -d '[:space:]')" ]]; then
      printf '  (колонки не прочитались)\n'
      continue
    fi
    while IFS='|' read -r cn ct || [[ -n "${cn:-}" ]]; do
      [[ -n "${cn:-}" ]] || continue
      printf '  - %s (%s)\n' "$cn" "${ct:-?}"
    done <<<"$cols"
  done < <(rbv_psql "SELECT relname FROM pg_stat_user_tables ORDER BY relname;")
  printf '\n=== end SCHEMA DIAG ===\n'
  return 0
}

# Записать schema diag в RUN_DIR + logs/ (logs переживает runs prune keep=0).
# Печатает в report через callback-строки на stdout для вызывающего с rep.
# $1 = optional note
rbv_write_schema_diag() {
  local note="${1:-}" out log
  out="${RUN_DIR:-/tmp}/schema-diag.txt"
  mkdir -p "$(dirname "$out")" "$(rbv_work_dir)/logs" 2>/dev/null || true
  {
    [[ -n "$note" ]] && printf 'note: %s\n' "$note"
    rbv_dump_schema_diag
  } >"$out" 2>/dev/null || {
    printf 'schema diag failed (PG down?)\n' >"$out"
  }
  log="$(rbv_work_dir)/logs/schema_${RUN_ID:-diag}_$(date -u +%H%M%S).txt"
  cp -f "$out" "$log" 2>/dev/null || true
  printf 'SCHEMA_DIAG_FILE=%s\n' "$out"
  printf 'SCHEMA_DIAG_LOG=%s\n' "$log"
  cat "$out"
  return 0
}

# --- Группы данных бота -----------------------------------------------------
# Набор таблиц у ботов разный: отсутствие таблицы — НЕ ошибка (у бота просто нет
# такой функции). Ошибка — когда данные пропали: таблица была в прошлой
# проверке и исчезла, или строк стало меньше.
# Переопределить набор: .checks.bot.tables.users / .checks.bot.tables.payments.

rbv_bot_tables() {
  local group="$1" def cfg
  case "$group" in
    users)
      def="users subscriptions tariffs app_settings cabinet_email_verification_codes cabinet_site_visits" ;;
    payments)
      def="payments payment_intents payment_webhook_events recurring_yookassa recurring_robokassa" ;;
    *) return 0 ;;
  esac
  cfg="$(jq -r --arg g "$group" '
    (.checks.bot.tables[$g] // empty) | if type=="array" then join(" ") else empty end
  ' "$RBV_CONFIG" 2>/dev/null || true)"
  if [[ -n "$cfg" && "$cfg" != "null" ]]; then
    printf '%s\n' "$cfg"
  else
    printf '%s\n' "$def"
  fi
  return 0
}

# Какие из перечисленных таблиц есть в БД (одним запросом). $1 = список.
rbv_tables_present() {
  local list="${1:-}" arr
  [[ -n "${list// /}" ]] || return 0
  # shellcheck disable=SC2086 # список имён — нужен word splitting
  arr="$(printf '%s\n' $list | sed "s/'/''/g; s/^/'/; s/\$/'/" | paste -sd, -)"
  [[ -n "$arr" ]] || return 0
  rbv_psql "SELECT t FROM unnest(ARRAY[${arr}]::text[]) AS t WHERE to_regclass('public.'||quote_ident(t)) IS NOT NULL ORDER BY 1;"
  return 0
}

# Число строк по каждой таблице одним запросом. stdout: name|rows
rbv_tables_counts() {
  local list="${1:-}" t sql=""
  for t in $list; do
    [[ -n "$t" ]] || continue
    [[ -n "$sql" ]] && sql+=" UNION ALL "
    sql+="SELECT '${t}'::text AS t, count(*)::bigint AS n FROM public.\"${t}\""
  done
  [[ -n "$sql" ]] || return 0
  rbv_psql "SELECT t||'|'||n FROM (${sql}) s ORDER BY t;"
  return 0
}

# Самая свежая дата среди всех timestamp/date-колонок перечисленных таблиц.
# stdout: <epoch>|<таблица.колонка> (пусто, если дат нет)
rbv_tables_max_epoch() {
  local list="${1:-}" arr pairs sql="" tbl col
  [[ -n "${list// /}" ]] || return 0
  # shellcheck disable=SC2086 # список имён — нужен word splitting
  arr="$(printf '%s\n' $list | sed "s/'/''/g; s/^/'/; s/\$/'/" | paste -sd, -)"
  [[ -n "$arr" ]] || return 0
  pairs="$(rbv_psql "SELECT table_name||'|'||column_name FROM information_schema.columns WHERE table_schema='public' AND table_name = ANY(ARRAY[${arr}]::text[]) AND (data_type IN ('timestamp without time zone','timestamp with time zone','date') OR udt_name IN ('timestamp','timestamptz','date'));")"
  while IFS='|' read -r tbl col; do
    [[ -n "${tbl:-}" && -n "${col:-}" ]] || continue
    [[ -n "$sql" ]] && sql+=" UNION ALL "
    sql+="SELECT '${tbl}.${col}'::text AS src, EXTRACT(EPOCH FROM MAX(\"${col}\"))::bigint AS e FROM public.\"${tbl}\""
  done <<<"$pairs"
  [[ -n "$sql" ]] || return 0
  rbv_psql "SELECT e||'|'||src FROM (${sql}) s WHERE e IS NOT NULL ORDER BY e DESC LIMIT 1;"
  return 0
}

# Сверка группы с baseline. $1 = группа, $2 = baseline JSON.
# stdout (для отчёта и для вызывающего):
#   TABLE|<имя>|<строк или ->|<было или ->|<ok|new|empty|drop|gone|absent>
#   SUMMARY|<ok|fail|skip>|<есть>/<всего>|<сумма строк>|<краткая сводка>
rbv_bot_group_report() {
  local group="$1" base="${2:-\{\}}"
  local list present t rows prev status
  local found=0 all=0 sum=0 bad=0
  local brief="" missing=""
  local -A cnt=() prevmap=()
  list="$(rbv_bot_tables "$group")"
  present="$(rbv_tables_present "$list" | tr '\n' ' ')"
  while IFS='|' read -r t rows; do
    [[ -n "${t:-}" ]] || continue
    cnt["$t"]="$rows"
  done < <(rbv_tables_counts "$present")
  while IFS='|' read -r t rows; do
    [[ -n "${t:-}" ]] || continue
    prevmap["$t"]="$rows"
  done < <(jq -r '.tables // {} | to_entries[] | "\(.key)|\(.value)"' <<<"$base" 2>/dev/null || true)

  for t in $list; do
    [[ -n "$t" ]] || continue
    all=$((all + 1))
    rows="${cnt[$t]:-}"
    prev="${prevmap[$t]:-}"
    if [[ -z "$rows" ]]; then
      if [[ "$prev" =~ ^[0-9]+$ ]] && (( prev > 0 )); then
        status="gone"
        bad=$((bad + 1))
      else
        status="absent"
        missing+="${t}, "
      fi
      printf 'TABLE|%s|-|%s|%s\n' "$t" "${prev:--}" "$status"
      continue
    fi
    found=$((found + 1))
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=0
    sum=$((sum + rows))
    if [[ "$prev" =~ ^[0-9]+$ ]]; then
      if (( rows < prev )); then
        status="drop"
        bad=$((bad + 1))
      else
        status="ok"
      fi
    elif (( rows == 0 )); then
      # пустая таблица без истории — информативно (у бота просто нет данных),
      # кроме users: бот без пользователей = бэкап не тот
      if [[ "$t" == "users" ]]; then
        status="drop"
        bad=$((bad + 1))
      else
        status="empty"
      fi
    else
      status="new"
    fi
    brief+="${t}=${rows} "
    printf 'TABLE|%s|%s|%s|%s\n' "$t" "$rows" "${prev:--}" "$status"
  done

  local gstatus="ok"
  if (( bad > 0 )); then
    gstatus="fail"
  elif (( found == 0 )); then
    gstatus="skip"
  fi
  local detail="${found}/${all} таблиц, строк=${sum}"
  [[ -n "$brief" ]] && detail+=" · ${brief% }"
  [[ -n "$missing" ]] && detail+=" · нет: ${missing%, }"
  printf 'SUMMARY|%s|%s/%s|%s|%s\n' "$gstatus" "$found" "$all" "$sum" "$detail"
  return 0
}

rbv_find_users_table() {
  # $1 = optional kind (bot → строго public.users; иначе эвристика panel).
  # stdout: schema.table or empty; всегда rc=0 (иначе set -e рвёт utbl="$(…)")
  local kind="${1:-}" t c
  if [[ "$kind" == "bot" ]]; then
    rbv_regclass "public.users"
    return 0
  fi
  for t in public.users users public.user user; do
    c="$(rbv_regclass "$t")"
    if [[ -n "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  c="$(rbv_regclass 'public."User"')"
  if [[ -n "$c" ]]; then
    printf '%s\n' "$c"
    return 0
  fi
  t="$(rbv_psql "SELECT quote_ident(schemaname)||'.'||quote_ident(relname) FROM pg_stat_user_tables WHERE relname ILIKE '%user%' ORDER BY n_live_tup DESC NULLS LAST LIMIT 1;")"
  t="$(echo "$t" | tr -d '[:space:]')"
  [[ -n "$t" && "$t" != "null" ]] && printf '%s\n' "$t"
  return 0
}

rbv_count_table() {
  local tbl="$1"
  local n
  n="$(rbv_psql "SELECT count(*) FROM ${tbl};")"
  n="$(echo "$n" | tr -d '[:space:]')"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$n"
  else
    printf '0\n'
  fi
  return 0
}

# Timestamp/date колонки public.$1 (имена, по одной строке).
rbv_table_ts_columns() {
  local bare="$1"
  rbv_psql "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${bare}' AND (data_type IN ('timestamp without time zone','timestamp with time zone','date') OR udt_name IN ('timestamp','timestamptz','date')) ORDER BY ordinal_position;"
  return 0
}

# Max epoch по timestamp-колонкам таблицы.
# stdout:
#   nofields          — нет timestamp/date колонок
#   0|<table>         — колонки есть, но MAX пуст
#   <epoch>|<table.col>
rbv_max_epoch_in_table() {
  local bare="$1" col e epoch=0 best="" tried=0 has
  while IFS= read -r col || [[ -n "${col:-}" ]]; do
    col="$(echo "${col:-}" | tr -d '[:space:]')"
    [[ -n "$col" ]] || continue
    tried=$((tried + 1))
    e="$(rbv_psql "SELECT EXTRACT(EPOCH FROM MAX(${col}))::bigint FROM public.${bare};" | tr -d '[:space:]')"
    [[ "$e" =~ ^[0-9]+$ ]] || continue
    if (( e > epoch )); then
      epoch=$e
      best="${bare}.${col}"
    fi
  done < <(rbv_table_ts_columns "$bare")
  # fallback: известные имена, если information_schema пуст/не отдал типы
  if (( tried == 0 )); then
    for col in created_at updated_at processed_at received_at event_at timestamp \
               '"createdAt"' '"updatedAt"' '"processedAt"'; do
      has="$(rbv_psql "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${bare}' AND column_name='${col//\"/}' LIMIT 1;" | tr -d '[:space:]')"
      [[ "$has" == "1" ]] || continue
      tried=$((tried + 1))
      e="$(rbv_psql "SELECT EXTRACT(EPOCH FROM MAX(${col}))::bigint FROM public.${bare};" | tr -d '[:space:]')"
      [[ "$e" =~ ^[0-9]+$ ]] || continue
      if (( e > epoch )); then
        epoch=$e
        best="${bare}.${col//\"/}"
      fi
    done
  fi
  if (( tried == 0 )); then
    printf 'nofields\n'
    return 0
  fi
  if [[ -n "$best" ]]; then
    printf '%s|%s\n' "$epoch" "$best"
  else
    printf '0|%s\n' "$bare"
  fi
  return 0
}

# Max epoch of "event-like" columns.
# $1 = optional kind: bot → payment_webhook_events; иначе users/nodes (panel).
# stdout: см. rbv_max_epoch_in_table; panel — "epoch" или "epoch|table".
rbv_max_event_epoch() {
  local kind="${1:-}" epoch=0 cand e best=""
  if [[ "$kind" == "bot" ]]; then
    # свежесть по всем платёжным таблицам, что есть у бота; если платежей
    # нет вовсе — по пользовательским
    local out g
    for g in payments users; do
      out="$(rbv_tables_max_epoch "$(rbv_tables_present "$(rbv_bot_tables "$g")" | tr '\n' ' ')")"
      out="$(printf '%s' "$out" | tr -d '\r')"
      [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    done
    printf 'missing\n'
    return 0
  fi
  for cand in \
    "SELECT EXTRACT(EPOCH FROM MAX(updated_at))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(created_at))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(\"updatedAt\"))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(\"createdAt\"))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(last_online))::bigint FROM users" \
    "SELECT EXTRACT(EPOCH FROM MAX(updated_at))::bigint FROM nodes" \
    "SELECT EXTRACT(EPOCH FROM MAX(created_at))::bigint FROM nodes"
    do
    e="$(rbv_psql "$cand;" 2>/dev/null | tr -d '[:space:]')"
    [[ "$e" =~ ^[0-9]+$ ]] || continue
    if (( e > epoch )); then
      epoch=$e
      case "$cand" in
        *FROM\ users*) best="users" ;;
        *FROM\ nodes*) best="nodes" ;;
      esac
    fi
  done
  if [[ -n "$best" ]]; then
    printf '%s|%s\n' "$epoch" "$best"
  else
    printf '%s\n' "$epoch"
  fi
  return 0
}

# --- check results accumulator (JSON lines file) ----------------------------

rbv_checks_init() {
  RBV_CHECKS_FILE="${1:?}"
  echo '[]' > "$RBV_CHECKS_FILE"
}

rbv_check_add() {
  # name status detail [prev] [curr]
  local name="$1" status="$2" detail="$3" prev="${4:-}" curr="${5:-}"
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$status" --arg d "$detail" --arg p "$prev" --arg c "$curr" \
    '. + [{name:$n, status:$s, detail:$d, prev:$p, curr:$c}]' \
    "$RBV_CHECKS_FILE" > "$tmp"
  mv -f "$tmp" "$RBV_CHECKS_FILE"
}

# --- stack probes -----------------------------------------------------------

# TCP egress с сети $1 наружу? rc=0 = дыра (egress есть), rc=1 = изолировано/нет egress.
# Не пишет в checks.json — только probe.
rbv_net_has_egress() {
  local net="$1"
  local probe="rbv_iso_${RANDOM}"
  docker rm -f "$probe" >/dev/null 2>&1 || true
  if ! docker run -d --name "$probe" --network "$net" busybox:1.36 sleep 30 >/dev/null 2>&1; then
    # нет busybox — не можем доказать egress; считаем «нет дыры» (осторожный false)
    return 1
  fi
  local leak=1
  if docker exec "$probe" nc -z -w 3 1.1.1.1 443 >/dev/null 2>&1 \
     || docker exec "$probe" wget -qO- -T 3 http://1.1.1.1 >/dev/null 2>&1; then
    leak=0
  fi
  docker rm -f "$probe" >/dev/null 2>&1 || true
  return "$leak"
}

# Preflight до download/restore: Docker умеет --internal без egress.
# При fail — вызывающий должен остановить все тесты.
# stdout: краткий detail; rc=0 ok, rc=1 fail.
rbv_preflight_isolation() {
  local net="rbv_preflight_${RANDOM}_net"
  local inn
  docker network rm "$net" >/dev/null 2>&1 || true
  if ! docker network create --internal "$net" >/dev/null 2>&1; then
    printf '%s\n' "не удалось создать --internal сеть"
    return 1
  fi
  inn="$(docker network inspect -f '{{.Internal}}' "$net" 2>/dev/null || echo false)"
  if [[ "$inn" != "true" ]]; then
    docker network rm "$net" >/dev/null 2>&1 || true
    printf '%s\n' "network.Internal=${inn} после create --internal"
    return 1
  fi
  if rbv_net_has_egress "$net"; then
    docker network rm "$net" >/dev/null 2>&1 || true
    printf '%s\n' "TCP egress на --internal сети (1.1.1.1) — хост не изолирует"
    return 1
  fi
  docker network rm "$net" >/dev/null 2>&1 || true
  printf '%s\n' "Internal=true, внешнего TCP нет"
  return 0
}

# Проверка изоляции: DNS на internal-сети Docker часто резолвится —
# смотрим Internal-флаг и реальный TCP egress.
rbv_check_isolation() {
  local sample="$1"
  [[ -n "${NET_NAME:-}" ]] || { rbv_check_add isolation skip "нет NET_NAME"; return 0; }
  local inn
  inn="$(docker network inspect -f '{{.Internal}}' "$NET_NAME" 2>/dev/null || echo false)"
  if [[ "$inn" != "true" ]]; then
    rbv_check_add isolation fail "network.Internal=${inn}"
    return 1
  fi
  if rbv_net_has_egress "$NET_NAME"; then
    rbv_check_add isolation fail "есть TCP egress наружу (1.1.1.1) при Internal=true"
    return 1
  fi
  # fallback: sample container /dev/tcp, если busybox не поднялся в has_egress
  # (has_egress при отсутствии busybox возвращает «нет дыры» — доп. проверка)
  if [[ -n "$sample" ]]; then
    if docker exec "$sample" sh -c 'timeout 3 sh -c "echo >/dev/tcp/1.1.1.1/443"' >/dev/null 2>&1; then
      rbv_check_add isolation fail "есть TCP egress наружу из sample-контейнера"
      return 1
    fi
  fi
  rbv_check_add isolation ok "Internal=true, внешнего TCP нет"
  return 0
}

rbv_check_stability() {
  local project="$1" compose="$2" sec="$3"
  local end now running crashed
  end=$(( $(date +%s) + sec ))
  local interval=15
  (( sec < 30 )) && interval=5
  msg INFO "stability: окно ${sec}с, интервал ${interval}с"
  while :; do
    now="$(date +%s)"
    (( now >= end )) && break
    running="$(docker compose -f "$compose" -p "$project" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
    crashed="$(docker compose -f "$compose" -p "$project" ps --status exited --status dead -q 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${crashed:-0}" -gt 0 ]]; then
      rbv_check_add stack fail "упали контейнеры: exited/dead=${crashed}, running=${running}"
      return 1
    fi
    if [[ "${running:-0}" -lt 1 ]]; then
      rbv_check_add stack fail "нет running-контейнеров"
      return 1
    fi
    msg INFO "stability: ещё ~$(( end - now ))с, running=${running}"
    sleep "$interval"
  done
  running="$(docker compose -f "$compose" -p "$project" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
  rbv_check_add stack ok "поднят, без падений ${sec}с, running=${running}"
  return 0
}

rbv_check_backend_ports() {
  # Probe internal service ports from compose.raw.json / running containers.
  local net="$1" compose_raw="$2" project="$3"
  local probe="rbv_probe_${RUN_ID}"
  docker rm -f "$probe" >/dev/null 2>&1 || true
  if ! docker run -d --name "$probe" --network "$net" \
       busybox:1.36 sleep 600 >/dev/null 2>&1; then
    rbv_check_add backend_ports skip "busybox недоступен"
    return 0
  fi
  local ok_n=0 fail_n=0 detail="" targets=""
  # Collect service:port from compose (container ports even if unpublished)
  targets="$(jq -r '
    .services // {} | to_entries[] |
    .key as $s |
    (.value.ports // [])[]? |
    (if type=="object" then (.target // .Published // empty|tostring)
     elif type=="string" then (capture("(?<p>[0-9]+)$") | .p // empty)
     else empty end) as $p |
    select($p != null and $p != "") |
    "\($s):\($p)"
  ' "$compose_raw" 2>/dev/null | sort -u | head -n 20 || true)"

  # Also from docker inspect ExposedPorts of running containers
  if [[ -z "$targets" ]]; then
    local cid
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      local name ports
      name="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$cid" 2>/dev/null || true)"
      [[ -z "$name" ]] && name="$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
      ports="$(docker inspect -f '{{range $p,$c := .Config.ExposedPorts}}{{$p}} {{end}}' "$cid" 2>/dev/null || true)"
      for p in $ports; do
        p="${p%%/*}"
        [[ "$p" =~ ^[0-9]+$ ]] && targets+="${name}:${p}"$'\n'
      done
    done < <(docker compose -f "${COMPOSE_FILE}" -p "$project" ps -q 2>/dev/null || true)
  fi

  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    local host="${t%%:*}" port="${t##*:}"
    local out=""
    # TCP ping via busybox nc, then HTTP GET
    if docker exec "$probe" nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
      out="$(docker exec "$probe" wget -qO- -T 3 "http://${host}:${port}/" 2>/dev/null \
            || docker exec "$probe" wget -qO- -T 3 "http://${host}:${port}/health" 2>/dev/null \
            || docker exec "$probe" wget -qO- -T 3 "http://${host}:${port}/api" 2>/dev/null \
            || echo "__TCP_OK__")"
      if [[ -n "$out" ]]; then
        ok_n=$((ok_n+1))
        detail+="✅ ${t} "
      else
        fail_n=$((fail_n+1))
        detail+="❌ ${t}:empty "
      fi
    else
      fail_n=$((fail_n+1))
      detail+="❌ ${t}:closed "
    fi
  done <<<"$targets"

  docker rm -f "$probe" >/dev/null 2>&1 || true

  if [[ -z "$targets" ]]; then
    rbv_check_add backend_ports skip "порты не обнаружены"
    return 0
  fi
  if (( fail_n > 0 && ok_n == 0 )); then
    rbv_check_add backend_ports fail "ok=${ok_n} fail=${fail_n} · ${detail}"
    return 1
  fi
  if (( fail_n > 0 )); then
    rbv_check_add backend_ports warn "ok=${ok_n} fail=${fail_n} · ${detail}"
    return 0
  fi
  rbv_check_add backend_ports ok "ok=${ok_n} · ${detail}"
  return 0
}

# --- Telegram formatting ----------------------------------------------------

rbv_status_icon() {
  case "$1" in
    ok) echo "✅" ;;
    fail) echo "❌" ;;
    warn) echo "⚠️" ;;
    skip) echo "⚪" ;;
    *) echo "•" ;;
  esac
}

rbv_html_esc() {
  # bash ${var//pat/&amp;} подставляет match в & — поэтому sed
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

rbv_format_tg_report() {
  # args via env-like: uses RBV_CHECKS_FILE and prints body to stdout
  local sid="$1" kind="$2" inst="$3" key="$4" overall="$5"
  local icon="🟢"
  [[ "$overall" == "true" ]] || icon="🔴"
  local path="s3://${RBV_BUCKET}/${key}"
  printf '%s <b>VERIFY %s</b>\n' "$icon" "$(echo "$kind" | tr 'a-z' 'A-Z')"
  printf '🗄 Хранилище: <b>%s</b>\n' "$(rbv_html_esc "$sid")"
  printf '🆔 Экземпляр: <code>%s</code>\n' "$(rbv_html_esc "$inst")"
  printf '📁 Путь: <code>%s</code>\n' "$(rbv_html_esc "$path")"
  printf '📦 Архив: <code>%s</code>\n' "$(rbv_html_esc "$(basename "$key")")"
  printf '\n<b>Проверки</b>\n'
  jq -r '.[] | "\(.status)|\(.name)|\(.detail)|\(.prev)|\(.curr)"' "$RBV_CHECKS_FILE" 2>/dev/null \
    | while IFS='|' read -r st name detail prev curr; do
        local ic
        ic="$(rbv_status_icon "$st")"
        printf '%s <b>%s</b> — %s\n' "$ic" "$(rbv_html_esc "$name")" "$(rbv_html_esc "$detail")"
        if [[ -n "$prev" || -n "$curr" ]]; then
          printf '   └ prev=<code>%s</code> → curr=<code>%s</code>\n' \
            "$(rbv_html_esc "${prev:-—}")" "$(rbv_html_esc "${curr:-—}")"
        fi
      done
  # diffs section
  local diffs
  diffs="$(jq -r '[.[] | select(.status=="fail" and (.prev!="" or .curr!=""))] | length' "$RBV_CHECKS_FILE" 2>/dev/null || echo 0)"
  if [[ "${diffs:-0}" -gt 0 ]]; then
    printf '\n<b>⚠ Расхождения</b>\n'
    jq -r '.[] | select(.status=="fail") | "• \(.name): \(.prev) → \(.curr) (\(.detail))"' \
      "$RBV_CHECKS_FILE" 2>/dev/null \
      | while IFS= read -r line; do
          printf '%s\n' "$(rbv_html_esc "$line")"
        done
  fi
}

rbv_tg_send_long() {
  # Split long HTML text into ≤3500 chunks
  local token="$1" chat="$2" text="$3" thread="${4:-}"
  local chunk="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ${#chunk} + ${#line} + 1 > 3500 )); then
      rbv_tg_send "$token" "$chat" "$chunk" "$thread"
      chunk=""
    fi
    chunk+="${line}"$'\n'
  done <<<"$text"
  [[ -n "$chunk" ]] && rbv_tg_send "$token" "$chat" "$chunk" "$thread"
}

rbv_tg_send_logs() {
  local token="$1" chat="$2" thread="$3" project="$4" compose="$5"
  local tmp logs
  tmp="$(mktemp)"
  {
    echo "=== compose ps ==="
    docker compose -f "$compose" -p "$project" ps 2>&1 || true
    echo
    local cid
    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      local name
      name="$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
      echo "=== logs: ${name} (tail 80) ==="
      docker logs --tail 80 "$cid" 2>&1 || true
      echo
    done < <(docker compose -f "$compose" -p "$project" ps -aq 2>/dev/null || true)
  } > "$tmp"
  # as message chunks (document upload needs multipart file — keep text for simplicity)
  logs="$(head -c 12000 "$tmp")"
  rbv_tg_send_long "$token" "$chat" "📄 <b>Логи контейнеров</b>
<pre>$(printf '%s' "$logs" | sed 's/[<>&]//g' | head -c 11000)</pre>" "$thread"
  rm -f "$tmp"
}
