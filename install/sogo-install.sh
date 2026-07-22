#!/usr/bin/env bash
# Runs inside the freshly created Debian LXC.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

ENV_FILE="${1:-/root/sogo-install.env}"
[[ -r "$ENV_FILE" ]] || { echo "FEHLER: Installationsparameter fehlen: $ENV_FILE" >&2; exit 1; }

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

load_env() {
  local key encoded value
  while IFS='=' read -r key encoded; do
    [[ -n "$key" ]] || continue
    case "$key" in
      FQDN|PUBLIC_URL|MAIL_DOMAIN|OIDC_DISCOVERY|OIDC_CLIENT_ID|OIDC_CLIENT_SECRET|FIRST_EMAIL|FIRST_NAME|IMAP_HOST|IMAP_PORT|IMAP_USER|IMAP_PASSWORD|SMTP_HOST|SMTP_PORT|SMTP_USER|SMTP_PASSWORD)
        value="$(printf '%s' "$encoded" | base64 -d)"
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *) die "Unbekannter Installationsparameter: $key" ;;
    esac
  done <"$ENV_FILE"
}

load_env
for required in FQDN PUBLIC_URL MAIL_DOMAIN OIDC_DISCOVERY OIDC_CLIENT_ID OIDC_CLIENT_SECRET FIRST_EMAIL FIRST_NAME IMAP_HOST IMAP_PORT IMAP_USER IMAP_PASSWORD SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD; do
  [[ -n "${!required:-}" ]] || die "Installationsparameter fehlt: $required"
done
[[ "$SMTP_PORT" == "587" ]] || die "Diese Version unterstützt für den SMTP-Relay ausschließlich Port 587 mit STARTTLS."

umask 077
export DEBIAN_FRONTEND=noninteractive

INSTALL_LIB_DIR="/root/sogo-install.d"
for module in \
  00-packages.sh \
  10-database-users.sh \
  20-dovecot.sh \
  30-postfix.sh \
  40-sogo-nginx.sh \
  50-finalize.sh; do
  [[ -r "${INSTALL_LIB_DIR}/${module}" ]] || die "Installationsmodul fehlt: ${module}"
  # shellcheck source=/dev/null
  source "${INSTALL_LIB_DIR}/${module}"
done
