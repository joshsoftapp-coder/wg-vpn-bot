#!/usr/bin/python3
"""Crash notifier — run by wg-admin-bot-onfailure.service (as wgbot) when
the bot unit fails. Posts the alert directly to Telegram, bypassing the
(dead) bot.

Hard-won constraints, in chronological order of discovery:
 - must NOT be inline in ExecStart= (systemd $-expansion silently blanked
   the variables);
 - must NOT grep config.yaml for the token: the bot re-serialises the file
   with yaml.safe_dump at pairing, which drops the quotes the installer
   wrote — a quote-assuming grep matched nothing, silently. Parse the YAML.
 - reads are RETRIED: OnFailure= can fire mid-crash-loop while the bot is
   rewriting state.json/config.yaml, yielding a momentarily empty/partial
   read. A single read then hit the "nothing to send" branch and exited 0
   silently (acceptance T4 failed while T5 — a calm direct run — passed).
 - every outcome is logged to stderr (→ journal via StandardError=journal):
   a failure notifier that fails silently hid every bug above.

Uses system python3 + PyYAML (startup.sh already depends on both).
"""
import json
import socket
import sys
import time
import urllib.request

import yaml

CFG = "/etc/wg-admin-bot/config.yaml"
STATE = "/var/lib/wg-admin-bot/state.json"

READ_TRIES = 3
READ_DELAY = 0.2  # seconds between attempts


def _read_creds():
    """Return (token, admin_id) or (None, None). Retries to ride out a
    read landing mid-rewrite during a crash loop."""
    for attempt in range(1, READ_TRIES + 1):
        try:
            with open(CFG) as f:
                cfg = yaml.safe_load(f) or {}
            token = (cfg.get("telegram") or {}).get("bot_token") or ""
            with open(STATE) as f:
                admin = (json.load(f) or {}).get("admin_user_id")
            if token and admin:
                return token, admin
            reason = "empty token" if not token else "admin not paired"
        except (OSError, ValueError, yaml.YAMLError) as e:
            reason = f"{type(e).__name__}: {e}"
        if attempt < READ_TRIES:
            print(f"crash-notify: read attempt {attempt}/{READ_TRIES} "
                  f"unusable ({reason}); retrying", file=sys.stderr)
            time.sleep(READ_DELAY)
    print(f"crash-notify: giving up after {READ_TRIES} reads ({reason})",
          file=sys.stderr)
    return None, None


def main() -> int:
    token, admin = _read_creds()
    if not token or not admin:
        return 0  # journal already has the why; don't fail the unit

    msg = (f"🔴 wg-admin-bot crashed on {socket.gethostname()}. systemd will "
           "retry. journalctl -u wg-admin-bot -n 50 for details.")
    try:
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=json.dumps({"chat_id": admin, "text": msg}).encode(),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10)
        print("crash-notify: alert sent", file=sys.stderr)
    except Exception as e:
        print(f"crash-notify: Telegram send failed: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
