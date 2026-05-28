"""Small JSON state store for runtime data (peer chat_ids, invites, etc)."""
from __future__ import annotations

import json
import threading
from typing import Any

from config import STATE_PATH

_lock = threading.RLock()


def _read() -> dict[str, Any]:
    if not STATE_PATH.exists():
        return {}
    try:
        with STATE_PATH.open("r") as f:
            return json.load(f) or {}
    except (json.JSONDecodeError, OSError):
        return {}


def _write(data: dict[str, Any]) -> None:
    # In-place write (not .tmp + rename) — same rationale as config.py and
    # wg_cmds.py: avoids needing write access on the parent directory, and
    # preserves the existing file's ownership and mode across writes.
    with STATE_PATH.open("w") as f:
        json.dump(data, f, indent=2)


def get(key: str, default: Any = None) -> Any:
    with _lock:
        return _read().get(key, default)


def set_(key: str, value: Any) -> None:
    with _lock:
        d = _read()
        d[key] = value
        _write(d)


def update(key: str, mutator) -> Any:
    with _lock:
        d = _read()
        new = mutator(d.get(key))
        d[key] = new
        _write(d)
        return new


def delete(key: str) -> None:
    with _lock:
        d = _read()
        if key in d:
            del d[key]
            _write(d)
