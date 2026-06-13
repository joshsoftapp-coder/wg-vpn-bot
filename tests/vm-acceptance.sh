#!/usr/bin/env bash
# vm-acceptance.sh — interactive v0.3.0 acceptance tests, run ON the VM.
#
# Covers checklist items 5–13 (the VM-side parts). Pauses for the manual
# confirmations (Telegram messages, second-terminal SSH).
#
# Usage (as root):
#   sudo bash vm-acceptance.sh              # main run (T1–T6, T8): ~20 min
#   sudo bash vm-acceptance.sh post-reboot  # T7: run after /reboot YES
#   sudo bash vm-acceptance.sh soak         # T9: run any time, e.g. after 48h
#
# The main run stops/kills the bot repeatedly and ends with everything
# restored. Item 5's EXTERNAL half (./audit-external.sh) runs from the
# laptop, not here.

set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0 ${1:-}" >&2
  exit 2
fi

UNIT=wg-admin-bot
green=$'\033[32m'; red=$'\033[31m'; yel=$'\033[33m'; bold=$'\033[1m'; rst=$'\033[0m'
pass=0; fail=0; declare -a failures=()

PASS() { pass=$((pass+1)); printf '%s  PASS%s  %s\n' "$green" "$rst" "$1"; }
FAIL() { fail=$((fail+1)); failures+=("$1"); printf '%s  FAIL%s  %s\n' "$red" "$rst" "$1"; }
note() { printf '%s        %s%s\n' "$yel" "$1" "$rst"; }
hdr()  { printf '\n%s── %s ──%s\n' "$bold" "$1" "$rst"; }

# Manual confirmation → recorded as PASS/FAIL.
ask() {
  local q="$1" a
  while :; do
    read -r -p "$(printf '%s  CHECK%s  %s [y/n] ' "$yel" "$rst" "$q")" a </dev/tty
    case "$a" in
      [Yy]) PASS "$q"; return 0 ;;
      [Nn]) FAIL "$q"; return 1 ;;
    esac
  done
}

pause() { read -r -p "$(printf '%s  ...%s  %s (Enter to continue) ' "$yel" "$rst" "$1")" _ </dev/tty; }

# Wait until a command succeeds, up to $1 seconds. Prints dots.
wait_for() {
  local secs="$1"; shift
  local deadline=$(( $(date +%s) + secs ))
  while (( $(date +%s) < deadline )); do
    if "$@" >/dev/null 2>&1; then echo; return 0; fi
    printf '.'; sleep 5
  done
  echo; return 1
}

bot_pid() { systemctl show "$UNIT" -p MainPID --value; }
bot_active() { systemctl is-active --quiet "$UNIT"; }
n_restarts() { systemctl show "$UNIT" -p NRestarts --value; }

restore() {
  systemctl unmask "$UNIT" >/dev/null 2>&1 || true
  systemctl start "$UNIT" >/dev/null 2>&1 || true
}
trap restore EXIT

summary() {
  hdr "Summary"
  printf '%s%d passed%s, ' "$green" "$pass" "$rst"
  if (( fail == 0 )); then printf '%s0 failed%s\n' "$green" "$rst"; else
    printf '%s%d failed%s:\n' "$red" "$fail" "$rst"
    for f in "${failures[@]}"; do printf '  %s✗%s %s\n' "$red" "$rst" "$f"; done
  fi
  (( fail == 0 ))
}

# ============================================================
# Subcommand: post-reboot (T7 / checklist #11)
# ============================================================
if [[ "${1:-}" == "post-reboot" ]]; then
  hdr "T7 — post-reboot regression (#11)"

  if python3 -c "
import yaml, sys
cfg = yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))
sys.exit(0 if (cfg.get('admin') or {}).get('user_id') else 1)" 2>/dev/null; then
    PASS "config.yaml survived reboot (admin still paired)"
  else
    FAIL "config.yaml lost admin user_id — REBOOT-WIPE REGRESSION"
  fi

  if python3 -c "
import json, sys
s = json.load(open('/var/lib/wg-admin-bot/state.json'))
sys.exit(0 if (s.get('peer_names') or {}) else 1)" 2>/dev/null; then
    PASS "state.json survived reboot (peer_names present)"
  else
    FAIL "state.json peer_names empty — REBOOT-WIPE REGRESSION"
  fi

  systemctl is-active --quiet wg-quick@wg0 \
    && PASS "wg-quick@wg0 active after reboot" \
    || FAIL "wg-quick@wg0 not active after reboot"

  if wait_for 120 bot_active; then
    PASS "$UNIT active after reboot"
  else
    FAIL "$UNIT not active within 120s of script start"
  fi

  npeers=$(wg show wg0 peers 2>/dev/null | grep -c . || echo 0)
  (( npeers >= 1 )) && PASS "kernel has $npeers peer(s)" || FAIL "kernel has no peers"

  ask "Toggle WireGuard on your phone — does it handshake and pass traffic?"
  ask "Did the bot send its startup ping after the reboot?"
  summary; exit $?
