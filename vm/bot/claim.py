"""
Peer invite/claim flow.

State layout in state.json:
  pending_invites: { token: {peer_name, expires} }
  peer_chat_ids:   { peer_name: user_id }
"""
from __future__ import annotations

import logging
import secrets
import time

import state
import wg_cmds

log = logging.getLogger(__name__)

INVITE_TTL_S = 30 * 60
TOKEN_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def gen_token() -> str:
    return "-".join(
        "".join(secrets.choice(TOKEN_CHARS) for _ in range(4))
        for _ in range(3)
    )


def create_invite(peer_name: str) -> str:
    """Create or replace a claim token for the given peer name."""
    if not wg_cmds.get_peer_by_name(peer_name):
        raise ValueError(f"Peer '{peer_name}' does not exist. Use /add {peer_name} first.")

    token = gen_token()
    expires = int(time.time()) + INVITE_TTL_S

    def mutate(cur):
        cur = cur or {}
        # Drop any previous unclaimed tokens for the same peer
        cur = {t: v for t, v in cur.items() if v.get("peer_name") != peer_name}
        # GC expired
        now = int(time.time())
        cur = {t: v for t, v in cur.items() if v.get("expires", 0) > now}
        cur[token] = {"peer_name": peer_name, "expires": expires}
        return cur
    state.update("pending_invites", mutate)
    return token


def try_claim(user_id: int, token: str) -> tuple[bool, str, str | None]:
    """
    Validate token and bind user_id to the peer. Returns (ok, message, peer_name).
    On success the invite is burned.
    """
    invites = state.get("pending_invites", {}) or {}
    inv = invites.get(token.strip())
    if not inv:
        return False, "No such invite, or it expired/was burned.", None
    if int(time.time()) >= inv.get("expires", 0):
        # GC expired token
        def mutate(cur):
            cur = cur or {}
            cur.pop(token.strip(), None)
            return cur
        state.update("pending_invites", mutate)
        return False, "Invite expired. Ask your admin for a new one.", None

    peer_name = inv["peer_name"]
    if not wg_cmds.get_peer_by_name(peer_name):
        return False, "Peer no longer exists. Ask your admin.", None

    # Bind chat_id and burn token
    def bind(cur):
        cur = cur or {}
        cur[peer_name] = int(user_id)
        return cur
    state.update("peer_chat_ids", bind)

    def burn(cur):
        cur = cur or {}
        cur.pop(token.strip(), None)
        return cur
    state.update("pending_invites", burn)

    return True, "ok", peer_name


def chat_id_for(peer_name: str) -> int | None:
    bindings = state.get("peer_chat_ids", {}) or {}
    v = bindings.get(peer_name)
    return int(v) if v else None


def unclaim(peer_name: str) -> bool:
    def mutate(cur):
        cur = cur or {}
        cur.pop(peer_name, None)
        return cur
    bindings = state.get("peer_chat_ids", {}) or {}
    if peer_name not in bindings:
        return False
    state.update("peer_chat_ids", mutate)
    return True


def remove_peer_bindings(peer_name: str) -> None:
    """Called when a peer is /removed — also drop chat_id binding and invites."""
    unclaim(peer_name)
    def mutate(cur):
        cur = cur or {}
        return {t: v for t, v in cur.items() if v.get("peer_name") != peer_name}
    state.update("pending_invites", mutate)
