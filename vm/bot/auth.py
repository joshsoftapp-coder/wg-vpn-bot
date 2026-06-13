"""TOFU pairing, admin check, audit log, unauthorized-DM tracking."""
from __future__ import annotations

import logging
import time
from pathlib import Path

import config
import state

log = logging.getLogger(__name__)

AUDIT_LOG = Path("/var/log/wg-admin-bot/audit.log")


def is_admin(user_id: int) -> bool:
    aid = config.admin_id()
    return aid is not None and int(user_id) == aid


def try_pair(user_id: int, token: str) -> tuple[bool, str]:
    if config.admin_id() is not None:
        return False, (
            "This bot is already paired. To transfer admin, SSH into the VM "
            "and run: sudo wg-bot-reset-admin"
        )

    stored, expires = config.pairing_token()
    if not stored:
        return False, "No pairing token is active. Run sudo wg-bot-reset-admin on the VM."
    if time.time() >= expires:
        return False, "Pairing token expired. Run sudo wg-bot-reset-admin on the VM."
    if token.strip() != stored:
        audit(user_id, "pair_failed", "bad token")
        return False, "Token does not match."

    config.set_admin_id(user_id)
    config.clear_pairing_token()
    state.set_("admin_user_id", int(user_id))
    audit(user_id, "pair_ok", "admin established")
    log.warning("ADMIN PAIRED: user_id=%s", user_id)
    return True, "ok"


def record_unauthorized(user_id: int, username: str | None, text: str) -> None:
    """Log an unauthorized DM attempt. Surfaced in the daily VM digest."""
    def mutate(cur):
        cur = cur or []
        cur.append({
            "ts": int(time.time()),
            "user_id": int(user_id),
            "username": username or "",
            "text": (text or "")[:200],
        })
        # Keep only last 48h worth, capped at 500 entries to bound the file
        cutoff = time.time() - 48 * 3600
        cur = [e for e in cur if e["ts"] > cutoff][-500:]
        return cur
    state.update("unauthorized_dms", mutate)
    audit(user_id, "unauthorized", text or "")


def audit(user_id, action: str, detail: str = "") -> None:
    """Append a line to the audit log. Best-effort."""
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
        line = f"{ts}\tuser={user_id}\taction={action}\t{detail}\n"
        with AUDIT_LOG.open("a") as f:
            f.write(line)
    except OSError as e:
        log.error("audit log write failed: %s", e)
