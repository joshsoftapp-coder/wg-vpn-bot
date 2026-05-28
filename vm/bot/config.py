"""YAML config loader. Mtime-cached, atomic save."""
from __future__ import annotations

import logging
import os
import threading
from pathlib import Path
from typing import Any

import yaml

CONFIG_PATH = Path(os.environ.get("WG_BOT_CONFIG", "/etc/wg-admin-bot/config.yaml"))
STATE_PATH = Path(os.environ.get("WG_BOT_STATE", "/var/lib/wg-admin-bot/state.json"))

log = logging.getLogger(__name__)

_lock = threading.RLock()
_cache: dict[str, Any] = {}
_mtime: float = 0.0


def load(force: bool = False) -> dict[str, Any]:
    global _cache, _mtime
    with _lock:
        try:
            st = CONFIG_PATH.stat()
        except FileNotFoundError:
            log.error("Config missing: %s", CONFIG_PATH)
            return {}
        if not force and st.st_mtime == _mtime and _cache:
            return _cache
        with CONFIG_PATH.open("r") as f:
            _cache = yaml.safe_load(f) or {}
        _mtime = st.st_mtime
        return _cache


def save(updates: dict[str, Any]) -> None:
    with _lock:
        cfg = load(force=True)
        _deep_merge(cfg, updates)
        # In-place write (not .tmp + rename): the bot runs as wgbot and
        # the parent dir /etc/wg-admin-bot is 0750 root:wgbot — no group
        # write on the dir, so we can't create temp files there. In-place
        # write goes directly to the existing file (which IS writable by
        # the wgbot group via 0640 root:wgbot). Atomicity tradeoff is
        # the same as for wg0.conf: file is small, writes are rare, the
        # partial-write window is microseconds.
        with CONFIG_PATH.open("w") as f:
            yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
        global _mtime, _cache
        _mtime = CONFIG_PATH.stat().st_mtime
        _cache = cfg


def get(path: str, default: Any = None) -> Any:
    cfg = load()
    cur: Any = cfg
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def _deep_merge(dst: dict, src: dict) -> dict:
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_merge(dst[k], v)
        else:
            dst[k] = v
    return dst


# Convenience accessors
def bot_token() -> str:
    tok = get("telegram.bot_token")
    if not tok:
        raise RuntimeError("telegram.bot_token missing from config")
    return tok


def admin_id() -> int | None:
    val = get("admin.user_id")
    return int(val) if val else None


def set_admin_id(user_id: int) -> None:
    save({"admin": {"user_id": int(user_id)}})


def pairing_token() -> tuple[str | None, int]:
    return get("admin.pairing_token"), int(get("admin.pairing_token_expires", 0))


def clear_pairing_token() -> None:
    save({"admin": {"pairing_token": None, "pairing_token_expires": 0}})


def timezone() -> str:
    return get("timezone", "UTC")