fi

# ============================================================
# Subcommand: soak (T9 / checklist #13)
# ============================================================
if [[ "${1:-}" == "soak" ]]; then
  hdr "T9 — soak report (#13)"
  up_since=$(systemctl show "$UNIT" -p ActiveEnterTimestamp --value)
  echo "Bot active since:        $up_since"
  echo "NRestarts (this boot):   $(n_restarts)   (expect 0 or only your test kills)"
  wd=$(journalctl -u "$UNIT" --no-pager 2>/dev/null | grep -ci 'watchdog' || true)
  echo "Watchdog events logged:  $wd   (expect 0 outside tests)"
  oom=$(journalctl -u "$UNIT" --no-pager 2>/dev/null | grep -ci 'oom\|Memory' || true)
  echo "Memory/OOM events:       $oom  (expect 0)"
  echo
  systemctl list-timers --no-pager | grep -E 'wg-(vm-)?digest|disk-check' || true
  echo
  ask "Have the daily digests arrived on schedule since the last run?"
  summary; exit $?
fi

# ============================================================
# Main run: T1–T6, T8
# ============================================================
cat <<EOF
${bold}wg-vpn-bot v0.3.0 acceptance — main run${rst}
Takes ~20 minutes (the watchdog test alone waits up to ~6 minutes).
The bot will be killed and masked along the way; everything is restored
at the end (and on Ctrl-C). Keep Telegram open.
EOF
pause "Ready"

# ---------- T1: internal audit (#5) ----------
hdr "T1 — internal security audit (#5)"
if wg-bot-audit --summary | grep -qE '^SUMMARY [0-9]+ 0$'; then
  PASS "wg-bot-audit: 0 failures"
else
  FAIL "wg-bot-audit reported failures — run 'sudo wg-bot-audit' for detail"
fi
note "Remember the laptop half: ./audit-external.sh PROJECT_ID"

# ---------- unit config sanity (#12 config half of T3) ----------
hdr "T2 — unit configuration (#12/#13 plumbing)"
[[ "$(systemctl show $UNIT -p Type --value)" == "notify" ]] \
  && PASS "Type=notify" || FAIL "Type is not notify"
wd_usec=$(systemctl show $UNIT -p WatchdogUSec --value)
[[ "$wd_usec" == "5min" || "$wd_usec" == "300000000" ]] \
  && PASS "WatchdogSec=300" || FAIL "WatchdogUSec=$wd_usec (want 5min)"
sl=$(systemctl show $UNIT -p StartLimitIntervalUSec --value)
[[ "$sl" == "0" ]] \
  && PASS "StartLimitIntervalSec=0 (never gives up)" || FAIL "StartLimitIntervalUSec=$sl (want 0)"
mm=$(systemctl show $UNIT -p MemoryMax --value)
[[ "$mm" == "314572800" ]] \
  && PASS "MemoryMax=300M" || FAIL "MemoryMax=$mm (want 314572800)"
bot_active && PASS "bot currently active" || FAIL "bot not active at test start"

# ---------- T3: watchdog hang detection (#6) ----------
hdr "T3 — watchdog kills a hung bot (#6) — up to ~6 min"
ts1=$(systemctl show $UNIT -p WatchdogTimestampMonotonic --value)
note "waiting 70s for a watchdog ping..."
sleep 70
ts2=$(systemctl show $UNIT -p WatchdogTimestampMonotonic --value)
[[ -n "$ts2" && "$ts2" != "$ts1" ]] \
  && PASS "watchdog pings advancing (60s cadence)" \
  || FAIL "watchdog timestamp not advancing — bot may not be sending WATCHDOG=1"

r0=$(n_restarts); pid0=$(bot_pid)
note "freezing bot pid $pid0 with SIGSTOP; systemd should kill+restart within ~5 min"
kill -STOP "$pid0"
if wait_for 420 bash -c "[[ \$(systemctl show $UNIT -p NRestarts --value) -gt $r0 ]]"; then
  PASS "systemd detected the hang and restarted the bot (NRestarts $r0 → $(n_restarts))"
else
  kill -CONT "$pid0" 2>/dev/null || true
  FAIL "no restart within 420s of SIGSTOP — watchdog not firing"
fi
journalctl -u $UNIT -n 100 --no-pager | grep -qi 'watchdog' \
  && PASS "journal shows watchdog timeout event" \
  || FAIL "no watchdog event in journal"
wait_for 90 bot_active || true
ask "Did a fresh '🟢 wg-admin-bot online' ping arrive in Telegram?"

