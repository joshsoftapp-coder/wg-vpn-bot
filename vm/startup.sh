#!/bin/bash
# VM bootstrap. GCP runs this on EVERY VM start (not just first boot).
# First-boot-only sections are guarded with explicit checks.

set -euo pipefail
exec > >(tee -a /var/log/wg-vpn-bot-startup.log) 2>&1

echo "[$(date)] VM bootstrap starting"

BUNDLE=/opt/wg-vpn-bot
[[ -d "$BUNDLE" ]] || { echo "FATAL: $BUNDLE missing"; exit 1; }

# ---------- packages ----------
echo "[$(date)] apt update + install"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  wireguard wireguard-tools \
  python3 python3-pip python3-venv \
  qrencode iptables jq \
  unattended-upgrades

# ---------- remove unused base-image packages ----------
# exim4 is a mail daemon shipped with Debian that serves no purpose here.
# Remove it to eliminate upgrade noise and the class of dpkg-script failure
# that can occur when apt runs non-interactively without DEBIAN_FRONTEND set.
# bsd-mailx depends on exim4 and is equally unused. || true: if a future
# Debian image ships without these, the purge exits non-zero — don't abort.
apt-get purge -y -qq \
  exim4 exim4-base exim4-config exim4-daemon-light bsd-mailx || true
apt-get autoremove -y -qq || true

# ---------- ip forwarding ----------
cat > /etc/sysctl.d/99-wg-forward.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-wg-forward.conf

# ---------- timezone (VM stays in UTC; digest uses laptop TZ via systemd) ----------
# We deliberately do NOT set the VM's timezone; the digest timer carries
# its own TZ via OnCalendar=. VM logs in UTC keep things simple.

# ---------- unattended security upgrades ----------
# Automatic-Reboot: kernel/libc security updates only take effect after a
# reboot. Off, a months-running VM accumulates downloaded-but-unbooted
# kernels. Reboots are safe (all config/state writes are first-boot-guarded)
# and cost ~60s of VPN downtime at 04:00 UTC.
# Filename must have NO extension: apt silently ignores unknown extensions
# (".local" was ignored for the project's whole life — caught by acceptance
# tests). "51" sorts after the package's 50unattended-upgrades so our
# values win.
cat > /etc/apt/apt.conf.d/51wg-vpn-bot <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
rm -f /etc/apt/apt.conf.d/50unattended-upgrades.local
systemctl enable --now unattended-upgrades

# ---------- apt conffile policy ----------
# Keep the existing config file on conflict, never prompt. The bot no longer
# runs apt (the /update command was removed in v0.3.0), but this policy is
# kept for unattended-upgrades: without it, packages whose upgrade would
# raise a conffile prompt are held back indefinitely.
cat > /etc/apt/apt.conf.d/90wg-bot-noninteractive <<'EOF'
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
}
EOF

# ---------- wgbot system user ----------
if ! id wgbot &>/dev/null; then
  useradd --system --home /var/lib/wg-admin-bot --create-home \
    --shell /usr/sbin/nologin wgbot
fi

install -d -o wgbot -g wgbot -m 0750 /var/lib/wg-admin-bot
install -d -o wgbot -g wgbot -m 0750 /var/log/wg-admin-bot
install -d -o root  -g wgbot -m 0750 /etc/wg-admin-bot

# ---------- bot code ----------
# Only copy and pip-install on first boot. On reboot the installed code is
# already in place; re-copying is harmless but pip install takes ~30s.
if [[ ! -d /opt/wg-admin-bot/venv ]]; then
  install -d -o root -g root -m 0755 /opt/wg-admin-bot
  cp -r "$BUNDLE/bot/." /opt/wg-admin-bot/
  chown -R root:root /opt/wg-admin-bot
  chmod -R 0755 /opt/wg-admin-bot

  # ---------- python venv ----------
  python3 -m venv /opt/wg-admin-bot/venv
  /opt/wg-admin-bot/venv/bin/pip install --quiet --no-cache-dir \
    -r /opt/wg-admin-bot/requirements.txt
  echo "[$(date)] first boot: installed bot code and python venv"
else
  echo "[$(date)] subsequent boot: bot code already installed, skipping"
