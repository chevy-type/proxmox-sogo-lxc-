#!/usr/bin/env bash
# SOGo OIDC Webmail LXC installer for Proxmox VE
# Community-Scripts-inspired standalone installer

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_VERSION="0.1.0"
readonly DEBIAN_VERSION="12"
readonly REPOSITORY="${SOGO_REPOSITORY:-chevy-type/proxmox-sogo-lxc-}"
readonly REPOSITORY_REF="${SOGO_REPOSITORY_REF:-main}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${REPOSITORY_REF}"

WORKDIR="$(mktemp -d /tmp/sogo-lxc.XXXXXX)"
CREATED_CT=0
CTID=""

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  local line="${1:-unknown}"
  echo
  echo "FEHLER: Installation in Zeile ${line} abgebrochen (Exit ${exit_code})." >&2
  if [[ "$CREATED_CT" -eq 1 && -n "$CTID" ]]; then
    echo "Der LXC ${CTID} wurde zur Diagnose nicht gelöscht." >&2
    echo "Status:  pct status ${CTID}" >&2
    echo "Konsole: pct enter ${CTID}" >&2
  fi
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FEHLER]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Benötigter Befehl fehlt: $1"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

prompt_optional() {
  local prompt="$1"
  local default="${2:-}"
  local shown="${default:-leer}"
  local value
  read -r -p "${prompt} [${shown}; - = leer]: " value
  if [[ "$value" == "-" ]]; then
    printf ''
  else
    printf '%s' "${value:-$default}"
  fi
}

prompt_secret() {
  local prompt="$1"
  local value
  read -r -s -p "${prompt}: " value
  echo
  printf '%s' "$value"
}

