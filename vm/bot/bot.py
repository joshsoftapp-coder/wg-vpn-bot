"""
wg-admin-bot — Telegram bot dispatcher.

Three classes of caller:
  • admin     — TOFU-paired, can run all commands
  • peer      — claimed via /claim, can DM bot (only /leave does something)
  • stranger  — anyone else, ignored (DM recorded for digest summary)
"""
from __future__ import annotations

import asyncio
import io
import logging
from datetime import datetime
from pathlib import Path

import qrcode
from telegram import InputFile, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application, ApplicationBuilder, CommandHandler,
    ContextTypes, MessageHandler, filters,
)

import alerts
import auth
import claim
import config
import digest
import state
import vm_cmds
import wg_cmds

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
)
log = logging.getLogger("bot")

# PTB logs every HTTP request at INFO, and the URL embeds the bot token
# (https://api.telegram.org/bot<TOKEN>/getUpdates). At INFO that writes the
# token into the systemd journal on every poll. Raise these loggers to
# WARNING so the token never lands in logs; real errors still surface.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("telegram").setLevel(logging.WARNING)


# =========== send helpers ===========

async def _send_admin(app: Application, text: str, **kw) -> None:
    aid = config.admin_id()
    if aid is None:
        log.info("admin send dropped (no admin paired): %s", text[:80])
        return
    try:
        await app.bot.send_message(chat_id=aid, text=text, **kw)
    except Exception as e:
        log.error("admin send failed: %s", e)


async def _send_peer(app: Application, peer_name: str, text: str, **kw) -> bool:
    """Send to claimed peer if bound; otherwise return False."""
    cid = claim.chat_id_for(peer_name)
    if cid is None:
        return False
    try:
        await app.bot.send_message(chat_id=cid, text=text, **kw)
        return True
    except Exception as e:
        log.error("peer send to %s failed: %s", peer_name, e)
        return False


async def _send_peer_config(app: Application, chat_id: int, peer: wg_cmds.Peer) -> None:
    """Send the .conf + QR to a chat. Requires peer.private_key set."""
    endpoint = wg_cmds.server_external_ip() or "<UNKNOWN-IP>"
    conf_text = wg_cmds.render_client_conf(peer, endpoint)

    await app.bot.send_document(
        chat_id=chat_id,
        document=InputFile(io.BytesIO(conf_text.encode()), filename=f"{peer.name}.conf"),
        caption=f"WireGuard config: {peer.name} @ {peer.allowed_ips}",
    )
    qr = io.BytesIO()
    qrcode.make(conf_text).save(qr, format="PNG")
    qr.seek(0)
    await app.bot.send_photo(
        chat_id=chat_id,
        photo=InputFile(qr, filename=f"{peer.name}.png"),
        caption="Scan with the WireGuard app to connect.",
    )


async def _broadcast_peers(app: Application, text: str) -> int:
    """Send text to all claimed peers. Returns number sent."""
    bindings = state.get("peer_chat_ids", {}) or {}
    n = 0
    for peer_name, cid in bindings.items():
        try:
            await app.bot.send_message(chat_id=int(cid), text=text)
            n += 1
        except Exception as e:
            log.warning("broadcast to %s failed: %s", peer_name, e)
    return n


# =========== decorator ===========

