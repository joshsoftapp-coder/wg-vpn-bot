#!/bin/bash
# Runs hourly via systemd timer. Emits routine or critical alerts.
set -euo pipefail

FIFO=/run/wg-bot.fifo

# Opening a FIFO for write BLOCKS until a reader exists. If the bot is down,
# an unguarded write would hang this oneshot forever (no default timeout),
# wedging its timer. timeout caps the wait; a lost alert while the bot is
# dead is unavoidable anyway.
fifo_send() {
  [[ -p "$FIFO" ]] || return 0
  printf '%s\n' "$1" | timeout 2 tee "$FIFO" >/dev/null 2>&1 || true
}

PCT=$(df --output=pcent / | tail -1 | tr -d ' %')
[[ -z "$PCT" ]] && exit 0

if (( PCT >= 95 )); then
  fifo_send "CRITICAL|disk_crit|🟥 Disk at ${PCT}% on $(hostname) — clean up or expand."
elif (( PCT >= 85 )); then
  fifo_send "ROUTINE|disk_warn|🟧 Disk at ${PCT}% on $(hostname)."
fi
