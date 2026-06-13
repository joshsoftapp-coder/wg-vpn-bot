"""
Daily digests — called as `digest.py vm` or `digest.py wg` by systemd timers.

Posts directly to Telegram with urllib (no asyncio needed for one-shot).
"""
from __future__ import annotations

import json
import logging
import sys
from pathlib import Path as _Path
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

import config
import state
import vm_cmds
import wg_cmds

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("digest")


def _svc_active(unit: str) -> bool:
    """Unit liveness via its cgroup — no D-Bus, no root, no subprocess.

    Unprivileged `systemctl is-active` needs the D-Bus system bus, which
    the GCP Debian image may not ship — it then errors and a healthy unit
    reads as inactive (observed on a real VM). The unit's cgroup.procs
    file is world-readable and non-empty iff the service has live
    processes (cgroup v2, Debian 12 default)."""
    try:
        procs = _Path(
            f"/sys/fs/cgroup/system.slice/{unit}.service/cgroup.procs"
        ).read_text()
        return any(ln.strip() for ln in procs.splitlines())
    except OSError:
        return False


def build_vm_digest() -> str:
    up = vm_cmds.fmt_uptime(vm_cmds.uptime_seconds())
    la = vm_cmds.load_avg()
    mem = vm_cmds.mem_info()
    disk = vm_cmds.disk_root()
    mem_pct = int(mem["used_kb"] * 100 / mem["total_kb"]) if mem["total_kb"] else 0
    ip = wg_cmds.server_external_ip() or "?"

    # Unauthorized DMs in last 24h
    dms = state.get("unauthorized_dms", []) or []
    cutoff = int(time.time()) - 86400
    recent_dms = [d for d in dms if d.get("ts", 0) > cutoff]

    lines = [
        f"*📋 VM digest — {datetime.now().strftime('%Y-%m-%d %H:%M')}*",
        "",
        f"Public IP: `{ip}`",
        f"Uptime: `{up}`",
        f"Load: `{la[0]:.2f} {la[1]:.2f} {la[2]:.2f}`",
        f"Mem used: `{mem_pct}%`",
        f"Disk used: `{disk['percent']}%` ({vm_cmds.fmt_bytes(disk['free_b'])} free)",
        f"WireGuard: {'🟢 active' if wg_cmds.wg_active() else '🔴 inactive'}",
        # This digest is sent by an independent systemd timer, NOT by the
        # bot — so it still arrives when the bot is dead and this line is
        # the dead-man's signal that makes a dead bot visible within 24h.
        f"Bot: {'🟢 active' if _svc_active('wg-admin-bot') else '🔴 INACTIVE — SSH in: systemctl status wg-admin-bot'}",
    ]
    if recent_dms:
        lines.append("")
        lines.append(f"*Unauthorized DMs (24h):* {len(recent_dms)} attempts")
        # Show up to 3 distinct senders
        seen = {}
        for d in recent_dms:
            uid = d.get("user_id")
            if uid not in seen:
                seen[uid] = d
            if len(seen) >= 3:
                break
        for uid, d in seen.items():
            # Telegram usernames are [A-Za-z0-9_] only, but be defensive:
            # strip backticks so a crafted value can't break the code span.
            uname = (d.get("username") or "?").replace("`", "")
            # Put everything inside a single backtick code span so neither the
            # 'id' label nor any character in the username can break Markdown.
            lines.append(f"  • `id={uid} @{uname}`")

    # Security audit summary — counts and check names only, never values.
    audit = vm_cmds.run_audit_summary()
    lines.append("")
    if not audit["ok"] and audit.get("error"):
        lines.append("*Security:* ⚠️ audit could not run")
    else:
        total = audit["passed"] + audit["failed"]
        if audit["failed"] == 0:
            lines.append(f"*Security:* ✅ {audit['passed']}/{total} checks passed")
        else:
            fails = ", ".join(f"`{s}`" for s in audit["fails"])
            lines.append(
                f"*Security:* ⚠️ {audit['passed']}/{total} passed — "
                f"failed: {fails} (see /audit)"
            )

    # Where to find the full logs (the digest is a summary, not the record).
    lines.append("")
    lines.append("Full logs — SSH in and run:")
    lines.append("`sudo journalctl -u wg-admin-bot`")
    lines.append("`sudo less /var/log/wg-admin-bot/audit.log`")
    return "\n".join(lines)


def build_wg_digest() -> str:
    peers = wg_cmds.list_peers()
    rt = wg_cmds.runtime_status()
    now = int(time.time())
    ip = wg_cmds.server_external_ip() or "?"

    lines = [
        f"*🔐 WireGuard digest — {datetime.now().strftime('%Y-%m-%d %H:%M')}*",
        "",
        f"Public IP: `{ip}`",
        f"Total peers: `{len(peers)}`",
    ]

    # Peers active in last 24h
    active_24h = []
    for p in peers:
        info = rt.get(p.public_key, {})
        last = info.get("last_handshake", 0)
        if last and (now - last) < 86400:
            active_24h.append((p, last, info.get("rx", 0), info.get("tx", 0)))

    if active_24h:
        lines.append("")
        lines.append("*Active in last 24h:*")
        for p, last, rx, tx in active_24h:
            ago_min = (now - last) // 60
            lines.append(
                f"• `{p.name}` — {ago_min}m ago — "
                f"↓{vm_cmds.fmt_bytes(rx)} ↑{vm_cmds.fmt_bytes(tx)}"
            )
    else:
        lines.append("")
        lines.append("_No peer activity in the last 24h._")

    return "\n".join(lines)


def _esc(s: str) -> str:
    """Escape Telegram-Markdown (legacy) special chars in user-controlled text.

    Legacy Markdown treats _ * ` [ as formatting. An unbalanced one makes
    Telegram reject the whole message with HTTP 400 'can't parse entities'.
    Usernames and similar arbitrary strings must be escaped before
    interpolation into a Markdown message.
    """
    if not s:
        return s
    for ch in ("_", "*", "`", "["):
        s = s.replace(ch, "\\" + ch)
    return s


def send(text: str) -> bool:
    token = config.bot_token()
    admin = config.admin_id()
    if admin is None:
        log.info("no admin paired; skipping digest")
        return False

    def _post(payload: dict) -> tuple[bool, str]:
        data = urllib.parse.urlencode(payload).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=data, method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                j = json.loads(resp.read())
                if not j.get("ok"):
                    return False, str(j)
            return True, ""
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode()
            except Exception:
                pass
            return False, f"HTTP {e.code}: {body}"
        except Exception as e:
            return False, f"{type(e).__name__}: {e}"

    # First attempt: Markdown
    ok, err = _post({"chat_id": admin, "text": text, "parse_mode": "Markdown"})
    if ok:
        return True
    log.error("digest send (markdown) failed: %s", err)

    # Fallback: plain text (strip nothing, just drop parse_mode). Better an
    # unformatted digest than none. This rescues messages that contain
    # Markdown-breaking characters we failed to escape.
    ok, err = _post({"chat_id": admin, "text": text})
    if ok:
        log.warning("digest delivered as plain text (markdown parse failed)")
        return True
    log.error("digest send (plain) also failed: %s", err)
    return False


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("vm", "wg"):
        log.error("usage: digest.py vm|wg")
        return 64
    kind = sys.argv[1]
    if not config.get("digest.enabled", True):
        log.info("digest disabled in config")
        return 0
    if kind == "vm":
        text = build_vm_digest()
    else:
        text = build_wg_digest()
    return 0 if send(text) else 1


if __name__ == "__main__":
    sys.exit(main())
