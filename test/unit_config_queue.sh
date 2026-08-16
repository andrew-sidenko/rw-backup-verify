#!/usr/bin/env bash
# Smoke: classify, grouping, tested, global schedule — без Docker/S3.
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

# --- classify ---
out="$(rbv_classify_name 'remnawave_backup_2026-08-10_03_00_00.tar.gz')"
[[ "$out" == "panel|remnawave_backup" ]] && pass "classify panel" || fail "classify panel" "$out"

out="$(rbv_classify_name 'custom_bot_OneOkBotNew_20260810_030015.tar.gz')"
[[ "$out" == "bot|custom_bot_OneOkBotNew" ]] && pass "classify bot" || fail "classify bot" "$out"

out="$(rbv_classify_name 'custom_bot_vpnnew_20260810_030045.tar.gz.age')"
[[ "$out" == "bot|custom_bot_vpnnew" ]] && pass "classify bot age" || fail "classify bot age" "$out"

# --- storage + schedule ---
"$ROOT/bin/rw-backup-verify" storage add \
  --id s1 --bucket b --access-key a --secret-key s \
  --prefix rw-backup-full --backup-hint "прод 03:00" >/dev/null
"$ROOT/bin/rw-backup-verify" schedule set --interval-hours 6 >/dev/null
ih="$(jq -r '.verify.interval_hours' "$RBV_CONFIG")"
[[ "$ih" == "6" ]] && pass "global interval" || fail "global interval" "$ih"

"$ROOT/bin/rw-backup-verify" telegram set --token tok --chat-id 123 >/dev/null
pass "telegram set"

# --- symlink like install.sh: /usr/local/bin → …/bin/rw-backup-verify ---
fake_local="$T/usr/local/bin"
mkdir -p "$fake_local"
ln -sfn "$ROOT/bin/rw-backup-verify" "$fake_local/rw-backup-verify"
# Регресс: без readlink -f ROOT становился …/usr/local и искал …/usr/local/lib/common.sh
if out="$("$fake_local/rw-backup-verify" telegram show 2>&1)"; then
  printf '%s\n' "$out" | grep -q '"token"' && pass "symlink cli" || fail "symlink cli" "no token in: $out"
else
  fail "symlink cli" "$out"
fi

# --- tested registry ---
rbv_mark_tested s1 "rw-backup-full/panel/h1/remnawave_backup_1.tar.gz" true "run1"
if rbv_is_tested s1 "rw-backup-full/panel/h1/remnawave_backup_1.tar.gz"; then
  pass "is_tested yes"
else
  fail "is_tested yes" "false"
fi
if rbv_is_tested s1 "other-key"; then
  fail "is_tested no" "true"
else
  pass "is_tested no"
fi

# --- grouping logic (simulate discover awk path) ---
# parent A: two bots + two versions each; parent B: panel versions
# Expect latest per family
tmp="$(mktemp)"
{
  printf '%s\t%s\t%s\t%s\t%s\n' "p/A|custom_bot_bot1" "custom_bot_bot1_20260801_010000.tar.gz" "p/A/custom_bot_bot1_20260801_010000.tar.gz" "p/A" "bot"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/A|custom_bot_bot1" "custom_bot_bot1_20260810_030000.tar.gz" "p/A/custom_bot_bot1_20260810_030000.tar.gz" "p/A" "bot"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/A|custom_bot_bot2" "custom_bot_bot2_20260810_020000.tar.gz" "p/A/custom_bot_bot2_20260810_020000.tar.gz" "p/A" "bot"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/B|remnawave_backup" "remnawave_backup_2026-08-01_03_00_00.tar.gz" "p/B/remnawave_backup_2026-08-01_03_00_00.tar.gz" "p/B" "panel"
  printf '%s\t%s\t%s\t%s\t%s\n' "p/B|remnawave_backup" "remnawave_backup_2026-08-10_03_00_00.tar.gz" "p/B/remnawave_backup_2026-08-10_03_00_00.tar.gz" "p/B" "panel"
} > "$tmp"
latest="$(sort -t$'\t' -k1,1 -k2,2 "$tmp" | awk -F'\t' '
  { g=$1; if (g!=prev){ if(prev!="") print last; prev=g } last=$0 }
  END { if(prev!="") print last }
')"
n="$(printf '%s\n' "$latest" | grep -c . || true)"
[[ "$n" == "3" ]] && pass "group count=3" || fail "group count" "n=$n"
printf '%s\n' "$latest" | grep -q 'custom_bot_bot1_20260810_030000' && pass "bot1 latest" || fail "bot1 latest" "missing"
printf '%s\n' "$latest" | grep -q 'custom_bot_bot2_20260810_020000' && pass "bot2 kept" || fail "bot2" "missing"
printf '%s\n' "$latest" | grep -q 'remnawave_backup_2026-08-10' && pass "panel latest" || fail "panel latest" "missing"
rm -f "$tmp"

