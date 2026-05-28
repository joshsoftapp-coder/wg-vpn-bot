"""
CLI used by VM startup script for first-peer creation.

Invoked as wgbot:
    /opt/wg-admin-bot/venv/bin/python3 /opt/wg-admin-bot/cli.py add-peer <name>
"""
from __future__ import annotations

import sys

import state
import wg_cmds


def cmd_add_peer(name: str) -> int:
    try:
        peer = wg_cmds.add(name)
    except (ValueError, RuntimeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    state.set_("first_peer_secret", {
        "name": peer.name,
        "private_key": peer.private_key,
        "preshared_key": peer.preshared_key,
        "allowed_ips": peer.allowed_ips,
    })
    print(f"created peer {peer.name} ({peer.allowed_ips})")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: cli.py add-peer <name>", file=sys.stderr)
        return 64
    if sys.argv[1] == "add-peer" and len(sys.argv) == 3:
        return cmd_add_peer(sys.argv[2])
    print("usage: cli.py add-peer <name>", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main())
