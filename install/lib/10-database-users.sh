# shellcheck shell=bash

info "Erstelle SOGo-Datenbank und verschlüsselte Mailkonten-Tabelle"
mariadb --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS sogo
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'sogo_app'@'127.0.0.1' IDENTIFIED BY '${SOGO_DB_PASSWORD}';
ALTER USER 'sogo_app'@'127.0.0.1' IDENTIFIED BY '${SOGO_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON sogo.* TO 'sogo_app'@'127.0.0.1';

CREATE USER IF NOT EXISTS 'sogo_mailro'@'127.0.0.1' IDENTIFIED BY '${MAIL_DB_PASSWORD}';
ALTER USER 'sogo_mailro'@'127.0.0.1' IDENTIFIED BY '${MAIL_DB_PASSWORD}';

CREATE TABLE IF NOT EXISTS sogo.sogo_users (
  c_uid         VARCHAR(255) NOT NULL,
  c_name        VARCHAR(255) NOT NULL,
  c_password    VARCHAR(255) NOT NULL,
  c_cn          VARCHAR(255) NOT NULL,
  mail          VARCHAR(255) NOT NULL,
  imap_host     VARCHAR(255) NOT NULL,
  imap_port     INT UNSIGNED NOT NULL DEFAULT 993,
  imap_user     VARCHAR(255) NOT NULL,
  imap_password VARBINARY(2048) NOT NULL,
  smtp_host     VARCHAR(255) NOT NULL,
  smtp_port     INT UNSIGNED NOT NULL DEFAULT 587,
  smtp_user     VARCHAR(255) NOT NULL,
  smtp_password VARBINARY(2048) NOT NULL,
  enabled       TINYINT(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (c_uid),
  UNIQUE KEY uq_sogo_users_name (c_name),
  UNIQUE KEY uq_sogo_users_mail (mail)
) ENGINE=InnoDB;

GRANT SELECT ON sogo.sogo_users TO 'sogo_mailro'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

info "Installiere Benutzerverwaltung"
install -m 0750 -o root -g root /root/sogo-mail-user.py /usr/local/sbin/sogo-mail-user
python3 - <<'PY'
import json
import os
from pathlib import Path

config = {
    "db_host": "127.0.0.1",
    "database": "sogo",
    "db_user": "sogo_app",
    "db_password": os.environ["SOGO_DB_PASSWORD"],
    "aes_key_hex": os.environ["AES_KEY_HEX"],
    "defaults": {
        "imap_host": os.environ["IMAP_HOST"],
        "imap_port": int(os.environ["IMAP_PORT"]),
        "smtp_host": os.environ["SMTP_HOST"],
        "smtp_port": int(os.environ["SMTP_PORT"]),
    },
}
path = Path("/etc/sogo-mail/config.json")
path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY

printf '%s\n%s\n' "$IMAP_PASSWORD" "$SMTP_PASSWORD" >/root/first-user-passwords
chmod 0600 /root/first-user-passwords
/usr/local/sbin/sogo-mail-user add "$FIRST_EMAIL" \
  --display-name "$FIRST_NAME" \
  --imap-host "$IMAP_HOST" \
  --imap-port "$IMAP_PORT" \
  --imap-user "$IMAP_USER" \
  --smtp-host "$SMTP_HOST" \
  --smtp-port "$SMTP_PORT" \
  --smtp-user "$SMTP_USER" \
  --password-stdin \
  --non-interactive </root/first-user-passwords
shred -u /root/first-user-passwords 2>/dev/null || rm -f /root/first-user-passwords

info "Prüfe die externen Mail-Zugangsdaten"
/usr/local/sbin/sogo-mail-user test "$FIRST_EMAIL"
