#!/usr/bin/env bash
# Проверки данных бота двумя группами (пользователи / платежи).
# Правило: отсутствие таблицы у бота — НЕ ошибка. Ошибка — пропажа данных:
# таблица была в прошлой проверке и исчезла, либо строк стало меньше.
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
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/checks.sh
source "$ROOT/lib/checks.sh"

echo "==== состав групп ===="
u="$(rbv_bot_tables users)"
p="$(rbv_bot_tables payments)"
for t in users subscriptions tariffs app_settings cabinet_email_verification_codes cabinet_site_visits; do
  [[ " $u " == *" $t "* ]] || fail "группа users: нет $t" "$u"
done
[[ "$(wc -w <<<"$u")" == "6" ]] && pass "группа users — 6 таблиц" || fail "группа users" "$u"
for t in payments payment_intents payment_webhook_events recurring_yookassa recurring_robokassa; do
  [[ " $p " == *" $t "* ]] || fail "группа payments: нет $t" "$p"
done
[[ "$(wc -w <<<"$p")" == "5" ]] && pass "группа payments — 5 таблиц" || fail "группа payments" "$p"

jq '.checks.bot.tables={users:["users","my_clients"],payments:["payments"]}' \
  "$RBV_CONFIG" >"$T/c.json" && mv "$T/c.json" "$RBV_CONFIG"
[[ "$(rbv_bot_tables users)" == "users my_clients" ]] && pass "состав переопределяется конфигом" \
  || fail "override" "$(rbv_bot_tables users)"
jq 'del(.checks.bot.tables)' "$RBV_CONFIG" >"$T/c.json" && mv "$T/c.json" "$RBV_CONFIG"

# --- мок БД: PRESENT/ROWS задаются переменными ------------------------------
# shellcheck disable=SC2317
rbv_psql() {
  local q="$1" t n
  if [[ "$q" == *"to_regclass('public.'||quote_ident(t))"* ]]; then
    for t in $MOCK_PRESENT; do printf '%s\n' "$t"; done
    return 0
  fi
  if [[ "$q" == *"UNION ALL"* && "$q" == *"count(*)"* ]]; then
    for t in $MOCK_ROWS; do printf '%s|%s\n' "${t%%:*}" "${t##*:}"; done
    return 0
  fi
  printf '\n'
  return 0
}

group_run() { rbv_bot_group_report "$1" "$2"; }
summary() { group_run "$1" "$2" | grep '^SUMMARY|' | cut -d'|' -f2; }
detail()  { group_run "$1" "$2" | grep '^SUMMARY|' | cut -d'|' -f5; }
# tstatus <группа> <таблица> <baseline>
tstatus() { group_run "$1" "$3" | grep "^TABLE|$2|" | cut -d'|' -f5; }

echo "==== неполный набор таблиц — не ошибка ===="
MOCK_PRESENT="users subscriptions"
MOCK_ROWS="users:1500 subscriptions:300"
[[ "$(summary users '{}')" == "ok" ]] && pass "нет 4 из 6 таблиц → ok" || fail "неполный набор" "$(summary users '{}')"
[[ "$(tstatus users cabinet_site_visits '{}')" == "absent" ]] && pass "отсутствующая таблица помечена absent" \
  || fail "absent" "$(tstatus users cabinet_site_visits '{}')"
d="$(detail users '{}')"
[[ "$d" == *"2/6 таблиц"* && "$d" == *"users=1500"* && "$d" == *"нет: tariffs"* ]] \
  && pass "сводка со списком отсутствующих" || fail "сводка" "$d"

echo "==== группы платежей нет вовсе ===="
MOCK_PRESENT=""
MOCK_ROWS=""
[[ "$(summary payments '{}')" == "skip" ]] && pass "бот без платежей → skip, не fail" \
  || fail "payments skip" "$(summary payments '{}')"

