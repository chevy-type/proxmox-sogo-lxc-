# Proxmox SOGo LXC

Ein schlanker, Community-Scripts-inspirierter Installer für **SOGo als Webmail-Client** in einem unprivilegierten Proxmox-LXC.

Ziel ist ausdrücklich **kein eigener öffentlicher Mailserver**. SOGo zeigt vorhandene externe IMAP-Postfächer an und versendet über den SMTP-Server des jeweiligen Anbieters. Kalender und Kontakte bleiben lokal in SOGo.

> **Status:** experimentelle Version `0.1.0`. Der Installer wurde syntaktisch geprüft, benötigt aber noch einen vollständigen Praxistest auf einem frischen Proxmox-System.

## Architektur

```text
Browser
  │
  ├─ Authentik / OpenID Connect
  │
  ▼
SOGo
  ├─ Kalender und Kontakte ── MariaDB
  ├─ Mail lesen ── Dovecot IMAPC ── externer IMAP-Server
  └─ Mail senden ── lokaler Postfix ── externer SMTP-Server
```

Der lokale Dovecot- und Postfix-Dienst ist ausschließlich innerhalb des Containers erreichbar. Es werden keine Mailports über Traefik oder die FritzBox veröffentlicht.

## Enthaltene Komponenten

- Debian 12 LXC, unprivilegiert
- SOGo 5 mit Webmail, Kalender und Kontakten
- Authentik/OIDC-Anmeldung
- MariaDB für SOGo-Daten und Benutzerzuordnung
- Dovecot als lokale XOAUTH2-zu-IMAP-Brücke
- Postfix als ausschließlich lokal erreichbarer SMTP-Relay
- Nginx auf Port 80 als Backend für Traefik
- Benutzerverwaltung mit `sogo-mail-user`
- Diagnose mit `sogo-healthcheck`
- gesicherte Updates mit `sogo-lxc-update`

Nicht enthalten:

- iRedMail oder iRedAdmin
- Amavis, ClamAV oder SpamAssassin
- lokale Mailzustellung
- MX-, SPF-, DKIM- oder DMARC-Verwaltung
- öffentliche IMAP-, SMTP- oder Submission-Ports

## Installation

Auf dem Proxmox-Host als `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chevy-type/proxmox-sogo-lxc-/main/ct/sogo.sh)"
```

Der Installer fragt interaktiv unter anderem ab:

- LXC-ID, Speicher, IP-Adresse und DNS-Server
- öffentliche SOGo-Adresse
- OIDC-Discovery-URL, Client-ID und Client-Secret
- erstes Mailkonto
- IMAP- und SMTP-Zugangsdaten

Voreinstellungen sind auf das Momenteschenker-Setup und IONOS ausgelegt, lassen sich aber während der Installation ändern.

## Authentik

Vor der Installation einen OAuth2/OpenID-Provider anlegen:

- Client-Typ: `Confidential`
- Redirect-URI, exakt: `https://post.example.org/SOGo/`
- Scopes: `openid profile email offline_access`
- Subject mode: nach eigener Authentik-Konvention

Die E-Mail-Adresse des Authentik-Benutzers muss mit dem in `sogo-mail-user` angelegten Konto übereinstimmen.

Beispiel für Momenteschenker:

```text
Discovery URL:
https://anmeldung.momenteschenker.de/application/o/sogo/.well-known/openid-configuration

Redirect URI:
https://post.momenteschenker.de/SOGo/
```

Der Installer kann den OIDC-Host optional intern auf die Traefik-IP auflösen. Dadurch bleibt der Hostname mit gültigem TLS-Zertifikat erhalten, ohne dass der Container den öffentlichen Umweg nehmen muss.

## Traefik

Der Installer verändert Traefik bewusst nicht. Nach erfolgreicher interner Installation die Datei aus [`examples/traefik-sogo.yaml`](examples/traefik-sogo.yaml) an die eigene IP und den verwendeten Zertifikatsresolver anpassen und in die vorhandene dynamische Konfiguration übernehmen.

Das Backend verwendet normales HTTP:

```text
Traefik → http://SOGO-LXC-IP:80
```

Es sind keine Sonderregeln für iRedAdmin, `/mail` oder ein HTTPS-Backend nötig.

## Benutzer verwalten

Im SOGo-LXC:

```bash
sogo-mail-user list
sogo-mail-user add name@example.org
sogo-mail-user test name@example.org
sogo-mail-user disable name@example.org
sogo-mail-user enable name@example.org
sogo-mail-user remove name@example.org
```

`add` legt neue Benutzer an oder aktualisiert bestehende Benutzer. Passwörter werden verdeckt abgefragt.

### IONOS-Vorgaben

```text
IMAP: imap.ionos.de:993, TLS
SMTP: smtp.ionos.de:587, STARTTLS
Benutzername: vollständige E-Mail-Adresse
```

Version `0.1.0` unterstützt für den SMTP-Relay absichtlich nur Port `587` mit STARTTLS.

## Passwörter und Sicherheit

Die externen IMAP- und SMTP-Passwörter werden mit einem zufällig erzeugten AES-Schlüssel in MariaDB verschlüsselt. Dovecot und Postfix entschlüsseln sie lokal bei Bedarf. Der Schlüssel und die Datenbankzugänge befinden sich ausschließlich in root-lesbaren Konfigurationsdateien.

Wichtig:

- Ein vollständiges Container-Backup enthält zwangsläufig auch Schlüssel und verschlüsselte Zugangsdaten.
- `doveadm user <adresse>` kann Dovecot-Benutzerfelder einschließlich des entschlüsselten IMAP-Passworts anzeigen. Diesen Befehl nicht ungeschwärzt weitergeben.
- Der Container sollte nur über Traefik auf Port 80 erreichbar sein.
- Keine Ports 25, 143, 465, 587, 993 oder 4190 weiterleiten.

## Diagnose

```bash
sogo-healthcheck
sogo-healthcheck --user bernd@example.org
```

Die zweite Variante prüft zusätzlich die echte IMAP- und SMTP-Anmeldung, versendet aber keine Nachricht.

## Updates

Normale Debian-Aktualisierung, SOGo/SOPE bleiben wegen des Nightly-Kanals gehalten:

```bash
sogo-lxc-update
```

Explizites SOGo-/SOPE-Update mit vorherigem Backup:

```bash
sogo-lxc-update --sogo
```

Sicherungen landen unter:

```text
/var/backups/sogo-lxc/
```

## Warum der Nightly-Kanal?

Die frei zugänglichen Debian-Pakete von SOGo werden über den öffentlichen Nightly-Kanal angeboten. Der offizielle Production-/Release-Kanal erfordert Zugangsdaten aus einem Alinto-Supportvertrag. Deshalb hält der Installer SOGo und SOPE nach der Installation standardmäßig fest.

## Bekannte Grenzen

- Noch kein vollständiger End-to-End-Praxistest des Installers.
- SMTP ist aktuell auf Port 587/STARTTLS begrenzt.
- Externe CalDAV-/CardDAV-Apps erhalten durch diese OIDC-only-Konfiguration nicht automatisch ein Basic-Auth-Passwort. Kalender und Kontakte sind zunächst für die SOGo-Weboberfläche vorgesehen.
- Passwortänderungen beim Mailanbieter müssen mit `sogo-mail-user add <adresse>` erneut hinterlegt werden.
- Anbieter mit ungewöhnlichen IMAP-Namensräumen oder SMTP-Verfahren können zusätzliche Anpassungen benötigen.

## Lizenz

MIT – siehe [`LICENSE`](LICENSE).
