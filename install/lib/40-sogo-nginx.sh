# shellcheck shell=bash

info "Konfiguriere SOGo für OIDC, Kalender, Kontakte und Webmail"
python3 - <<'PY'
import json
import os
from pathlib import Path

q = json.dumps
public_url = os.environ["PUBLIC_URL"]
mail_domain = os.environ["MAIL_DOMAIN"]
first_email = os.environ["FIRST_EMAIL"]
db_password = os.environ["SOGO_DB_PASSWORD"]
db_base = f"mysql://sogo_app:{db_password}@sogo-db:3306/sogo"

content = f"""{{
  WOPort = "127.0.0.1:20000";
  WOWorkersCount = 5;
  WOListenQueueSize = 20;
  WOWatchDogRequestTimeout = 10;
  SxVMemLimit = 512;

  SOGoMemcachedHost = "127.0.0.1";
  SOGoTimeZone = "Europe/Berlin";
  SOGoLanguage = German;
  SOGoLoginModule = Mail;
  SOGoPageTitle = "Momenteschenker";
  SOGoSuperUsernames = ({q(first_email)});

  OCSFolderInfoURL = {q(db_base + '/sogo_folder_info')};
  OCSSessionsFolderURL = {q(db_base + '/sogo_sessions_folder')};
  OCSCacheFolderURL = {q(db_base + '/sogo_cache_folder')};
  SOGoProfileURL = {q(db_base + '/sogo_user_profile')};
  OCSEMailAlarmsFolderURL = {q(db_base + '/sogo_alarms_folder')};
  OCSOpenIdURL = {q(db_base + '/sogo_openid')};

  SOGoUserSources = (
    {{
      type = sql;
      id = users;
      viewURL = {q(db_base + '/sogo_users')};
      canAuthenticate = YES;
      isAddressBook = YES;
      displayName = "Momenteschenker";
      UIDFieldName = c_uid;
      IDFieldName = c_name;
      CNFieldName = c_cn;
      MailFieldNames = (mail);
    }}
  );

  SOGoAuthenticationType = openid;
  SOGoOpenIdConfigUrl = {q(os.environ['OIDC_DISCOVERY'])};
  SOGoOpenIdClient = {q(os.environ['OIDC_CLIENT_ID'])};
  SOGoOpenIdClientSecret = {q(os.environ['OIDC_CLIENT_SECRET'])};
  SOGoOpenIdScope = "openid profile email offline_access";
  SOGoOpenIdEmailParam = email;
  SOGoOpenIdEnableRefreshToken = YES;
  SOGoOpenIdTokenCheckInterval = 60;
  SOGoOpenIdLogoutEnabled = YES;

  SOGoMailDomain = {q(mail_domain)};
  SOGoEnableDomainBasedUID = NO;
  SOGoForceExternalLoginWithEmail = YES;
  SOGoPasswordChangeEnabled = NO;
  SOGoMailAuxiliaryUserAccountsEnabled = NO;

  SOGoIMAPServer = "imap://127.0.0.1:143";
  NGImap4AuthMechanism = xoauth2;

  SOGoMailingMechanism = smtp;
  SOGoSMTPServer = "smtp://127.0.0.1:25";

  SOGoSieveScriptsEnabled = NO;
  SOGoVacationEnabled = NO;
  SOGoForwardEnabled = NO;

  SOGoAppointmentSendEMailNotifications = YES;
  SOGoACLsSendEMailNotifications = YES;
  SOGoFoldersSendEMailNotifications = YES;
  SOGoDebugRequests = NO;
  ImapDebugEnabled = NO;
  MySQL4DebugEnabled = NO;
}}
"""

path = Path("/etc/sogo/sogo.conf")
path.write_text(content, encoding="utf-8")
path.chmod(0o640)
PY
chown root:sogo /etc/sogo/sogo.conf

if grep -q '^PREFORK=' /etc/default/sogo 2>/dev/null; then
  sed -i 's/^PREFORK=.*/PREFORK=5/' /etc/default/sogo
else
  printf '\nPREFORK=5\n' >>/etc/default/sogo
fi

info "Konfiguriere Nginx als internen HTTP-Frontendserver"
rm -f /etc/nginx/sites-enabled/default
cat >/etc/nginx/sites-available/sogo <<EOF_NGINX
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name ${FQDN};

  client_max_body_size 50m;

  location = / {
    return 302 /SOGo/;
  }

  location = /.well-known/caldav {
    return 301 /SOGo/dav;
  }

  location = /.well-known/carddav {
    return 301 /SOGo/dav;
  }

  location ^~ /SOGo.woa/WebServerResources/ {
    alias /usr/lib/GNUstep/SOGo/WebServerResources/;
    expires 1y;
    access_log off;
  }

  location ^~ /SOGo/WebServerResources/ {
    alias /usr/lib/GNUstep/SOGo/WebServerResources/;
    expires 1y;
    access_log off;
  }

  location /SOGo {
    proxy_pass http://127.0.0.1:20000;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header x-webobjects-server-port 443;
    proxy_set_header x-webobjects-server-name ${FQDN};
    proxy_set_header x-webobjects-server-url ${PUBLIC_URL};
    proxy_set_header x-webobjects-server-protocol HTTP/1.0;
    proxy_set_header x-webobjects-remote-user "";
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_buffering off;
  }
}
EOF_NGINX
ln -sfn /etc/nginx/sites-available/sogo /etc/nginx/sites-enabled/sogo
nginx -t