validate_fqdn() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_ipv4_cidr() {
  local value="$1" ip octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  ip="${value%/*}"
  IFS='.' read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

validate_ipv4() {
  local value="$1" octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

validate_url() {
  [[ "$1" =~ ^https://[^[:space:]]+$ ]]
}

storage_default() {
  local content="$1"
  pvesm status -content "$content" 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1; exit}'
}

storage_supports() {
  local storage="$1" content="$2"
  pvesm status -content "$content" 2>/dev/null |
    awk 'NR > 1 {print $1}' |
    grep -Fxq "$storage"
}

put_b64() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(printf '%s' "$value" | base64 -w0)" >>"$WORKDIR/install.env"
}

fetch_installer_file() {
  local remote="$1" local_path="$2" expected actual
  curl -fsSL --retry 3 --connect-timeout 15 "${RAW_BASE}/${remote}" -o "$local_path"

  if [[ -r "${WORKDIR}/SHA256SUMS" ]]; then
    expected="$(awk -v path="./${remote}" '$2 == path {print $1; exit}' "${WORKDIR}/SHA256SUMS")"
    [[ -n "$expected" ]] || die "Keine Prüfsumme für ${remote} gefunden."
    actual="$(sha256sum "$local_path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "Prüfsummenfehler bei ${remote}."
  fi
}

echo
echo "============================================================"
echo " SOGo OIDC Webmail LXC Installer ${SCRIPT_VERSION}"
echo " Debian ${DEBIAN_VERSION} / SOGo 5 / Dovecot IMAP bridge"
echo "============================================================"
echo

[[ "$EUID" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
for cmd in pct pveam pvesm pvesh pveversion curl openssl awk grep sed base64 sha256sum; do
  require_cmd "$cmd"
done
pveversion >/dev/null 2>&1 || die "Dieses Skript muss auf einem Proxmox-VE-Host laufen."

NEXTID="$(pvesh get /cluster/nextid)"
TEMPLATE_STORAGE_DEFAULT="$(storage_default vztmpl)"
CT_STORAGE_DEFAULT="$(storage_default rootdir)"
[[ -n "$TEMPLATE_STORAGE_DEFAULT" ]] || die "Kein aktiver Storage für Container-Templates gefunden."
[[ -n "$CT_STORAGE_DEFAULT" ]] || die "Kein aktiver Storage für LXC-RootFS gefunden."

CTID="$(prompt_default "Container-ID" "$NEXTID")"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige Container-ID."
pct status "$CTID" >/dev/null 2>&1 && die "Container-ID ${CTID} ist bereits belegt."

while true; do
  FQDN="$(prompt_default "Öffentlicher SOGo-Hostname" "post.momenteschenker.de")"
  FQDN="${FQDN,,}"
  validate_fqdn "$FQDN" && break
  warn "Bitte einen vollständigen Hostnamen eingeben."
done

PUBLIC_URL="$(prompt_default "Öffentliche URL" "https://${FQDN}")"
PUBLIC_URL="${PUBLIC_URL%/}"
validate_url "$PUBLIC_URL" || die "Die öffentliche URL muss mit https:// beginnen."

while true; do
  IP_CIDR="$(prompt_default "Statische IPv4-Adresse mit CIDR" "192.168.178.61/24")"
  validate_ipv4_cidr "$IP_CIDR" && break
  warn "Beispiel: 192.168.178.61/24"
done

while true; do
  GATEWAY="$(prompt_default "IPv4-Gateway" "192.168.178.1")"
  validate_ipv4 "$GATEWAY" && break
  warn "Beispiel: 192.168.178.1"
done

NAMESERVER="$(prompt_default "DNS-Server des Containers" "$GATEWAY")"
validate_ipv4 "$NAMESERVER" || die "Ungültiger DNS-Server."

BRIDGE="$(prompt_default "Proxmox-Bridge" "vmbr0")"
TEMPLATE_STORAGE="$(prompt_default "Template-Storage" "$TEMPLATE_STORAGE_DEFAULT")"
CT_STORAGE="$(prompt_default "Container-Storage" "$CT_STORAGE_DEFAULT")"
CORES="$(prompt_default "CPU-Kerne" "2")"
RAM="$(prompt_default "RAM in MB" "3072")"
SWAP="$(prompt_default "Swap in MB" "1024")"
DISK="$(prompt_default "Root-Disk in GB" "12")"

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "Ungültige CPU-Anzahl."
[[ "$RAM" =~ ^[1-9][0-9]*$ ]] || die "Ungültiger RAM-Wert."
[[ "$SWAP" =~ ^[0-9]+$ ]] || die "Ungültiger Swap-Wert."
[[ "$DISK" =~ ^[1-9][0-9]*$ ]] || die "Ungültige Disk-Größe."
storage_supports "$TEMPLATE_STORAGE" vztmpl || die "Storage '${TEMPLATE_STORAGE}' unterstützt keine Templates."
storage_supports "$CT_STORAGE" rootdir || die "Storage '${CT_STORAGE}' unterstützt keine LXC-RootFS."

OIDC_DISCOVERY="$(prompt_default \
  "OIDC-Discovery-URL" \
  "https://anmeldung.momenteschenker.de/application/o/sogo/.well-known/openid-configuration")"
validate_url "$OIDC_DISCOVERY" || die "Ungültige OIDC-Discovery-URL."
OIDC_CLIENT_ID="$(prompt_default "OIDC Client-ID" "sogo")"
OIDC_CLIENT_SECRET="$(prompt_secret "OIDC Client-Secret")"
[[ -n "$OIDC_CLIENT_SECRET" ]] || die "Ein OIDC Client-Secret ist erforderlich."
OIDC_INTERNAL_IP="$(prompt_optional \
  "Interne IP für den OIDC-Host (bei Split-DNS/Hairpin)" \
  "192.168.178.190")"
[[ -z "$OIDC_INTERNAL_IP" ]] || validate_ipv4 "$OIDC_INTERNAL_IP" || die "Ungültige interne OIDC-IP."

while true; do
  FIRST_EMAIL="$(prompt_default "Erster Benutzer / E-Mail-Adresse" "bernd@momenteschenker.de")"
  FIRST_EMAIL="${FIRST_EMAIL,,}"
  validate_email "$FIRST_EMAIL" && break
  warn "Ungültige E-Mail-Adresse."
done
FIRST_NAME="$(prompt_default "Anzeigename des ersten Benutzers" "Bernd")"
MAIL_DOMAIN="${FIRST_EMAIL#*@}"

IMAP_HOST="$(prompt_default "IMAP-Server" "imap.ionos.de")"
IMAP_PORT="$(prompt_default "IMAP-Port" "993")"
IMAP_USER="$(prompt_default "IMAP-Benutzername" "$FIRST_EMAIL")"
IMAP_PASSWORD="$(prompt_secret "IMAP-Passwort")"
[[ -n "$IMAP_PASSWORD" ]] || die "Ein IMAP-Passwort ist erforderlich."

SMTP_HOST="$(prompt_default "SMTP-Server" "smtp.ionos.de")"
SMTP_PORT="$(prompt_default "SMTP-Port (aktuell nur 587/STARTTLS)" "587")"
SMTP_USER="$(prompt_default "SMTP-Benutzername" "$FIRST_EMAIL")"
SMTP_PASSWORD="$(prompt_secret "SMTP-Passwort (leer = gleich wie IMAP)")"
SMTP_PASSWORD="${SMTP_PASSWORD:-$IMAP_PASSWORD}"

[[ "$IMAP_PORT" =~ ^[0-9]+$ ]] || die "Ungültiger IMAP-Port."
[[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || die "Ungültiger SMTP-Port."
[[ "$SMTP_PORT" == "587" ]] || die "Diese Version unterstützt für den SMTP-Relay ausschließlich Port 587 mit STARTTLS."

echo
echo "Geplante Installation:"
echo "  CT-ID:          ${CTID}"
echo "  URL:            ${PUBLIC_URL}"
echo "  IP:             ${IP_CIDR}"
echo "  DNS:            ${NAMESERVER}"
echo "  Ressourcen:     ${CORES} CPU / ${RAM} MB RAM / ${DISK} GB"
echo "  Anmeldung:      OIDC über ${OIDC_DISCOVERY}"
echo "  Mail:           ${IMAP_HOST}:${IMAP_PORT} / ${SMTP_HOST}:${SMTP_PORT}"
echo "  Erster Benutzer:${FIRST_EMAIL}"
echo "  Eingehende Mail-Ports: keine"
echo "  SOGo-Pakete:    öffentlicher Nightly-Kanal"
echo
read -r -p "Jetzt installieren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || die "Abgebrochen."

info "Lade Prüfsummen und Installationsdateien"
curl -fsSL --retry 3 --connect-timeout 15 "${RAW_BASE}/SHA256SUMS" -o "$WORKDIR/SHA256SUMS"
fetch_installer_file "install/sogo-install.sh" "$WORKDIR/sogo-install.sh"
fetch_installer_file "install/sogo-mail-user.py" "$WORKDIR/sogo-mail-user.py"
fetch_installer_file "install/sogo-healthcheck.sh" "$WORKDIR/sogo-healthcheck.sh"
fetch_installer_file "install/sogo-lxc-update.sh" "$WORKDIR/sogo-lxc-update.sh"
mkdir -p "$WORKDIR/sogo-install.d"
for module in \
  00-packages.sh \
  10-database-users.sh \
  20-dovecot.sh \
  30-postfix.sh \
  40-sogo-nginx.sh \
  50-finalize.sh; do
  fetch_installer_file "install/lib/${module}" "$WORKDIR/sogo-install.d/${module}"
done
chmod 0700 "$WORKDIR"/*.sh "$WORKDIR"/*.py "$WORKDIR"/sogo-install.d/*.sh

info "Suche aktuelles Debian-${DEBIAN_VERSION}-Template"
pveam update >/dev/null
TEMPLATE_NAME="$(
  pveam available --section system |
    awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}' |
    sort -V |
    tail -n1
)"
[[ -n "$TEMPLATE_NAME" ]] || die "Kein Debian-12-amd64-Template gefunden."
TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

if ! pveam list "$TEMPLATE_STORAGE" | awk 'NR > 1 {print $1}' | grep -Fxq "$TEMPLATE_REF"; then
  info "Lade ${TEMPLATE_NAME}"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
  ok "Template bereits vorhanden: ${TEMPLATE_NAME}"
fi

info "Erstelle unprivilegierten LXC ${CTID}"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$FQDN" \
  --ostype debian \
  --arch amd64 \
  --unprivileged 1 \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap "$SWAP" \
  --rootfs "${CT_STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY},ip6=auto,type=veth" \
  --nameserver "$NAMESERVER" \
  --onboot 1 \
  --start 1
CREATED_CT=1

info "Warte auf Netzwerk und DNS im Container"
NETWORK_READY=0
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    NETWORK_READY=1
    break
  fi
  sleep 2
done
[[ "$NETWORK_READY" -eq 1 ]] || die "Netzwerk/DNS ist im LXC nicht erreichbar."

CONTAINER_IP="${IP_CIDR%/*}"
SHORT_HOST="${FQDN%%.*}"
OIDC_HOST="$(printf '%s\n' "$OIDC_DISCOVERY" | sed -E 's#^https://([^/:]+).*#\1#')"

cat >"$WORKDIR/hosts" <<EOF_HOSTS
127.0.0.1 localhost sogo-db
${CONTAINER_IP} ${FQDN} ${SHORT_HOST}
EOF_HOSTS
if [[ -n "$OIDC_INTERNAL_IP" ]]; then
  printf '%s %s\n' "$OIDC_INTERNAL_IP" "$OIDC_HOST" >>"$WORKDIR/hosts"
fi
cat >>"$WORKDIR/hosts" <<'EOF_HOSTS'

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF_HOSTS

printf '%s\n' "$FQDN" >"$WORKDIR/hostname"
pct push "$CTID" "$WORKDIR/hosts" /etc/hosts --perms 0644
pct push "$CTID" "$WORKDIR/hostname" /etc/hostname --perms 0644
pct exec "$CTID" -- hostname "$FQDN"

: >"$WORKDIR/install.env"
chmod 0600 "$WORKDIR/install.env"
put_b64 FQDN "$FQDN"
put_b64 PUBLIC_URL "$PUBLIC_URL"
put_b64 MAIL_DOMAIN "$MAIL_DOMAIN"
put_b64 OIDC_DISCOVERY "$OIDC_DISCOVERY"
put_b64 OIDC_CLIENT_ID "$OIDC_CLIENT_ID"
put_b64 OIDC_CLIENT_SECRET "$OIDC_CLIENT_SECRET"
put_b64 FIRST_EMAIL "$FIRST_EMAIL"
put_b64 FIRST_NAME "$FIRST_NAME"
put_b64 IMAP_HOST "$IMAP_HOST"
put_b64 IMAP_PORT "$IMAP_PORT"
put_b64 IMAP_USER "$IMAP_USER"
put_b64 IMAP_PASSWORD "$IMAP_PASSWORD"
put_b64 SMTP_HOST "$SMTP_HOST"
put_b64 SMTP_PORT "$SMTP_PORT"
put_b64 SMTP_USER "$SMTP_USER"
put_b64 SMTP_PASSWORD "$SMTP_PASSWORD"

pct push "$CTID" "$WORKDIR/install.env" /root/sogo-install.env --perms 0600
pct push "$CTID" "$WORKDIR/sogo-install.sh" /root/sogo-install.sh --perms 0700
pct push "$CTID" "$WORKDIR/sogo-mail-user.py" /root/sogo-mail-user.py --perms 0700
pct push "$CTID" "$WORKDIR/sogo-healthcheck.sh" /root/sogo-healthcheck.sh --perms 0700
pct push "$CTID" "$WORKDIR/sogo-lxc-update.sh" /root/sogo-lxc-update.sh --perms 0700
pct exec "$CTID" -- install -d -m 0700 /root/sogo-install.d
for module in "$WORKDIR"/sogo-install.d/*.sh; do
  pct push "$CTID" "$module" "/root/sogo-install.d/$(basename "$module")" --perms 0700
done

info "Installiere SOGo und die lokalen IMAP-/SMTP-Brücken"
pct exec "$CTID" -- bash /root/sogo-install.sh /root/sogo-install.env

ok "Installation abgeschlossen"
echo
echo "Nächste Schritte:"
echo "  1. Authentik Redirect-URI: ${PUBLIC_URL}/SOGo/"
echo "  2. Traefik auf http://${CONTAINER_IP}:80 routen"
echo "  3. SOGo öffnen: ${PUBLIC_URL}"
echo
echo "Benutzerverwaltung im Container:"
echo "  sogo-mail-user list"
echo "  sogo-mail-user add name@example.org"
echo "  sogo-mail-user test ${FIRST_EMAIL}"
echo
echo "Wichtig: Der öffentliche SOGo-Nightly-Kanal ist nicht der kostenpflichtige Release-Kanal."