def admin_only(handler):
    async def wrapper(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        u = update.effective_user
        if u is None:
            return
        if not auth.is_admin(u.id):
            _record_stranger(u, update.effective_message)
            return
        return await handler(update, ctx)
    return wrapper


def _record_stranger(user, message) -> None:
    """A non-admin DM'd the bot. Record for digest summary."""
    # Don't treat claimed peers as strangers — they have their own handlers.
    peer = auth.is_claimed_peer(user.id)
    if peer:
        return
    text = message.text if message else ""
    auth.record_unauthorized(user.id, user.username, text or "")


# =========== /start, /claim, /leave (open or peer-facing) ===========

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    m = update.effective_message
    if u is None or m is None:
        return

    parts = (m.text or "").split(maxsplit=1)
    arg = parts[1].strip() if len(parts) == 2 else ""

    # Already paired
    if config.admin_id() is not None:
        if auth.is_admin(u.id):
            await m.reply_text("You're already the admin. Try /help.")
            return
        peer = auth.is_claimed_peer(u.id)
        if peer:
            await m.reply_text(
                f"You're claimed as peer '{peer}'. "
                f"You can /leave YES to remove yourself."
            )
            return
        # Stranger
        await m.reply_text(
            "👋 Hi! This is a private VPN bot.\n\n"
            "If your admin sent you a claim token, your next message should be:\n\n"
            "    /claim ABCD-EFGH-IJKL\n\n"
            "(replace ABCD-EFGH-IJKL with the actual token you received).\n\n"
            "Telegram's UI made you press Start before letting you type — "
            "that's why this is two steps."
        )
        _record_stranger(u, m)
        return

    # Not paired — TOFU
    if not arg:
        await m.reply_text(
            "👋 Hi! This bot is unpaired and waiting for an admin.\n\n"
            "Telegram's UI requires that bare /start before you can type — that's "
            "the message I just received. To actually pair, your next message "
            "needs to include the pairing token:\n\n"
            "    /start ABCD-EFGH-IJKL\n\n"
            "(replace ABCD-EFGH-IJKL with the token from the installer output, "
            "or run `sudo wg-bot-reset-admin` on the VM to generate a fresh one)."
        )
        return

    ok, why = auth.try_pair(u.id, arg)
    if not ok:
        await m.reply_text(why)
        return

    await m.reply_text(
        f"✅ Paired. You are the admin (user_id={u.id}).\n"
        "Sending your first peer config…"
    )
    await _deliver_first_peer(ctx.application, u.id)
    await m.reply_text(_help_text(), parse_mode=ParseMode.MARKDOWN)


async def _deliver_first_peer(app: Application, chat_id: int) -> None:
    name = config.get("first_peer.name", "vpn-default")
    peer = wg_cmds.get_peer_by_name(name)
    if peer is None:
        await app.bot.send_message(
            chat_id=chat_id,
            text=f"⚠ First peer '{name}' not found. Use /add {name} to create one.",
        )
        return
    # First-peer secret is stashed by cli.py
    stash = state.get("first_peer_secret", {}) or {}
    if stash.get("name") == name and stash.get("private_key"):
        peer.private_key = stash["private_key"]
        peer.preshared_key = stash.get("preshared_key") or peer.preshared_key
    else:
        await app.bot.send_message(
            chat_id=chat_id,
            text=f"⚠ First peer '{name}' exists but private key isn't stashed. "
                 f"Use /reissue {name} to get a fresh config.",
        )
        return
    await _send_peer_config(app, chat_id, peer)
    state.delete("first_peer_secret")


async def cmd_claim(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    m = update.effective_message
    if u is None or m is None:
        return
    if auth.is_admin(u.id):
        await m.reply_text("Admins don't claim. Use /add to create peers.")
        return

    parts = (m.text or "").split(maxsplit=1)
    if len(parts) != 2 or not parts[1].strip():
        await m.reply_text("Usage: /claim YOUR-TOKEN-HERE")
        return
    token = parts[1].strip()

    ok, msg, peer_name = claim.try_claim(u.id, token)
    if not ok:
        await m.reply_text(msg)
        _record_stranger(u, m)
        return

    auth.audit(u.id, "claim_ok", peer_name or "")
    # Send the config — but we don't have the private key (only at creation).
    peer = wg_cmds.get_peer_by_name(peer_name)
    if not peer:
        await m.reply_text(
            f"Claim recorded for '{peer_name}', but the peer no longer exists. "
            "Ask your admin."
        )
        return

    await m.reply_text(
        f"✅ Claimed peer '{peer_name}'.\n"
        f"Your admin will now /reissue your config — you'll receive it here shortly."
    )
    # Notify admin
    await _send_admin(
        ctx.application,
        f"📥 {peer_name} claimed by user_id={u.id} username=@{u.username or '?'}.\n"
        f"Run /reissue {peer_name} to send their config."
    )


async def cmd_leave(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    m = update.effective_message
    if u is None or m is None:
        return

    peer_name = auth.is_claimed_peer(u.id)
    if not peer_name:
        # Stranger or admin
        if auth.is_admin(u.id):
            await m.reply_text("Admins don't /leave. Use /remove <name> YES to remove peers.")
        return  # silent for strangers

    parts = (m.text or "").split()
    if len(parts) < 2 or parts[1].upper() != "YES":
        await m.reply_text(
            f"⚠ This will REMOVE your VPN access (peer '{peer_name}').\n"
            "Confirm with: /leave YES"
        )
        return

    try:
        wg_cmds.remove(peer_name)
        claim.remove_peer_bindings(peer_name)
        await m.reply_text(
            f"👋 Removed peer '{peer_name}'. Your VPN config will stop working. Goodbye."
        )
        auth.audit(u.id, "peer_self_remove", peer_name)
        await _send_admin(
            ctx.application,
            f"👋 Peer '{peer_name}' left voluntarily (user_id={u.id} username=@{u.username or '?'})."
        )
    except Exception as e:
        log.exception("self-remove failed")
        await m.reply_text(f"❌ Failed: {e}")


# =========== admin: WG group ===========

@admin_only
async def cmd_peers(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    peers = wg_cmds.list_peers()
    if not peers:
        await update.effective_message.reply_text("No peers yet. Try /add <name>.")
        return
    rt = wg_cmds.runtime_status()
    now = int(__import__("time").time())
    lines = ["*Peers*"]
    for p in peers:
        info = rt.get(p.public_key, {})
        last = info.get("last_handshake", 0)
        hs = _fmt_handshake(last, now)
        lines.append(f"• `{p.name}` — {p.allowed_ips} — handshake: {hs}")
    await update.effective_message.reply_text("\n".join(lines), parse_mode=ParseMode.MARKDOWN)


def _fmt_handshake(epoch: int, now: int) -> str:
    if not epoch:
        return "never"
    ago = now - epoch
    if ago < 60: return f"{ago}s ago"
    if ago < 3600: return f"{ago // 60}m ago"
    if ago < 86400: return f"{ago // 3600}h ago"
    return f"{ago // 86400}d ago"


@admin_only
async def cmd_peer(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /peer <name>")
        return
    name = ctx.args[0]
    p = wg_cmds.get_peer_by_name(name)
    if not p:
        await update.effective_message.reply_text(f"No peer named '{name}'.")
        return
    rt = wg_cmds.runtime_status().get(p.public_key, {})
    info = (
        f"*Peer `{name}`*\n"
        f"Allowed IP: `{p.allowed_ips}`\n"
        f"Public key: `{p.public_key}`\n"
    )
    if rt.get("last_handshake"):
        info += f"Last handshake: epoch `{rt['last_handshake']}`\n"
    if rt.get("rx") or rt.get("tx"):
        info += (f"Transfer: ↓{vm_cmds.fmt_bytes(rt.get('rx', 0))} "
                 f"↑{vm_cmds.fmt_bytes(rt.get('tx', 0))}\n")
    await update.effective_message.reply_text(info, parse_mode=ParseMode.MARKDOWN)


@admin_only
async def cmd_add(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /add <name>")
        return
    name = ctx.args[0]
    try:
        peer = wg_cmds.add(name)
    except (ValueError, RuntimeError) as e:
        await update.effective_message.reply_text(f"❌ {e}")
        return
    auth.audit(update.effective_user.id, "peer_add", name)
    await _send_peer_config(ctx.application, update.effective_chat.id, peer)


@admin_only
async def cmd_remove(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /remove <name> YES")
        return
    name = ctx.args[0]
    if not wg_cmds.get_peer_by_name(name):
        await update.effective_message.reply_text(f"No peer named '{name}'.")
        return
    if len(ctx.args) < 2 or ctx.args[1].upper() != "YES":
        await update.effective_message.reply_text(
            f"⚠ This will permanently remove peer '{name}'.\n"
            f"Confirm: /remove {name} YES"
        )
        return
    try:
        wg_cmds.remove(name)
        claim.remove_peer_bindings(name)
        auth.audit(update.effective_user.id, "peer_remove", name)
        await update.effective_message.reply_text(f"🗑 Removed peer '{name}'.")
    except (ValueError, RuntimeError) as e:
        await update.effective_message.reply_text(f"❌ {e}")


@admin_only
async def cmd_reissue(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /reissue <name>")
        return
    name = ctx.args[0]
    if not wg_cmds.get_peer_by_name(name):
        await update.effective_message.reply_text(f"No peer named '{name}'.")
        return
    try:
        peer = wg_cmds.reissue(name)
    except (ValueError, RuntimeError) as e:
        await update.effective_message.reply_text(f"❌ {e}")
        return
    auth.audit(update.effective_user.id, "peer_reissue", name)

    # Send the fresh config to admin
    await _send_peer_config(ctx.application, update.effective_chat.id, peer)
    await update.effective_message.reply_text(f"✅ Reissued '{name}'.")


@admin_only
async def cmd_invite(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /invite <name>")
        return
    name = ctx.args[0]
    try:
        tok = claim.create_invite(name)
    except ValueError as e:
        await update.effective_message.reply_text(f"❌ {e}")
        return
    auth.audit(update.effective_user.id, "invite", name)
    bot_user = config.get("telegram.bot_username", "your_bot")
    await update.effective_message.reply_text(
        f"📤 Send this to '{name}':\n\n"
        f"Open Telegram, find @{bot_user}, send:\n"
        f"`/claim {tok}`\n\n"
        f"Expires in 30 minutes.",
        parse_mode=ParseMode.MARKDOWN,
    )


@admin_only
async def cmd_unclaim(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /unclaim <name>")
        return
    name = ctx.args[0]
    if claim.unclaim(name):
        auth.audit(update.effective_user.id, "unclaim", name)
        await update.effective_message.reply_text(
            f"✅ Cleared claim binding for '{name}'. "
            f"Future /reissue will DM you instead."
        )
    else:
        await update.effective_message.reply_text(f"No claim binding for '{name}'.")


@admin_only
async def cmd_export(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """Send wg0.conf as a Telegram document."""
    try:
        text = Path("/etc/wireguard/wg0.conf").read_text()
    except OSError as e:
        await update.effective_message.reply_text(f"❌ Cannot read wg0.conf: {e}")
        return
    auth.audit(update.effective_user.id, "export", "")
    await update.effective_message.reply_document(
        document=InputFile(io.BytesIO(text.encode()), filename="wg0.conf"),
        caption=(
            "⚠ Contains server private key. Store securely.\n"
            "To restore: fresh install, then replace /etc/wireguard/wg0.conf via SSH."
        ),
    )


# =========== admin: VM group ===========

@admin_only
async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    up = vm_cmds.fmt_uptime(vm_cmds.uptime_seconds())
    la = vm_cmds.load_avg()
    mem = vm_cmds.mem_info()
    disk = vm_cmds.disk_root()
    peers = wg_cmds.list_peers()
    rt = wg_cmds.runtime_status()
    now = int(__import__("time").time())
    recent = sum(1 for s in rt.values()
                 if s["last_handshake"] and (now - s["last_handshake"]) < 300)
    wg_state = "🟢 active" if wg_cmds.wg_active() else "🔴 inactive"
    mem_pct = int(mem["used_kb"] * 100 / mem["total_kb"]) if mem["total_kb"] else 0
    ip = wg_cmds.server_external_ip() or "?"

    text = (
        f"*Status*\n"
        f"Host: `{Path('/etc/hostname').read_text().strip()}`\n"
        f"Public IP: `{ip}`\n"
        f"Uptime: `{up}`\n"
        f"Load: `{la[0]:.2f} {la[1]:.2f} {la[2]:.2f}`\n"
        f"Mem: `{mem_pct}%` used\n"
        f"Disk: `{disk['percent']}%` used "
        f"({vm_cmds.fmt_bytes(disk['free_b'])} free)\n"
        f"WireGuard: {wg_state}\n"
        f"Peers: `{len(peers)}` total, `{recent}` connected (last 5 min)"
    )
    await update.effective_message.reply_text(text, parse_mode=ParseMode.MARKDOWN)


@admin_only
async def cmd_audit(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    r = vm_cmds.run_audit_summary()
    if not r["ok"] and r.get("error"):
        await update.effective_message.reply_text(
            f"⚠️ Audit could not run: `{r['error']}`",
            parse_mode=ParseMode.MARKDOWN,
        )
        return
    total = r["passed"] + r["failed"]
    if r["failed"] == 0:
        text = (
            f"*Security audit* ✅\n"
            f"`{r['passed']}/{total}` checks passed."
        )
    else:
        # Slugs only — no values. Safe to send over Telegram.
        fails = "\n".join(f"• `{slug}`" for slug in r["fails"])
        text = (
            f"*Security audit* ⚠️\n"
            f"`{r['passed']}/{total}` passed, `{r['failed']}` failed:\n"
            f"{fails}\n\n"
            f"_Run_ `sudo wg-bot-audit` _over SSH for detail._"
        )
    await update.effective_message.reply_text(text, parse_mode=ParseMode.MARKDOWN)


@admin_only
async def cmd_logs(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args:
        await update.effective_message.reply_text("Usage: /logs wg|ssh|bot [n]")
        return
    target = ctx.args[0].lower()
    n = int(ctx.args[1]) if len(ctx.args) > 1 and ctx.args[1].isdigit() else 30
    n = max(1, min(n, 200))
    out = vm_cmds.tail_journal(target, n)
    if not out.strip():
        out = "(no output)"
    if len(out) > 3800:
        out = out[-3800:]
    await update.effective_message.reply_text(f"```\n{out}\n```", parse_mode=ParseMode.MARKDOWN)


@admin_only
async def cmd_reboot(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if ctx.args and ctx.args[0].upper() == "YES":
        await _broadcast_peers(ctx.application,
                               "🔁 VPN is rebooting (~60 seconds). You'll be reconnected automatically.")
        await update.effective_message.reply_text("🔁 Rebooting. See you in a minute.")
        auth.audit(update.effective_user.id, "reboot", "")
        await asyncio.sleep(2)
        vm_cmds.reboot()
        return
    await update.effective_message.reply_text(
        "⚠ This will reboot the VM. Confirm: /reboot YES"
    )


@admin_only
async def cmd_shutdown(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if ctx.args and ctx.args[0].upper() == "YES":
        await _broadcast_peers(ctx.application,
                               "⛔ VPN is shutting down. It will be unreachable until the admin starts it again.")
        await update.effective_message.reply_text(
            "⛔ Shutting down. Bot becomes unreachable. Start VM from the GCP Console to bring it back."
        )
        auth.audit(update.effective_user.id, "shutdown", "")
        await asyncio.sleep(2)
        vm_cmds.shutdown()
        return
    await update.effective_message.reply_text(
        "⚠ This will POWER OFF the VM and the bot will be unreachable.\n"
        "Confirm: /shutdown YES"
    )


@admin_only
@admin_only
async def cmd_restart(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not ctx.args or ctx.args[0].lower() != "wg":
        await update.effective_message.reply_text("Usage: /restart wg")
        return
    await _broadcast_peers(ctx.application,
                           "🔄 VPN restarting (~5 seconds). Reconnection should be automatic.")
    ok, msg = vm_cmds.restart_wg()
    auth.audit(update.effective_user.id, "restart_wg", "ok" if ok else "fail")
    await update.effective_message.reply_text(("✅ " if ok else "❌ ") + msg)


@admin_only
async def cmd_update(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if ctx.args and ctx.args[0].upper() == "YES":
        await _broadcast_peers(ctx.application,
                               "🔧 VPN host is applying security updates. Brief connection drops possible.")
        await update.effective_message.reply_text("Applying upgrades…")
        out = vm_cmds.apt_apply()
        auth.audit(update.effective_user.id, "update_apply", "")
        await update.effective_message.reply_text(f"```\n{out[-3500:]}\n```", parse_mode=ParseMode.MARKDOWN)
    else:
        await update.effective_message.reply_text("Checking what would change (dry-run)…")
        out = vm_cmds.apt_dry_run()
        await update.effective_message.reply_text(
            f"```\n{out[-3500:]}\n```\n\nTo apply: /update YES",
            parse_mode=ParseMode.MARKDOWN,
        )


@admin_only
async def cmd_digest(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """On-demand digest. /digest = both, /digest vm or /digest wg = one."""
    which = ctx.args[0].lower() if ctx.args else "both"
    if which not in ("vm", "wg", "both"):
        await update.effective_message.reply_text("Usage: /digest [vm|wg]")
        return

    sent_any = False
    if which in ("vm", "both"):
        try:
            text = digest.build_vm_digest()
            await update.effective_message.reply_text(text, parse_mode=ParseMode.MARKDOWN)
            sent_any = True
        except Exception as e:
            log.exception("vm digest failed")
            await update.effective_message.reply_text(f"❌ VM digest failed: {e}")
    if which in ("wg", "both"):
        try:
            text = digest.build_wg_digest()
            await update.effective_message.reply_text(text, parse_mode=ParseMode.MARKDOWN)
            sent_any = True
        except Exception as e:
            log.exception("wg digest failed")
            await update.effective_message.reply_text(f"❌ WG digest failed: {e}")
    if sent_any:
        auth.audit(update.effective_user.id, "digest", which)


@admin_only
async def cmd_whoami(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    await update.effective_message.reply_text(
        f"Admin (user_id={u.id}, username=@{u.username or '?'})"
    )


@admin_only
async def cmd_help(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    await update.effective_message.reply_text(_help_text(), parse_mode=ParseMode.MARKDOWN)


def _help_text() -> str:
    return (
        "*wg-admin-bot commands*\n"
        "\n*Peers:*\n"
        "  /peers — list all\n"
        "  /peer NAME — details\n"
        "  /add NAME — create peer, DM you the config\n"
        "  /reissue NAME — new keys (same name)\n"
        "  /remove NAME YES — delete peer entirely\n"
        "\n*VM (host):*\n"
        "  /status — health\n"
        "  /audit — security audit summary\n"
        "  /logs wg|ssh|bot [n] — tail journald\n"
        "  /reboot YES, /shutdown YES, /restart wg\n"
        "  /update — dry-run, /update YES — apply\n"
        "  /digest [vm|wg] — show status digest now\n"
        "\n*Misc:*\n"
        "  /export — download wg0.conf backup\n"
        "  /whoami — your user info\n"
    )


# =========== fallback ===========

async def cmd_unknown(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    m = update.effective_message
    if u is None:
        return
    if auth.is_admin(u.id):
        await m.reply_text("Unknown command. Try /help.")
        return
    peer = auth.is_claimed_peer(u.id)
    if peer:
        await m.reply_text(
            f"You're peer '{peer}'. Your only command here is /leave YES."
        )
        return
    # Stranger
    _record_stranger(u, m)


# =========== background tasks ===========

async def _alerts_tick_loop(sink: alerts.AlertSink) -> None:
    while True:
        await asyncio.sleep(60)
        try:
            await sink.tick()
        except Exception:
            log.exception("alerts.tick failed")


async def _post_init(app: Application) -> None:
    """Set up alert sink, register background tasks, ping admin on restart.

    PTB 21.x emits a PTBUserWarning that tasks created here "won't be
    automatically awaited" — this is a known false-positive. run_polling()
    handles the task lifecycle correctly. Verified empirically: the FIFO
    listener and tick loop both run as expected."""
    async def send_to_admin(text: str) -> None:
        await _send_admin(app, text)

    sink = alerts.AlertSink(send_to_admin)
    app.bot_data["alert_sink"] = sink
    app.create_task(alerts.listen_fifo(sink))
    app.create_task(_alerts_tick_loop(sink))

    aid = config.admin_id()
    if aid is not None:
        try:
            await app.bot.send_message(
                chat_id=aid,
                text=f"🟢 wg-admin-bot online ({datetime.now().strftime('%H:%M:%S')}).",
            )
        except Exception:
            log.warning("could not send startup ping to admin", exc_info=True)


async def _on_error(update, context) -> None:
    """Global error handler. Any handler exception lands here.

    The goal: never silently lose a message. Log it, and if we can, tell
    the user something went wrong so they're not staring at an unresponsive
    bot wondering what to do."""
    log.error("handler exception while processing %s", update, exc_info=context.error)
    try:
        if isinstance(update, Update) and update.effective_message:
            err_text = type(context.error).__name__
            await update.effective_message.reply_text(
                f"⚠️ Command failed: {err_text}. Check logs: /logs bot 50 "
                f"or `sudo journalctl -u wg-admin-bot -n 50` on the VM."
            )
    except Exception:
        log.exception("error handler itself failed")


# =========== entrypoint ===========

def main() -> None:
    token = config.bot_token()
    app: Application = (
        ApplicationBuilder()
        .token(token)
        .post_init(_post_init)
        .build()
    )

    # Open-ish
    app.add_handler(CommandHandler("start", cmd_start))
    # /claim and /leave are disabled in this build — the peer-claim flow
    # has known bugs. Code in claim.py and the handlers are kept for a
    # future re-enable. Re-add the lines below to restore:
    # app.add_handler(CommandHandler("claim", cmd_claim))
    # app.add_handler(CommandHandler("leave", cmd_leave))

    # Admin: WG
    app.add_handler(CommandHandler("peers", cmd_peers))
    app.add_handler(CommandHandler("peer", cmd_peer))
    app.add_handler(CommandHandler("add", cmd_add))
    app.add_handler(CommandHandler("remove", cmd_remove))
    app.add_handler(CommandHandler("reissue", cmd_reissue))
    # /invite and /unclaim disabled along with the claim flow.
    # app.add_handler(CommandHandler("invite", cmd_invite))
    # app.add_handler(CommandHandler("unclaim", cmd_unclaim))
    app.add_handler(CommandHandler("export", cmd_export))

    # Admin: VM
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("audit", cmd_audit))
    app.add_handler(CommandHandler("logs", cmd_logs))
    app.add_handler(CommandHandler("reboot", cmd_reboot))
    app.add_handler(CommandHandler("shutdown", cmd_shutdown))
    app.add_handler(CommandHandler("restart", cmd_restart))
    app.add_handler(CommandHandler("update", cmd_update))
    app.add_handler(CommandHandler("digest", cmd_digest))

    # Meta
    app.add_handler(CommandHandler("whoami", cmd_whoami))
    app.add_handler(CommandHandler("help", cmd_help))

    # Everything else
    app.add_handler(MessageHandler(filters.ALL, cmd_unknown))

    # Global error handler — every handler exception lands here
    app.add_error_handler(_on_error)

    log.info("wg-admin-bot starting (admin paired: %s)", config.admin_id() is not None)
    # drop_pending_updates=False: if the bot crashes, messages stay in
    # Telegram's queue so we don't silently lose pairing attempts.
    app.run_polling(poll_interval=0.0, timeout=30, drop_pending_updates=False)


if __name__ == "__main__":
    main()
