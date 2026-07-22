# shellcheck shell=bash

info "Konfiguriere Postfix als nur lokal erreichbaren SMTP-Relay"
cat >/etc/postfix/momente-relay.cf <<EOF_RELAY
user = sogo_mailro
password = ${MAIL_DB_PASSWORD}
hosts = 127.0.0.1
dbname = sogo
query = SELECT CONCAT('[', smtp_host, ']:', smtp_port) FROM sogo_users WHERE LOWER(mail) = LOWER('%s') AND enabled = 1
EOF_RELAY

cat >/etc/postfix/momente-sasl.cf <<EOF_SASL
user = sogo_mailro
password = ${MAIL_DB_PASSWORD}
hosts = 127.0.0.1
dbname = sogo
query = SELECT CONCAT(smtp_user, ':', CONVERT(AES_DECRYPT(smtp_password, UNHEX('${AES_KEY_HEX}')) USING utf8mb4)) FROM sogo_users WHERE LOWER(mail) = LOWER('%s') AND enabled = 1
EOF_SASL

cat >/etc/postfix/momente-sender.cf <<EOF_SENDER
user = sogo_mailro
password = ${MAIL_DB_PASSWORD}
hosts = 127.0.0.1
dbname = sogo
query = SELECT 'OK' FROM sogo_users WHERE LOWER(mail) = LOWER('%s') AND enabled = 1
EOF_SENDER
chmod 0640 /etc/postfix/momente-relay.cf /etc/postfix/momente-sasl.cf /etc/postfix/momente-sender.cf
chown root:postfix /etc/postfix/momente-relay.cf /etc/postfix/momente-sasl.cf /etc/postfix/momente-sender.cf

postconf -e "myhostname = ${FQDN}"
postconf -e "myorigin = \$myhostname"
postconf -e "mydestination = localhost"
postconf -e "inet_interfaces = loopback-only"
postconf -e "inet_protocols = ipv4"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "smtpd_relay_restrictions = permit_mynetworks,reject"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,reject"
postconf -e "smtpd_sender_restrictions = check_sender_access mysql:/etc/postfix/momente-sender.cf,reject"
postconf -e "sender_dependent_relayhost_maps = mysql:/etc/postfix/momente-relay.cf"
postconf -e "smtp_sender_dependent_authentication = yes"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = mysql:/etc/postfix/momente-sasl.cf"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_sasl_tls_security_options = noanonymous"
postconf -e "smtp_sasl_mechanism_filter = plain,login"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtp_tls_loglevel = 0"
postconf -e "relayhost ="
postfix check

SENDER_TEST="$(postmap -q "$FIRST_EMAIL" mysql:/etc/postfix/momente-sender.cf)"
[[ "$SENDER_TEST" == "OK" ]] || die "Postfix-Sender-Lookup ist fehlgeschlagen."
RELAY_TEST="$(postmap -q "$FIRST_EMAIL" mysql:/etc/postfix/momente-relay.cf)"
[[ "$RELAY_TEST" == "[${SMTP_HOST}]:${SMTP_PORT}" ]] || die "Postfix-Relay-Lookup ist fehlgeschlagen."
SASL_TEST="$(postmap -q "$FIRST_EMAIL" mysql:/etc/postfix/momente-sasl.cf)"
[[ -n "$SASL_TEST" ]] || die "Postfix-SASL-Lookup ist fehlgeschlagen."
unset SASL_TEST
