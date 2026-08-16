#!/usr/bin/env bash
# Установка rw-backup-verify на отдельный сервер (root).
set -euo pipefail
[[ ${EUID:-0} -eq 0 ]] || { echo "Нужен root"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/rw-backup-verify}"
CONFIG_DIR="${CONFIG_DIR:-/etc/rw-backup-verify}"
STATE_DIR="${STATE_DIR:-/var/lib/rw-backup-verify}"

echo "[*] Установка в ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"/{queue,runs,locks,cache}

# --- зависимости -----------------------------------------------------------
# install.sh не управляет пакетами хоста, но явно проверяет их наличие
missing=""
for cmd in jq rsync docker tar gzip curl aws; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=" $cmd"
done
if [[ -n "$missing" ]]; then
  echo "[WARN] Не найдены зависимости:${missing}" >&2
  echo "       Установите перед использованием, например:" >&2
  echo "       Debian/Ubuntu: apt-get install -y jq rsync docker.io tar gzip curl unzip" >&2
  echo "       awscli: curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install" >&2
  echo "       age (только если бэкапы .age): https://github.com/FiloSottile/age/releases" >&2
  # не прерываем установку — возможно, зависимости ставятся иначе
fi

rsync -a --delete \
  --exclude '.git' --exclude 'test' --exclude '*.md' \
  "$ROOT/bin" "$ROOT/lib" "$ROOT/config" "$ROOT/systemd" \
  "$INSTALL_DIR/" 2>/dev/null || {
  mkdir -p "$INSTALL_DIR"/{bin,lib,config,systemd}
  cp -a "$ROOT/bin/." "$INSTALL_DIR/bin/"
  cp -a "$ROOT/lib/." "$INSTALL_DIR/lib/"
  cp -a "$ROOT/config/." "$INSTALL_DIR/config/"
  cp -a "$ROOT/systemd/." "$INSTALL_DIR/systemd/"
}

chmod 755 "$INSTALL_DIR/bin/"*.sh "$INSTALL_DIR/bin/rw-backup-verify" 2>/dev/null || true
chmod 755 "$INSTALL_DIR/bin/rw-backup-verify"

ln -sfn "$INSTALL_DIR/bin/rw-backup-verify" /usr/local/bin/rw-backup-verify

if [[ ! -f "${CONFIG_DIR}/config.json" ]]; then
  cp "$INSTALL_DIR/config/config.example.json" "${CONFIG_DIR}/config.json"
  # подставить work_dir
  tmp="$(mktemp)"
  jq --arg w "$STATE_DIR" '.work_dir=$w' "${CONFIG_DIR}/config.json" > "$tmp"
  mv "$tmp" "${CONFIG_DIR}/config.json"
  chmod 600 "${CONFIG_DIR}/config.json"
  echo "[OK] Конфиг: ${CONFIG_DIR}/config.json"
else
  echo "[i] Конфиг уже есть — не трогаю"
fi

# systemd
cp "$INSTALL_DIR/systemd/rw-backup-verify.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/rw-backup-verify.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now rw-backup-verify.timer

echo
echo "[OK] Готово."
echo "  1) rw-backup-verify storage add --id ... --bucket ... --access-key ... --secret-key ..."
echo "  2) rw-backup-verify schedule set --interval-hours 12   # или --times 06:30,18:30"
echo "  3) rw-backup-verify telegram set --token ... --chat-id ..."
echo "  4) rw-backup-verify discover <id> && rw-backup-verify run --storage <id>"
echo "  Timer: systemctl status rw-backup-verify.timer"
