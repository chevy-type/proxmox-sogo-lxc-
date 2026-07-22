#!/usr/bin/env bash
set -Eeuo pipefail

USER_EMAIL=""
if [[ "${1:-}" == "--user" ]]; then
  USER_EMAIL="${2:-}"
fi

failures=0
check() {
  local label="$1"
  shift
  printf '%-38s ' "$label"
  if "$@" >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FEHLER"
    failures=$((failures + 1))
  fi
}

[[ "$EUID" -eq 0 ]] || { echo "Bitte als root ausführen." >&2; exit 1; }

INSTALL_JSON="/etc/sogo-mail/installation.json"
[[ -r "$INSTALL_JSON" ]] || { echo "Installationseintrag fehlt: $INSTALL_JSON" >&2; exit 1; }

OIDC_DISCOVERY="$(jq -r '.oidc_discovery' "$INSTALL_JSON")"

for service in mariadb memcached dovecot postfix nginx sogo; do
  check "Dienst ${service}" systemctl is-active --quiet "$service"
done

check "OIDC Discovery" curl -fsS --max-time 10 "$OIDC_DISCOVERY"
check "SOGo lokal" curl -fsS --max-time 10 http://127.0.0.1/SOGo/
check "Dovecot-Konfiguration" doveconf -n
check "Postfix-Konfiguration" postfix check
check "Nginx-Konfiguration" nginx -t

while read -r host; do
  [[ -n "$host" ]] || continue
  check "DNS ${host}" getent ahostsv4 "$host"
done < <(
  mariadb --batch --skip-column-names sogo -e \
    "SELECT DISTINCT imap_host FROM sogo_users WHERE enabled=1 UNION SELECT DISTINCT smtp_host FROM sogo_users WHERE enabled=1;" \
    2>/dev/null || true
)

if [[ -n "$USER_EMAIL" ]]; then
  echo
  if ! sogo-mail-user test "$USER_EMAIL"; then
    failures=$((failures + 1))
  fi
fi

echo
if (( failures == 0 )); then
  echo "Alle Prüfungen erfolgreich."
  exit 0
fi

echo "${failures} Prüfung(en) fehlgeschlagen." >&2
exit 1