fi

# ---------- config & state ----------
# CRITICAL: guard these with a first-boot check.
# GCP runs this startup script on EVERY VM start (not just first boot).
# Without the guard, every reboot overwrites config.yaml (wiping the
# paired admin_user_id) and state.json (wiping peer names).
# Sentinel: if config.yaml already exists with a non-null admin.user_id,
# the VM has been through pairing — skip both copies.
_CONFIG_TARGET=/etc/wg-admin-bot/config.yaml
if [[ ! -f "$_CONFIG_TARGET" ]] || \
   python3 -c "
import yaml, sys
cfg = yaml.safe_load(open('$_CONFIG_TARGET'))
sys.exit(0 if cfg.get('admin',{}).get('user_id') is None else 1)
" 2>/dev/null; then
  # First boot (or config absent / not yet paired): safe to copy template.
  cp "$BUNDLE/config.yaml" "$_CONFIG_TARGET"
  chown root:wgbot "$_CONFIG_TARGET"
  chmod 0660 "$_CONFIG_TARGET"

  # state.json: also only initialise on first boot.
  # On subsequent boots, state.json holds peer_names and other runtime data
  # we must not wipe.
  install -o wgbot -g wgbot -m 0600 /dev/null /var/lib/wg-admin-bot/state.json
  echo '{}' > /var/lib/wg-admin-bot/state.json
  chown wgbot:wgbot /var/lib/wg-admin-bot/state.json
  echo "[$(date)] first boot: initialised config.yaml and state.json"
else
  # Subsequent boot: preserve existing config (has live admin_user_id etc.)
  # but re-apply ownership/mode in case a previous bad write changed them.
  chown root:wgbot "$_CONFIG_TARGET"
  chmod 0660 "$_CONFIG_TARGET"
  echo "[$(date)] subsequent boot: preserved existing config.yaml and state.json"
fi

# audit.log: create only if absent. `install /dev/null` truncates, so this
# MUST be guarded — without the guard every reboot wipes the audit trail.
[[ -f /var/log/wg-admin-bot/audit.log ]] || \
  install -o wgbot -g wgbot -m 0640 /dev/null /var/log/wg-admin-bot/audit.log

# ---------- helper script ----------
install -m 0755 "$BUNDLE/wg-helpers/reset-admin.sh" /usr/local/sbin/wg-bot-reset-admin
install -m 0755 "$BUNDLE/wg-helpers/wg-bot-doctor" /usr/local/sbin/wg-bot-doctor
install -m 0755 "$BUNDLE/wg-helpers/wg-bot-audit" /usr/local/sbin/wg-bot-audit
install -m 0755 "$BUNDLE/wg-helpers/crash-notify.py" /usr/local/sbin/wg-bot-crash-notify

# ---------- sudoers (install EARLY, before any sudo calls) ----------
install -m 0440 -o root -g root "$BUNDLE/sudoers.d/wgbot" /etc/sudoers.d/wgbot
visudo -c -f /etc/sudoers.d/wgbot || { echo "FATAL: bad sudoers"; rm /etc/sudoers.d/wgbot; exit 1; }

# ---------- wg server config ----------
# CRITICAL: set the directory mode BEFORE creating wg0.conf inside it.
# Debian's wireguard package ships /etc/wireguard at 0700 root:root, which
# blocks the wgbot user from traversing the directory.
#
# 750 (not 770) is sufficient because the bot writes wg0.conf in place,
# not via .tmp + rename. wgbot needs traverse + list on the directory,
# but doesn't need write access on the directory itself.
chgrp wgbot /etc/wireguard
chmod 750 /etc/wireguard

WG_SUBNET=$(python3 -c "import yaml; print(yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))['wireguard']['subnet'])")
WG_PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))['wireguard']['port'])")
SERVER_IP=$(echo "$WG_SUBNET" | awk -F. '{print $1"."$2"."$3".1"}')
FIRST_PEER=$(python3 -c "import yaml; print(yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))['first_peer']['name'])")

