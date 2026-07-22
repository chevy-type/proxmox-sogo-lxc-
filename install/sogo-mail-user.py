#!/usr/bin/env python3
"""Manage SOGo users and their external IMAP/SMTP credentials."""

from __future__ import annotations

import argparse
import getpass
import imaplib
import json
import re
import smtplib
import ssl
import sys
from pathlib import Path
from typing import Any

import pymysql
from pymysql.cursors import DictCursor

CONFIG_PATH = Path("/etc/sogo-mail/config.json")
EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")


class UserError(RuntimeError):
    pass


def load_config() -> dict[str, Any]:
    try:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise UserError(f"Konfiguration fehlt: {CONFIG_PATH}") from exc
    except json.JSONDecodeError as exc:
        raise UserError(f"Ungültige Konfiguration: {exc}") from exc

    required = {"database", "db_user", "db_password", "aes_key_hex", "defaults"}
    missing = required.difference(config)
    if missing:
        raise UserError(f"Konfiguration unvollständig: {', '.join(sorted(missing))}")
    return config


def connect(config: dict[str, Any]) -> pymysql.Connection:
    return pymysql.connect(
        host=config.get("db_host", "127.0.0.1"),
        user=config["db_user"],
        password=config["db_password"],
        database=config["database"],
        charset="utf8mb4",
        autocommit=True,
        cursorclass=DictCursor,
        connect_timeout=10,
    )


def normalize_email(value: str) -> str:
    value = value.strip().lower()
    if not EMAIL_RE.fullmatch(value):
        raise UserError(f"Ungültige E-Mail-Adresse: {value}")
    return value


def validate_host(value: str, label: str) -> str:
    value = value.strip().lower()
    if not HOST_RE.fullmatch(value):
        raise UserError(f"Ungültiger {label}: {value}")
    return value


def validate_port(value: int, label: str) -> int:
    if not 1 <= value <= 65535:
        raise UserError(f"Ungültiger {label}: {value}")
    return value


def prompt_default(prompt: str, default: str) -> str:
    value = input(f"{prompt} [{default}]: ").strip()
    return value or default


def read_passwords(args: argparse.Namespace) -> tuple[str, str]:
    if args.password_stdin:
        imap_password = sys.stdin.readline().rstrip("\r\n")
        smtp_password = sys.stdin.readline().rstrip("\r\n")
        smtp_password = smtp_password or imap_password
    else:
        imap_password = getpass.getpass("IMAP-Passwort: ")
        smtp_password = getpass.getpass("SMTP-Passwort (leer = gleich wie IMAP): ")
        smtp_password = smtp_password or imap_password

    if not imap_password:
        raise UserError("Das IMAP-Passwort darf nicht leer sein.")
    if not smtp_password:
        raise UserError("Das SMTP-Passwort darf nicht leer sein.")
    return imap_password, smtp_password