# ---------- T4: never gives up + crash notifier (#7, #2 fix) ----------
hdr "T4 — crash loop recovery + crash notifier (#7)"
note "killing the bot 3× (RestartSec=30, so ~2 min)"
killed=0
for _ in 1 2 3; do
  wait_for 90 bash -c "[[ \$(systemctl show $UNIT -p MainPID --value) -gt 0 ]]" || break
  kill -9 "$(bot_pid)" 2>/dev/null && killed=$((killed+1))
  sleep 3
done
(( killed == 3 )) && PASS "delivered 3 kills" || FAIL "only delivered $killed/3 kills"
if wait_for 90 bot_active; then
  PASS "bot auto-restarted after every kill; unit never entered failed state"
else
  FAIL "bot did not return to active after kill loop"
fi
ask "Did '🔴 wg-admin-bot crashed' notifications arrive in Telegram? (previously these were silently dropped)"

# ---------- T5: notifier direct (#8) ----------
hdr "T5 — crash notifier, direct invocation (#8)"
systemctl start wg-admin-bot-onfailure \
  && PASS "onfailure unit ran without error" \
  || FAIL "onfailure unit failed — systemctl status wg-admin-bot-onfailure"
ask "Did the crash message arrive in Telegram just now?"

# ---------- T6: FIFO non-blocking + login alert (#9) ----------
hdr "T6 — dead bot must not hang SSH or watchers (#9)"
systemctl mask --now "$UNIT" >/dev/null 2>&1
if wait_for 30 bash -c "! systemctl is-active --quiet $UNIT"; then
  PASS "bot masked+stopped (graceful shutdown can take a few seconds)"
else
  FAIL "could not stop the bot within 30s"
fi

note "forced FIFO write with no reader: timeout must cap it at ~5s, not hang"
t0=$(date +%s)
printf 'ROUTINE|accept_test|fifo non-block acceptance test\n' \
  | timeout 5 tee /run/wg-bot.fifo >/dev/null 2>&1
dt=$(( $(date +%s) - t0 ))
if (( dt <= 7 )); then
  PASS "blocked FIFO write capped at ${dt}s (would previously hang forever)"
else
  FAIL "FIFO write took ${dt}s — timeout guard not effective"
fi
timeout 20 systemctl start wg-bot-disk-check \
  && PASS "disk-check unit returns with bot dead" \
  || FAIL "disk-check unit hung/failed with bot dead"

cat <<EOF

  Now, ${bold}from your laptop in a SECOND terminal${rst}, SSH into this VM:
    gcloud compute ssh <VM> --project=<PROJECT> --zone=<ZONE> --tunnel-through-iap
  The bot is DEAD right now — before this fix, that login would hang.
EOF
pause "Do the SSH login now, then come back"
ask "Did the SSH login complete promptly (a few seconds, no hang)?"

systemctl unmask "$UNIT" >/dev/null 2>&1
systemctl start "$UNIT"
wait_for 90 bot_active \
  && PASS "bot restored and active" || FAIL "bot did not come back after unmask"
pause "SSH in from the laptop ONCE MORE (bot now alive) to test the login alert"
ask "Did the '🔐 SSH login' alert arrive in Telegram (may batch up to ~1 min)?"

# ---------- T7: digest dead-man (#10) ----------
hdr "T7 — digest reports dead bot (#10)"
systemctl stop "$UNIT"
systemctl start wg-vm-digest \
  && PASS "wg-vm-digest ran with bot stopped (independent path)" \
  || FAIL "wg-vm-digest failed to run"
ask "Did the VM digest arrive showing 'Bot: 🔴 INACTIVE'?"
systemctl start "$UNIT"
wait_for 90 bot_active && PASS "bot restarted" || FAIL "bot did not restart"
ask "Send /digest in Telegram — does it now show 'Bot: 🟢 active'?"

# ---------- T8: auto-reboot policy (#12) ----------
hdr "T8 — unattended-upgrades auto-reboot policy (#12)"
ar=$(apt-config dump Unattended-Upgrade::Automatic-Reboot 2>/dev/null | grep -o '"true"' || true)
[[ -n "$ar" ]] && PASS "Automatic-Reboot=true parsed by apt" || FAIL "Automatic-Reboot not set/parsed"
art=$(apt-config dump Unattended-Upgrade::Automatic-Reboot-Time 2>/dev/null | grep -o '"04:00"' || true)
[[ -n "$art" ]] && PASS "Automatic-Reboot-Time=04:00" || FAIL "Automatic-Reboot-Time not 04:00"
unattended-upgrade --dry-run >/dev/null 2>&1 \
  && PASS "unattended-upgrade dry-run executes cleanly" \
  || FAIL "unattended-upgrade dry-run errored"

# ---------- wrap ----------
summary
st=$?
cat <<EOF

Remaining manual items:
  • #11 reboot: send /reboot YES in Telegram, wait ~2 min, then run:
      sudo bash $0 post-reboot
  • #13 soak: after 48h untouched, run:
      sudo bash $0 soak
  • #5 external half (from laptop): ./audit-external.sh PROJECT_ID
EOF
exit $st
