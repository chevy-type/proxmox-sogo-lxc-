# shellcheck shell=bash

info "Aktualisiere Debian und installiere Basispakete"
echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
echo "postfix postfix/mailname string ${FQDN}" | debconf-set-selections
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg jq openssl \
  mariadb-server default-mysql-client \
  memcached nginx \
  dovecot-core dovecot-imapd dovecot-mysql \
  postfix postfix-mysql libsasl2-modules \
  python3 python3-pymysql \
  logrotate

info "Richte den öffentlichen SOGo-Nightly-Paketkanal ein"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 \
  "https://keys.openpgp.org/vks/v1/by-fingerprint/74FFC6D72B925A34B5D356BDF8A27B36A6E2EAE9" \
  -o /etc/apt/keyrings/sogo.asc
chmod 0644 /etc/apt/keyrings/sogo.asc
cat >/etc/apt/sources.list.d/sogo.list <<'EOF_REPO'
deb [arch=amd64 signed-by=/etc/apt/keyrings/sogo.asc] https://packages.sogo.nu/nightly/5/debian/ bookworm bookworm
EOF_REPO
apt-get update
apt-get install -y sogo

SOPE_MYSQL_PKG="$(
  apt-cache search 'gdl1.*mysql\|mysql.*gdl1' |
    awk '/^sope|^libsope/ {print $1; exit}'
)"
if [[ -n "$SOPE_MYSQL_PKG" ]]; then
  apt-get install -y "$SOPE_MYSQL_PKG"
else
  warn "Kein separates SOPE-MySQL-Adapterpaket gefunden; prüfe, ob es bereits als Abhängigkeit installiert wurde."
fi

info "Erzeuge lokale Dienstkonten und Geheimnisse"
getent group vmail >/dev/null || groupadd --gid 2000 vmail
id -u vmail >/dev/null 2>&1 || useradd \
  --uid 2000 \
  --gid vmail \
  --home-dir /var/lib/sogo-mail \
  --shell /usr/sbin/nologin \
  --create-home \
  vmail
install -d -o vmail -g vmail -m 0750 /var/lib/sogo-mail
install -d -o root -g root -m 0700 /etc/sogo-mail

SOGO_DB_PASSWORD="$(openssl rand -hex 24)"
MAIL_DB_PASSWORD="$(openssl rand -hex 24)"
AES_KEY_HEX="$(openssl rand -hex 32)"
export SOGO_DB_PASSWORD MAIL_DB_PASSWORD AES_KEY_HEX

systemctl enable --now mariadb