def add_user(args: argparse.Namespace, config: dict[str, Any]) -> None:
    defaults = config["defaults"]
    email = normalize_email(args.email)

    interactive = not args.non_interactive
    if interactive:
        display_name = prompt_default("Anzeigename", args.display_name or email.split("@", 1)[0])
        imap_host = prompt_default("IMAP-Server", args.imap_host or defaults["imap_host"])
        imap_port = int(prompt_default("IMAP-Port", str(args.imap_port or defaults["imap_port"])))
        imap_user = prompt_default("IMAP-Benutzer", args.imap_user or email)
        smtp_host = prompt_default("SMTP-Server", args.smtp_host or defaults["smtp_host"])
        smtp_port = int(prompt_default("SMTP-Port", str(args.smtp_port or defaults["smtp_port"])))
        smtp_user = prompt_default("SMTP-Benutzer", args.smtp_user or email)
    else:
        display_name = args.display_name or email.split("@", 1)[0]
        imap_host = args.imap_host or defaults["imap_host"]
        imap_port = int(args.imap_port or defaults["imap_port"])
        imap_user = args.imap_user or email
        smtp_host = args.smtp_host or defaults["smtp_host"]
        smtp_port = int(args.smtp_port or defaults["smtp_port"])
        smtp_user = args.smtp_user or email

    imap_host = validate_host(imap_host, "IMAP-Server")
    smtp_host = validate_host(smtp_host, "SMTP-Server")
    imap_port = validate_port(imap_port, "IMAP-Port")
    smtp_port = validate_port(smtp_port, "SMTP-Port")
    if smtp_port != 587:
        raise UserError("Diese Version unterstützt für den SMTP-Relay nur Port 587 mit STARTTLS.")
    imap_password, smtp_password = read_passwords(args)

    sql = """
        INSERT INTO sogo_users (
            c_uid, c_name, c_password, c_cn, mail,
            imap_host, imap_port, imap_user, imap_password,
            smtp_host, smtp_port, smtp_user, smtp_password,
            enabled
        ) VALUES (
            %s, %s, %s, %s, %s,
            %s, %s, %s, AES_ENCRYPT(%s, UNHEX(%s)),
            %s, %s, %s, AES_ENCRYPT(%s, UNHEX(%s)),
            1
        )
        ON DUPLICATE KEY UPDATE
            c_uid = VALUES(c_uid),
            c_name = VALUES(c_name),
            c_cn = VALUES(c_cn),
            imap_host = VALUES(imap_host),
            imap_port = VALUES(imap_port),
            imap_user = VALUES(imap_user),
            imap_password = VALUES(imap_password),
            smtp_host = VALUES(smtp_host),
            smtp_port = VALUES(smtp_port),
            smtp_user = VALUES(smtp_user),
            smtp_password = VALUES(smtp_password),
            enabled = 1
    """

    params = (
        email,
        email,
        "{PLAIN}disabled-oidc-only",
        display_name,
        email,
        imap_host,
        imap_port,
        imap_user,
        imap_password,
        config["aes_key_hex"],
        smtp_host,
        smtp_port,
        smtp_user,
        smtp_password,
        config["aes_key_hex"],
    )

    with connect(config) as db:
        with db.cursor() as cursor:
            cursor.execute(sql, params)
    print(f"OK: {email} wurde angelegt oder aktualisiert.")


def list_users(config: dict[str, Any]) -> None:
    sql = """
        SELECT mail, c_cn, imap_host, imap_port, imap_user,
               smtp_host, smtp_port, smtp_user, enabled
        FROM sogo_users
        ORDER BY mail
    """
    with connect(config) as db:
        with db.cursor() as cursor:
            cursor.execute(sql)
            rows = cursor.fetchall()

    if not rows:
        print("Keine Benutzer vorhanden.")
        return

    for row in rows:
        state = "aktiv" if row["enabled"] else "deaktiviert"
        print(
            f"{row['mail']} | {row['c_cn']} | {state}\n"
            f"  IMAP {row['imap_user']}@{row['imap_host']}:{row['imap_port']}\n"
            f"  SMTP {row['smtp_user']}@{row['smtp_host']}:{row['smtp_port']}"
        )


def remove_user(args: argparse.Namespace, config: dict[str, Any]) -> None:
    email = normalize_email(args.email)
    if not args.yes:
        answer = input(f"{email} wirklich entfernen? [j/N]: ").strip().lower()
        if answer not in {"j", "ja", "y", "yes"}:
            print("Abgebrochen.")
            return

    with connect(config) as db:
        with db.cursor() as cursor:
            affected = cursor.execute("DELETE FROM sogo_users WHERE mail = %s", (email,))
    if affected:
        print(f"OK: {email} wurde entfernt.")
    else:
        raise UserError(f"Benutzer nicht gefunden: {email}")


def set_enabled(args: argparse.Namespace, config: dict[str, Any], enabled: bool) -> None:
    email = normalize_email(args.email)
    with connect(config) as db:
        with db.cursor() as cursor:
            affected = cursor.execute(
                "UPDATE sogo_users SET enabled = %s WHERE mail = %s",
                (1 if enabled else 0, email),
            )
    if not affected:
        raise UserError(f"Benutzer nicht gefunden oder Zustand bereits gesetzt: {email}")
    print(f"OK: {email} ist jetzt {'aktiv' if enabled else 'deaktiviert'}.")


