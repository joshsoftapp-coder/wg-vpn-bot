"""
FIFO listener for watcher-emitted alerts.

Watchers write lines: SEVERITY|name|text
Critical → sent immediately.
Routine  → batched, flushed every 5 minutes (max 1 message, others queued).
"""
from __future__ import annotations

import asyncio
import logging
import os
import stat
import time
from pathlib import Path

log = logging.getLogger(__name__)

FIFO_PATH = Path("/run/wg-bot.fifo")
ROUTINE_BATCH_INTERVAL_S = 300


class AlertSink:
    def __init__(self, send_callable):
        self._send = send_callable
        self._routine_queue: list[tuple[str, str]] = []
        self._last_flush = time.time()

    async def critical(self, name: str, text: str) -> None:
        await self._send(text)

    async def routine(self, name: str, text: str) -> None:
        self._routine_queue.append((name, text))

    async def tick(self) -> None:
        if time.time() - self._last_flush < ROUTINE_BATCH_INTERVAL_S:
            return
        await self._flush()

    async def _flush(self) -> None:
        self._last_flush = time.time()
        if not self._routine_queue:
            return
        # Send first, queue rest for next batch
        first = self._routine_queue.pop(0)
        msg = first[1]
        if self._routine_queue:
            msg += f"\n\n(+{len(self._routine_queue)} more queued for next batch)"
        await self._send(msg)


def ensure_fifo() -> None:
    if FIFO_PATH.exists():
        if stat.S_ISFIFO(FIFO_PATH.stat().st_mode):
            return
        FIFO_PATH.unlink()
    os.mkfifo(FIFO_PATH, 0o622)
    os.chmod(FIFO_PATH, 0o622)


async def listen_fifo(sink: AlertSink) -> None:
    ensure_fifo()
    log.info("FIFO listener on %s", FIFO_PATH)
    fd = os.open(FIFO_PATH, os.O_RDONLY | os.O_NONBLOCK)
    try:
        buf = b""
        while True:
            try:
                chunk = os.read(fd, 4096)
                if chunk:
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        await _dispatch(sink, line.decode("utf-8", "replace").strip())
                else:
                    os.close(fd)
                    await asyncio.sleep(0.5)
                    fd = os.open(FIFO_PATH, os.O_RDONLY | os.O_NONBLOCK)
            except BlockingIOError:
                await asyncio.sleep(0.5)
            except Exception as e:
                log.error("FIFO read error: %s", e)
                await asyncio.sleep(1.0)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


async def _dispatch(sink: AlertSink, line: str) -> None:
    if not line:
        return
    parts = line.split("|", 2)
    if len(parts) != 3:
        log.warning("malformed FIFO line: %r", line)
        return
    sev, name, text = parts[0].strip().upper(), parts[1].strip(), parts[2]
    if sev == "CRITICAL":
        await sink.critical(name, text)
    elif sev == "ROUTINE":
        await sink.routine(name, text)
    else:
        log.warning("unknown severity %r", sev)