echo "==== рост данных ===="
MOCK_PRESENT="users subscriptions"
MOCK_ROWS="users:1600 subscriptions:300"
base='{"tables":{"users":1500,"subscriptions":300}}'
[[ "$(summary users "$base")" == "ok" ]] && pass "рост строк → ok" || fail "рост" "$(summary users "$base")"
[[ "$(tstatus users users "$base")" == "ok" ]] && pass "users ok" || fail "users ok" "$(tstatus users users "$base")"

echo "==== потеря данных ===="
MOCK_ROWS="users:1400 subscriptions:300"
[[ "$(summary users "$base")" == "fail" ]] && pass "строк стало меньше → fail" || fail "падение строк" "$(summary users "$base")"
[[ "$(tstatus users users "$base")" == "drop" ]] && pass "таблица помечена drop" || fail "drop" "$(tstatus users users "$base")"

echo "==== таблица исчезла ===="
MOCK_PRESENT="users"
MOCK_ROWS="users:1500"
[[ "$(summary users "$base")" == "fail" ]] && pass "исчезла таблица с данными → fail" \
  || fail "gone fail" "$(summary users "$base")"
[[ "$(tstatus users subscriptions "$base")" == "gone" ]] && pass "таблица помечена gone" \
  || fail "gone" "$(tstatus users subscriptions "$base")"
# та, которой и раньше не было, исчезновением не считается
[[ "$(tstatus users tariffs "$base")" == "absent" ]] && pass "не было и нет → absent" \
  || fail "absent vs gone" "$(tstatus users tariffs "$base")"

echo "==== пустые таблицы ===="
MOCK_PRESENT="users tariffs recurring_robokassa"
MOCK_ROWS="users:10 tariffs:0 recurring_robokassa:0"
[[ "$(summary users '{}')" == "ok" ]] && pass "пустая tariffs без истории → не ошибка" \
  || fail "empty tariffs" "$(summary users '{}')"
[[ "$(tstatus users tariffs '{}')" == "empty" ]] && pass "пустая помечена empty" \
  || fail "empty" "$(tstatus users tariffs '{}')"
MOCK_ROWS="users:0 tariffs:5 recurring_robokassa:0"
[[ "$(summary users '{}')" == "fail" ]] && pass "пустая users → fail (бот без пользователей)" \
  || fail "users empty" "$(summary users '{}')"

echo "==== свежесть по группам ===="
# shellcheck disable=SC2317
rbv_psql() {
  local q="$1" t
  if [[ "$q" == *"to_regclass('public.'||quote_ident(t))"* ]]; then
    for t in $MOCK_PRESENT; do printf '%s\n' "$t"; done
    return 0
  fi
  if [[ "$q" == *"information_schema.columns"* ]]; then
    printf '%s\n' "$MOCK_TS_COLS"
    return 0
  fi
  if [[ "$q" == *"EXTRACT(EPOCH"* ]]; then
    printf '%s\n' "$MOCK_EPOCH"
    return 0
  fi
  printf '\n'
  return 0
}
MOCK_PRESENT="payments payment_intents"
MOCK_TS_COLS="payments|created_at"
MOCK_EPOCH="1786438827|payments.created_at"
out="$(rbv_max_event_epoch bot)"
[[ "$out" == "1786438827|payments.created_at" ]] && pass "свежесть берётся из платежей" \
  || fail "свежесть платежи" "$out"

MOCK_PRESENT=""
MOCK_TS_COLS=""
MOCK_EPOCH=""
[[ "$(rbv_max_event_epoch bot)" == "missing" ]] && pass "нет дат нигде → missing (обработается как skip)" \
  || fail "свежесть missing" "$(rbv_max_event_epoch bot)"

echo "==== toggles ===="
jq '.checks.bot.bot_payments=false' "$RBV_CONFIG" >"$T/c.json" && mv "$T/c.json" "$RBV_CONFIG"
rbv_check_enabled bot bot_payments && fail "bot_payments off" "включено" || pass "bot_payments отключается"
rbv_check_enabled bot bot_users && pass "bot_users по умолчанию включён" || fail "bot_users default" "выключен"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
