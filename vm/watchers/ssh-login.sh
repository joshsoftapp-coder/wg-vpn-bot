#!/bin/bash
# Fired from /etc/pam.d/sshd via pam_exec on every session open.
# Writes a critical alert to the bot's FIFO.

set -euo pipefail

USER="${PAM_USER:-?}"
RHOST="${PAM_RHOST:-?}"
TYPE="${PAM_TYPE:-?}"

[[ "$TYPE" == "open_session" ]] || exit 0

SOURCE_NOTE=""
if [[ "$RHOST" =~ ^35\.235\.(24[0-9]|25[0-5])\. ]]; then
  SOURCE_NOTE=" (via Google IAP)"
fi

FIFO=/run/wg-bot.fifo
[[ -p "$FIFO" ]] || exit 0

# timeout is load-bearing here: opening a FIFO for write blocks until a
# reader exists. pam_exec waits for this script — without the timeout, a
# dead bot would HANG every SSH login, exactly when you SSH in to fix it.
printf '%s\n' "CRITICAL|ssh_login|🔐 SSH login: ${USER}@$(hostname) from ${RHOST}${SOURCE_NOTE}" \
  | timeout 2 tee "$FIFO" >/dev/null 2>&1 || true
