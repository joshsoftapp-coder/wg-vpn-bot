#!/bin/bash
# Reset admin: clear stored admin user_id, generate a new 30-min pairing token.
# Run as root: sudo wg-bot-reset-admin

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Must be run as root (use sudo)." >&2
  exit 1
fi

STATE=/var/lib/wg-admin-bot/state.json
CFG=/etc/wg-admin-bot/config.yaml

[[ -f "$STATE" ]] || { echo "State file not found: $STATE"; exit 1; }
[[ -f "$CFG"   ]] || { echo "Config not found: $CFG"; exit 1; }

gen_token() {
  python3 - <<'PY'
import secrets
chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
print("-".join("".join(secrets.choice(chars) for _ in range(4)) for _ in range(3)))
PY
}

TOKEN=$(gen_token)
EXPIRY=$(date -u -d '+30 minutes' +%s 2>/dev/null || date -u -v+30M +%s)

python3 - "$CFG" "$TOKEN" "$EXPIRY" <<'PY'
import sys, yaml
cfg_path, token, expiry = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(cfg_path) as f:
    cfg = yaml.safe_load(f)
cfg.setdefault("admin", {})
cfg["admin"]["user_id"] = None
cfg["admin"]["pairing_token"] = token
cfg["admin"]["pairing_token_expires"] = expiry
with open(cfg_path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY

# Clear all claim bindings too — admin reset is a full reset
python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
d["admin_user_id"] = None
d["peer_chat_ids"] = {}
d["pending_invites"] = {}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY

chown wgbot:wgbot "$STATE"
chmod 600 "$STATE"

systemctl restart wg-admin-bot.service

cat <<EOF

✓ Admin reset complete.

New pairing token (valid for 30 minutes):

    $TOKEN

Send to your bot:    /start $TOKEN

EOF
