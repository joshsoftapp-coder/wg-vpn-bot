#!/bin/bash
# Called from wg-quick@wg0.service OnFailure=.
# Reports the failure and attempts a restart.

set -euo pipefail

FIFO=/run/wg-bot.fifo

# Opening a FIFO for write blocks until a reader exists; timeout keeps a
# dead bot from hanging this handler.
fifo_send() {
  [[ -p "$FIFO" ]] || return 0
  printf '%s\n' "$1" | timeout 2 tee "$FIFO" >/dev/null 2>&1 || true
}

STATE=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo unknown)
fifo_send "CRITICAL|wg_down|🔴 WireGuard state: ${STATE} on $(hostname). Attempting restart."

systemctl restart wg-quick@wg0 2>&1 | tee -a /var/log/wg-admin-bot/wg-restart.log || true
sleep 3
STATE2=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo unknown)
if [[ "$STATE2" == "active" ]]; then
  fifo_send "ROUTINE|wg_recovered|🟢 WireGuard recovered."
else
  fifo_send "CRITICAL|wg_dead|🟥 WireGuard restart FAILED on $(hostname). Manual intervention required."
fi
