# shellcheck shell=bash

info "Installiere Wartungs- und Diagnosebefehle"
install -m 0750 -o root -g root /root/sogo-healthcheck.sh /usr/local/sbin/sogo-healthcheck
install -m 0750 -o root -g root /root/sogo-lxc-update.sh /usr/local/sbin/sogo-lxc-update

cat >/etc/sogo-mail/installation.json <<EOF_INSTALL
{
  "version": "0.1.0",
  "fqdn": "${FQDN}",
  "public_url": "${PUBLIC_URL}",
  "oidc_discovery": "${OIDC_DISCOVERY}",
  "first_user": "${FIRST_EMAIL}"
}
EOF_INSTALL
chmod 0600 /etc/sogo-mail/installation.json

info "Aktiviere und starte die Dienste"
systemctl enable mariadb memcached dovecot postfix nginx sogo
systemctl restart mariadb
systemctl restart memcached
systemctl restart dovecot
systemctl restart postfix
systemctl restart nginx
systemctl restart sogo
sleep 8

for service in mariadb memcached dovecot postfix nginx sogo; do
  systemctl is-active --quiet "$service" || {
    systemctl --no-pager --full status "$service" || true
    die "Dienst ist nicht aktiv: $service"
  }
done

curl -fsS --max-time 15 -o /dev/null http://127.0.0.1/SOGo/ || die "Lokaler SOGo-HTTP-Test fehlgeschlagen."

info "Schütze SOGo/SOPE vor unbeabsichtigten Nightly-Updates"
dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
  awk '$1 ~ /^(sogo|sope)/ {print $1}' |
  sort -u >/etc/sogo-mail/held-packages
if [[ -s /etc/sogo-mail/held-packages ]]; then
  xargs -r apt-mark hold </etc/sogo-mail/held-packages >/dev/null
fi

rm -f "$ENV_FILE" /root/sogo-install.sh /root/sogo-mail-user.py /root/sogo-healthcheck.sh /root/sogo-lxc-update.sh
rm -rf /root/sogo-install.d
unset IMAP_PASSWORD SMTP_PASSWORD OIDC_CLIENT_SECRET SOGO_DB_PASSWORD MAIL_DB_PASSWORD AES_KEY_HEX

ok "SOGo ist intern unter http://$(hostname -I | awk '{print $1}'):80 erreichbar."
ok "OIDC Redirect-URI: ${PUBLIC_URL}/SOGo/"
ok "Erster Benutzer: ${FIRST_EMAIL}"
