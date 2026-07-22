#!/usr/bin/env bash
set -Eeuo pipefail

UPDATE_SOGO=0
if [[ "${1:-}" == "--sogo" ]]; then
  UPDATE_SOGO=1
elif [[ $# -gt 0 ]]; then
  echo "Verwendung: sogo-lxc-update [--sogo]" >&2
  exit 2
fi

[[ "$EUID" -eq 0 ]] || { echo "Bitte als root ausführen." >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/sogo-lxc/${STAMP}"
HELD_FILE="/etc/sogo-mail/held-packages"
install -d -m 0700 "$BACKUP_DIR"

echo "Erstelle Sicherung unter ${BACKUP_DIR}"
tar -C / -czf "${BACKUP_DIR}/config.tar.gz" \
  etc/sogo \
  etc/sogo-mail \
  etc/dovecot \
  etc/postfix \
  etc/nginx/sites-available/sogo \
  etc/nginx/sites-enabled/sogo
mariadb-dump --single-transaction --routines --events sogo | gzip >"${BACKUP_DIR}/sogo.sql.gz"

export DEBIAN_FRONTEND=noninteractive
apt-get update

if (( UPDATE_SOGO == 1 )); then
  echo "Aktualisiere Debian einschließlich SOGo/SOPE aus dem Nightly-Kanal."
  if [[ -s "$HELD_FILE" ]]; then
    xargs -r apt-mark unhold <"$HELD_FILE" >/dev/null || true
  fi
  apt-get -y full-upgrade
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
    awk '$1 ~ /^(sogo|sope)/ {print $1}' |
    sort -u >"$HELD_FILE"
  xargs -r apt-mark hold <"$HELD_FILE" >/dev/null || true
else
  echo "Aktualisiere Debian; SOGo/SOPE bleiben gehalten."
  apt-get -y full-upgrade
fi

systemctl restart mariadb memcached dovecot postfix nginx sogo
sleep 5
sogo-healthcheck

echo "Update abgeschlossen. Sicherung: ${BACKUP_DIR}"
