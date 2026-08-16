#!/usr/bin/env bash
# Очередь: каждый .job = один экземпляр (latest untested archive).
# Выполняются строго по одному (FIFO).
set -euo pipefail
_self="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

rbv_load_config
WD="$(rbv_work_dir)"
QD="$(rbv_queue_dir)"

if ! rbv_queue_lock; then
  msg INFO "Воркер уже работает — выход"
  exit 0
fi

shopt -s nullglob
jobs=("$QD"/*.job)
if [[ ${#jobs[@]} -eq 0 ]]; then
  msg INFO "Очередь пуста — нечего выполнять (${QD})"
  exit 0
fi

msg INFO "Worker: задач в очереди = ${#jobs[@]}"
mapfile -t sorted < <(printf '%s\n' "${jobs[@]}" | sort)

local_i=0
for job in "${sorted[@]}"; do
  [[ -f "$job" ]] || continue
  local_i=$((local_i + 1))
  sid="$(jq -r '.storage' "$job")"
  kind="$(jq -r '.kind' "$job")"
  inst="$(jq -r '.instance' "$job")"
  key="$(jq -r '.key' "$job")"
  parent="$(jq -r '.parent // empty' "$job")"
  reason="$(jq -r '.reason // "queue"' "$job")"
  msg INFO "=== [${local_i}/${#sorted[@]}] job $(basename "$job") ${sid} ${kind} ${inst} ==="
  msg INFO "key=${key} reason=${reason}"

  # ключ в S3 может быть с prefix; rbv-run-one ждёт полный key относительно bucket
  set +e
  "${SCRIPT_DIR}/rbv-run-one.sh" "$sid" "$kind" "$inst" "$key" "$parent" "$reason"
  rc=$?
  set -e
  ok_json=false
  (( rc == 0 )) && ok_json=true
  run_id="$(ls -1dt "${WD}/runs/"* 2>/dev/null | head -n1 | xargs -r basename || true)"
  # rc=75 / .retryable — временный сбой (диск): не жжём tested, чтобы retry взял тот же key
  if (( rc == 75 )) || [[ -n "$run_id" && -f "${WD}/runs/${run_id}/.retryable" ]]; then
    msg WARN "← rc=${rc} RETRYABLE (не в tested) run_id=${run_id:-?}  (отчёт: ${WD}/runs/${run_id:-})"
  else
    rbv_mark_tested "$sid" "$key" "$ok_json" "${run_id:-}"
    msg INFO "← rc=${rc} marked tested run_id=${run_id:-?}  (отчёт: ${WD}/runs/${run_id:-})"
  fi
  rm -f "$job"
done

msg OK "Очередь пуста"
rbv_queue_unlock
exit 0
