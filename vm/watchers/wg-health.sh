#!/bin/bash
# Called from wg-quick@wg0.service OnFailure=.
# Reports the failure and attempts a restart.

set -euo pipefail

FIFO=/run/wg-bot.fifo
[[ -p "$FIFO" ]] || exit 0

STATE=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo unknown)
printf '%s\n' "CRITICAL|wg_down|🔴 WireGuard state: ${STATE} on $(hostname). Attempting restart." \
  > "$FIFO" 2>/dev/null || true

systemctl restart wg-quick@wg0 2>&1 | tee -a /var/log/wg-admin-bot/wg-restart.log || true
sleep 3
STATE2=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo unknown)
if [[ "$STATE2" == "active" ]]; then
  printf '%s\n' "ROUTINE|wg_recovered|🟢 WireGuard recovered." \
    > "$FIFO" 2>/dev/null || true
else
  printf '%s\n' "CRITICAL|wg_dead|🟥 WireGuard restart FAILED on $(hostname). Manual intervention required." \
    > "$FIFO" 2>/dev/null || true
fi