if [[ ! -f /etc/wireguard/wg0.conf ]]; then
  echo "[$(date)] generating WireGuard server config"

  # Detect the actual outbound network interface. GCP Debian 12 uses ens4,
  # others may use eth0 or enp*. Hardcoding eth0 silently breaks NAT.
  WAN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
  if [[ -z "$WAN_IFACE" ]]; then
    echo "FATAL: could not detect outbound network interface"
    ip addr || true
    ip route || true
    exit 1
  fi
  echo "[$(date)] outbound interface: $WAN_IFACE"

  umask 077
  SERVER_PRIV=$(wg genkey)
  echo "$SERVER_PRIV" > /etc/wireguard/server.key
  chmod 600 /etc/wireguard/server.key

  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
SaveConfig = false
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IFACE} -j MASQUERADE
EOF
fi
# Apply ownership and mode that survive (the wg-save-restore wrapper
# re-applies these after every wg-quick save call).
chown root:wgbot /etc/wireguard/wg0.conf
chmod 660 /etc/wireguard/wg0.conf

# ---------- wg-save-restore helper ----------
# wg-quick save rewrites wg0.conf with default umask (077) and strips our
# group ownership. This wrapper runs save and then restores the perms we
# need atomically as root.
cat > /usr/local/sbin/wg-save-restore <<'EOF'
#!/bin/sh
set -e
/usr/bin/wg-quick save wg0
/bin/chown root:wgbot /etc/wireguard/wg0.conf
/bin/chmod 660 /etc/wireguard/wg0.conf
EOF
chmod 755 /usr/local/sbin/wg-save-restore

# ---------- FIFO via tmpfiles.d (survives reboot) ----------
# /run is tmpfs; the bot can't mkfifo there as wgbot. Pre-create at boot.
cat > /etc/tmpfiles.d/wg-admin-bot.conf <<'EOF'
# type path                mode uid    gid    age arg
p     /run/wg-bot.fifo     0622 wgbot  wgbot  -   -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/wg-admin-bot.conf

systemctl enable wg-quick@wg0
systemctl start  wg-quick@wg0

# Verify wg-quick actually started — bail loudly if not.
if ! systemctl is-active --quiet wg-quick@wg0; then
  echo "FATAL: wg-quick@wg0 failed to start"
  systemctl status wg-quick@wg0 --no-pager -l || true
  journalctl -u wg-quick@wg0 -n 50 --no-pager || true
  exit 1
fi

# ---------- first peer ----------
# Use the bot's CLI to create the first peer the same way subsequent peers
# will be created. Run as wgbot. A failure here is fatal — the installer's
# pairing flow depends on the stashed first-peer secret.
#
# Detection MUST consult the authoritative name map in state.json, NOT a
# '# name:' comment in wg0.conf. wg-quick save strips all comments on every
# call, so the comment never survives past the first peer op — checking for
# it would make this block run on EVERY boot, and add() would then raise
# "already exists", tripping the FATAL branch on every reboot.
#
# We also treat "the kernel already has at least one peer" as "first peer
# done". This covers the rare case where state.json was lost but the WG
# interface still carries the original peer: re-running add() there would
# mint a duplicate peer (new key/IP) and orphan the original. If you truly
# want a fresh first peer after total state loss, uninstall + reinstall.
_STATE_TARGET=/var/lib/wg-admin-bot/state.json
_first_peer_present() {
  # 0 (true) if the first peer is already accounted for.
  sudo -u wgbot python3 -c "
import json, sys
try:
    s = json.load(open('$_STATE_TARGET'))
except (OSError, ValueError):
    s = {}
names = (s.get('peer_names') or {}).values()
if '${FIRST_PEER}' in names:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null && return 0
  # state.json didn't confirm it; fall back to kernel membership.
  local n
  n=$(/usr/bin/wg show wg0 peers 2>/dev/null | grep -c .)
  [[ "${n:-0}" -ge 1 ]]
}

if ! _first_peer_present; then
  echo "[$(date)] creating first peer: $FIRST_PEER"
  if ! sudo -u wgbot /opt/wg-admin-bot/venv/bin/python3 \
       /opt/wg-admin-bot/cli.py add-peer "$FIRST_PEER"; then
    echo "FATAL: first-peer creation failed"
    ls -la /etc/wireguard/ || true
    sudo -u wgbot stat /etc/wireguard/wg0.conf || true
    sudo -u wgbot /opt/wg-admin-bot/venv/bin/python3 -c \
      "import wg_cmds; print(wg_cmds.list_peers())" 2>&1 || true
    exit 1
  fi
