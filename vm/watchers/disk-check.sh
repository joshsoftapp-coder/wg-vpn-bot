#!/bin/bash
# Runs hourly via systemd timer. Emits routine or critical alerts.
set -euo pipefail

FIFO=/run/wg-bot.fifo
[[ -p "$FIFO" ]] || exit 0

PCT=$(df --output=pcent / | tail -1 | tr -d ' %')
[[ -z "$PCT" ]] && exit 0

if (( PCT >= 95 )); then
  printf '%s\n' "CRITICAL|disk_crit|🟥 Disk at ${PCT}% on $(hostname) — clean up or expand." \
    > "$FIFO" 2>/dev/null || true
elif (( PCT >= 85 )); then
  printf '%s\n' "ROUTINE|disk_warn|🟧 Disk at ${PCT}% on $(hostname)." \
    > "$FIFO" 2>/dev/null || true
fi