# --- enqueue FIFO ---
rbv_enqueue_instance s1 bot "bot:p/A:custom_bot_bot1" "p/A/custom_bot_bot1_x.tar.gz" "p/A" manual
sleep 0.01
rbv_enqueue_instance s1 panel "panel:p/B:remnawave_backup" "p/B/remnawave_backup_x.tar.gz" "p/B" manual
mapfile -t jobs < <(ls -1 "$(rbv_queue_dir)"/*.job | sort)
[[ "$(jq -r .kind "${jobs[0]}")" == "bot" ]] && pass "FIFO first=bot" || fail "FIFO" "$(jq -r .kind "${jobs[0]}")"
[[ "$(jq -r .kind "${jobs[1]}")" == "panel" ]] && pass "FIFO second=panel" || fail "FIFO2" "bad"

# --- global due ---
mkdir -p "$(rbv_work_dir)/locks"
date +%s > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then fail "global not due" "was due"; else pass "global not due"; fi
echo $(( $(date +%s) - 7*3600 )) > "$(rbv_work_dir)/locks/last_run_global"
if rbv_global_due; then pass "global due"; else fail "global due" "not"; fi

"$ROOT/bin/rw-backup-verify" schedule set --times "$(date +%H:%M)" >/dev/null
rm -f "$(rbv_work_dir)/locks/due_global_"*
# clear interval so times path used — schedule set replaces verify object
if rbv_global_due; then pass "times due"; else fail "times due" "not"; fi

# --- checks lib ---
# shellcheck source=../lib/checks.sh
source "$ROOT/lib/checks.sh"

# toggles
jq '.checks.bot.backend_ports=false | .checks.panel.stack=false' \
  "$RBV_CONFIG" > "$T/c3.json" && mv "$T/c3.json" "$RBV_CONFIG"
rbv_check_enabled bot backend_ports && fail "bot ports off" "enabled" || pass "bot ports disabled"
rbv_check_enabled panel backend_ports && pass "panel ports on" || fail "panel ports" "off"
rbv_check_enabled panel stack && fail "panel stack off" "on" || pass "panel stack disabled"
# aliases: старое stability=false должно выключать stack
jq '.checks.bot.stability=false | del(.checks.bot.stack)' "$RBV_CONFIG" > "$T/c4.json" && mv "$T/c4.json" "$RBV_CONFIG"
rbv_check_enabled bot stack && fail "alias stability→stack" "still on" || pass "alias stability disables stack"

# archive epoch parse
ep="$(rbv_parse_archive_epoch 'remnawave_backup_2026-08-10_03_00_00.tar.gz')"
[[ "$ep" -gt 1000000000 ]] && pass "parse panel epoch" || fail "parse panel epoch" "$ep"
ep2="$(rbv_parse_archive_epoch 'custom_bot_x_20260810_030015.tar.gz')"
[[ "$ep2" -gt 1000000000 ]] && pass "parse bot epoch" || fail "parse bot epoch" "$ep2"

# skew / event window relative
skew=3600
prev=1000000; curr=1003600; event=1001800
lo=$((prev - skew)); hi=$((curr + skew))
(( event >= lo && event <= hi )) && pass "event in window" || fail "event window" "$event"
event_bad=$((curr + skew + 10))
(( event_bad > hi )) && pass "event out detected" || fail "event out" "not"

# baseline roundtrip
rbv_baseline_save s1 "bot:p/A:custom_bot_bot1" '{"user_rows":10,"archive_ts":100}'
b="$(rbv_baseline_load s1 "bot:p/A:custom_bot_bot1")"
[[ "$(jq -r .user_rows <<<"$b")" == "10" ]] && pass "baseline save/load" || fail "baseline" "$b"

# check accumulator + tg format
rbv_checks_init "$T/checks.json"
# shellcheck disable=SC2034 # читает rbv_format_tg_report
RBV_BUCKET=b
rbv_check_add download ok "file.tar.gz"
rbv_check_add user_rows fail "меньше" "20" "15"
rbv_check_add isolation ok "internal"
body="$(rbv_format_tg_report s1 bot "bot:p/A:x" "pref/custom_bot_x.tar.gz" false)"
printf '%s\n' "$body" | grep -q 'Хранилище' && pass "tg has storage" || fail "tg storage" "missing"
printf '%s\n' "$body" | grep -q 'Путь' && pass "tg has path" || fail "tg path" "missing"
printf '%s\n' "$body" | grep -q 'user_rows' && pass "tg has check" || fail "tg check" "missing"
printf '%s\n' "$body" | grep -q 'Расхождения' && pass "tg has diffs" || fail "tg diffs" "missing"
printf '%s\n' "$body" | grep -q '✅\|❌\|⚠\|⚪' && pass "tg icons" || fail "tg icons" "missing"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
(( FAIL == 0 ))