def load_user_with_passwords(email: str, config: dict[str, Any]) -> dict[str, Any]:
    sql = """
        SELECT mail, imap_host, imap_port, imap_user,
               CONVERT(AES_DECRYPT(imap_password, UNHEX(%s)) USING utf8mb4) AS imap_password,
               smtp_host, smtp_port, smtp_user,
               CONVERT(AES_DECRYPT(smtp_password, UNHEX(%s)) USING utf8mb4) AS smtp_password,
               enabled
        FROM sogo_users
        WHERE mail = %s
    """
    with connect(config) as db:
        with db.cursor() as cursor:
            cursor.execute(sql, (config["aes_key_hex"], config["aes_key_hex"], email))
            row = cursor.fetchone()
    if row is None:
        raise UserError(f"Benutzer nicht gefunden: {email}")
    if not row["enabled"]:
        raise UserError(f"Benutzer ist deaktiviert: {email}")
    return row


def test_user(args: argparse.Namespace, config: dict[str, Any]) -> None:
    email = normalize_email(args.email)
    row = load_user_with_passwords(email, config)

    print(f"Teste IMAP für {email} …")
    with imaplib.IMAP4_SSL(
        row["imap_host"],
        int(row["imap_port"]),
        ssl_context=ssl.create_default_context(),
        timeout=20,
    ) as imap:
        imap.login(row["imap_user"], row["imap_password"])
        status, folders = imap.list()
        if status != "OK":
            raise UserError("IMAP LIST wurde abgelehnt.")
        folder_count = len(folders or [])
        imap.logout()
    print(f"OK: IMAP-Anmeldung erfolgreich, {folder_count} Ordner gefunden.")

    print(f"Teste SMTP für {email} …")
    smtp_port = int(row["smtp_port"])
    context = ssl.create_default_context()
    if smtp_port == 465:
        with smtplib.SMTP_SSL(row["smtp_host"], smtp_port, timeout=20, context=context) as smtp:
            smtp.login(row["smtp_user"], row["smtp_password"])
    else:
        with smtplib.SMTP(row["smtp_host"], smtp_port, timeout=20) as smtp:
            smtp.ehlo()
            smtp.starttls(context=context)
            smtp.ehlo()
            smtp.login(row["smtp_user"], row["smtp_password"])
    print("OK: SMTP-Anmeldung erfolgreich. Es wurde keine Nachricht versendet.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sogo-mail-user",
        description="SOGo-Benutzer und externe IMAP-/SMTP-Zugangsdaten verwalten.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    add = sub.add_parser("add", help="Benutzer anlegen oder aktualisieren")
    add.add_argument("email")
    add.add_argument("--display-name")
    add.add_argument("--imap-host")
    add.add_argument("--imap-port", type=int)
    add.add_argument("--imap-user")
    add.add_argument("--smtp-host")
    add.add_argument("--smtp-port", type=int)
    add.add_argument("--smtp-user")
    add.add_argument("--password-stdin", action="store_true")
    add.add_argument("--non-interactive", action="store_true")

    sub.add_parser("list", help="Benutzer ohne Passwörter anzeigen")

    remove = sub.add_parser("remove", help="Benutzer entfernen")
    remove.add_argument("email")
    remove.add_argument("--yes", action="store_true")

    disable = sub.add_parser("disable", help="Benutzer deaktivieren")
    disable.add_argument("email")

    enable = sub.add_parser("enable", help="Benutzer aktivieren")
    enable.add_argument("email")

    test = sub.add_parser("test", help="IMAP- und SMTP-Anmeldung testen")
    test.add_argument("email")

    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        config = load_config()

        if args.command == "add":
            add_user(args, config)
        elif args.command == "list":
            list_users(config)
        elif args.command == "remove":
            remove_user(args, config)
        elif args.command == "disable":
            set_enabled(args, config, False)
        elif args.command == "enable":
            set_enabled(args, config, True)
        elif args.command == "test":
            test_user(args, config)
        else:
            raise UserError(f"Unbekannter Befehl: {args.command}")
        return 0
    except (UserError, pymysql.MySQLError, OSError, imaplib.IMAP4.error, smtplib.SMTPException) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