else
  echo "[$(date)] first peer already present, skipping"
fi

# ---------- systemd units ----------
cp "$BUNDLE/systemd/wg-admin-bot.service"             /etc/systemd/system/
cp "$BUNDLE/systemd/wg-admin-bot-onfailure.service"   /etc/systemd/system/
cp "$BUNDLE/systemd/wg-vm-digest.service"             /etc/systemd/system/
cp "$BUNDLE/systemd/wg-vm-digest.timer"               /etc/systemd/system/
cp "$BUNDLE/systemd/wg-digest.service"                /etc/systemd/system/
cp "$BUNDLE/systemd/wg-digest.timer"                  /etc/systemd/system/

# Rewrite digest timers with the configured TZ + time
DIGEST_TZ=$(python3 -c "import yaml; print(yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))['timezone'])")
VM_TIME=$(python3 -c "import yaml; print(yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))['digest']['vm_time'])")
WG_TIME=$(python3 -c "import yaml; print(yaml.safe_load(open('/etc/wg-admin-bot/config.yaml'))['digest']['wg_time'])")

sed -i "s|OnCalendar=.*|OnCalendar=*-*-* ${VM_TIME}:00 ${DIGEST_TZ}|" \
  /etc/systemd/system/wg-vm-digest.timer
sed -i "s|OnCalendar=.*|OnCalendar=*-*-* ${WG_TIME}:00 ${DIGEST_TZ}|" \
  /etc/systemd/system/wg-digest.timer

systemctl daemon-reload
systemctl enable --now wg-admin-bot.service
systemctl enable --now wg-vm-digest.timer
systemctl enable --now wg-digest.timer

# ---------- watchers ----------
install -m 0755 "$BUNDLE/watchers/ssh-login.sh"  /usr/local/sbin/wg-bot-ssh-login
install -m 0755 "$BUNDLE/watchers/disk-check.sh" /usr/local/sbin/wg-bot-disk-check
install -m 0755 "$BUNDLE/watchers/wg-health.sh"  /usr/local/sbin/wg-bot-wg-health

# PAM hook for SSH login alerts
# Anchored guard: the rule must exist as a real (non-comment) line. The
# Google OS Login section ends the file WITHOUT a trailing newline, so a
# bare `echo >>` glues the rule onto their closing comment — PAM then
# never sees it (found by acceptance testing: SSH alerts silently dead).
# The newline guard fixes the append; the anchored grep also repairs a
# previously-glued file on the next boot (the old garbage stays inside a
# comment, harmless).
if ! grep -qE '^session[[:space:]]+optional[[:space:]]+pam_exec\.so[[:space:]]+/usr/local/sbin/wg-bot-ssh-login' /etc/pam.d/sshd; then
  [ -n "$(tail -c1 /etc/pam.d/sshd)" ] && echo >> /etc/pam.d/sshd
  echo "session optional pam_exec.so /usr/local/sbin/wg-bot-ssh-login" >> /etc/pam.d/sshd
fi

# Disk check timer
cat > /etc/systemd/system/wg-bot-disk-check.service <<'EOF'
[Unit]
Description=wg-bot disk check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-bot-disk-check
EOF
cat > /etc/systemd/system/wg-bot-disk-check.timer <<'EOF'
[Unit]
Description=wg-bot disk check (hourly)
[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now wg-bot-disk-check.timer

# wg-quick OnFailure hook (calls wg-health watcher)
mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
cat > /etc/systemd/system/wg-quick@wg0.service.d/onfailure.conf <<'EOF'
[Unit]
OnFailure=wg-bot-wg-down.service
EOF
cat > /etc/systemd/system/wg-bot-wg-down.service <<'EOF'
[Unit]
Description=wg-bot wg-down handler
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-bot-wg-health
EOF
systemctl daemon-reload

echo "[$(date)] VM bootstrap complete"
systemctl --no-pager status wg-admin-bot.service || true
