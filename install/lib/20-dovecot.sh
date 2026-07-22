# shellcheck shell=bash

info "Konfiguriere Dovecot als lokalen OIDC-zu-IMAP-Adapter"
USERINFO_URL="$(curl -fsSL --max-time 15 "$OIDC_DISCOVERY" | jq -er '.userinfo_endpoint')"
[[ "$USERINFO_URL" == https://* ]] || die "OIDC-Discovery enthält keinen gültigen userinfo_endpoint."
export USERINFO_URL

cat >/etc/dovecot/dovecot-oauth2.conf.ext <<EOF_OAUTH
introspection_mode = auth
introspection_url = ${USERINFO_URL}
username_attribute = email
username_format = %Lu
openid_configuration_url = ${OIDC_DISCOVERY}
tls_ca_cert_file = /etc/ssl/certs/ca-certificates.crt
timeout_msecs = 10000
max_parallel_connections = 20
max_pipelined_requests = 1
debug = no
EOF_OAUTH
chmod 0640 /etc/dovecot/dovecot-oauth2.conf.ext
chown root:dovecot /etc/dovecot/dovecot-oauth2.conf.ext

cat >/etc/dovecot/dovecot-sql.conf.ext <<EOF_SQL
 driver = mysql
 connect = host=127.0.0.1 dbname=sogo user=sogo_mailro password=${MAIL_DB_PASSWORD}
 user_query = SELECT 2000 AS uid, 2000 AS gid, CONCAT('/var/lib/sogo-mail/', LOWER(mail)) AS home, 'imapc:~/imapc' AS mail, imap_host AS imapc_host, imap_port AS imapc_port, 'imaps' AS imapc_ssl, 'yes' AS imapc_ssl_verify, imap_user AS imapc_user, CONVERT(AES_DECRYPT(imap_password, UNHEX('${AES_KEY_HEX}')) USING utf8mb4) AS imapc_password FROM sogo_users WHERE LOWER(mail) = LOWER('%u') AND enabled = 1
 iterate_query = SELECT mail AS username FROM sogo_users WHERE enabled = 1
EOF_SQL
sed -i 's/^ //' /etc/dovecot/dovecot-sql.conf.ext
chmod 0640 /etc/dovecot/dovecot-sql.conf.ext
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext

cat >/etc/dovecot/dovecot.conf <<EOF_DOVECOT
protocols = imap
listen = 127.0.0.1

ssl = no
disable_plaintext_auth = no
auth_mechanisms = xoauth2 oauthbearer
auth_username_format = %Lu
auth_verbose = no

mail_uid = vmail
mail_gid = vmail
first_valid_uid = 2000
last_valid_uid = 2000
mail_home = /var/lib/sogo-mail/%Lu
mail_location = imapc:~/imapc
mail_max_userip_connections = 30

imapc_host = ${IMAP_HOST}
imapc_port = ${IMAP_PORT}
imapc_ssl = imaps
imapc_ssl_verify = yes
imapc_sasl_mechanisms = plain login
imapc_features = delay-login
imapc_cmd_timeout = 60s
imapc_connection_retry_count = 3
imapc_connection_retry_interval = 2s
imapc_max_idle_time = 10m

namespace inbox {
  inbox = yes
  separator = /
  prefix =
}

passdb {
  driver = oauth2
  mechanisms = xoauth2 oauthbearer
  args = /etc/dovecot/dovecot-oauth2.conf.ext
}

userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}

service imap-login {
  inet_listener imap {
    address = 127.0.0.1
    port = 143
  }
  inet_listener imaps {
    port = 0
  }
}

service auth {
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
}

protocol imap {
  mail_plugins =
}
EOF_DOVECOT

doveconf -n >/dev/null
