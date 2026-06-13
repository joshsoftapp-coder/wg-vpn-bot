#!/usr/bin/env bash
#
# wg-vpn-bot installer
#
# Needs bash 4+ (Linux: works as-is; macOS: `brew install bash`;
# Windows: untested — try WSL with gcloud installed inside it).
# On macOS, `env bash` already resolves to homebrew's bash when brew is
# in PATH; if it isn't (system bash 3.2 picked up), re-exec with the
# homebrew binary directly (Apple Silicon, then Intel paths).
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for _hb in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_hb" ]; then exec "$_hb" "$0" "$@"; fi
  done
fi  # otherwise fall through — preflight prints the friendly bash-4+ error
# Creates a fresh GCP project + VM running WireGuard, managed via a Telegram bot.
# Designed for the GCP free tier (us-* regions). Single-admin, IAP-protected SSH.
#
# Usage:
#   ./install.sh              interactive
#   ./install.sh --dry-run    show what would happen, don't apply
#   ./install.sh --help

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ---------- constants ----------
SCRIPT_VERSION="0.3.0"
FREE_TIER_REGIONS=("us-west1" "us-central1" "us-east1")
DEFAULT_REGION="us-central1"
DEFAULT_ZONE_SUFFIX="-a"
DEFAULT_MACHINE_TYPE="e2-micro"
DEFAULT_DISK_SIZE_GB="30"
DEFAULT_IMAGE_FAMILY="debian-12"
DEFAULT_IMAGE_PROJECT="debian-cloud"
DEFAULT_WG_PORT="51820"
DEFAULT_WG_SUBNET="10.13.13.0/24"
IAP_SSH_RANGE="35.235.240.0/20"

# ---------- globals (populated by prompts) ----------
DRY_RUN="false"
HEX_SUFFIX=""
PROJECT_ID=""
ORG_ID=""
BILLING_ACCOUNT=""
REGION=""
ZONE=""
VM_NAME=""
BOT_TOKEN=""
BOT_USERNAME=""
FIRST_PEER=""
LAPTOP_TZ=""
PAIRING_TOKEN=""
LOG_FILE=""
GCLOUD_ACCOUNT=""
BOT_HEALTHY=""

# ---------- ui helpers ----------
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_cyan=$'\033[36m'; c_dim=$'\033[2m'

say()  { printf '%s\n' "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
info() { printf '%s\n' "${c_cyan}ℹ${c_reset} $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
ok()   { printf '%s\n' "${c_green}✓${c_reset} $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
warn() { printf '%s\n' "${c_yellow}⚠${c_reset} $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
err()  { printf '%s\n' "${c_red}✗${c_reset} $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
hdr()  { printf '\n%s\n\n' "${c_bold}── $* ──${c_reset}" | tee -a "${LOG_FILE:-/dev/null}" >&2; }

die() { err "$*"; exit 1; }

# Run a command, log it, skip if dry-run.
run() {
  printf '%s $ %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG_FILE"
  if [[ "$DRY_RUN" == "true" ]]; then
    info "${c_dim}(dry-run)${c_reset} $*"
    return 0
  fi
  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

# Capture stdout, also log.
run_capture() {
  printf '%s $ %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG_FILE"
  if [[ "$DRY_RUN" == "true" ]]; then
    info "${c_dim}(dry-run)${c_reset} $*" >&2
    return 0
  fi
  local out
  out=$("$@" 2>>"$LOG_FILE")
  printf '%s' "$out"
}

prompt() {
  local question="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s [%s]: ' "$question" "$default")" answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$(printf '%s: ' "$question")" answer
    printf '%s' "$answer"
  fi
}

confirm() {
  local question="$1" default="${2:-N}" answer
  local hint="[y/N]"; [[ "$default" =~ ^[Yy]$ ]] && hint="[Y/n]"
  read -r -p "$(printf '%s %s ' "$question" "$hint")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------- preflight ----------

preflight() {
  hdr "Preflight checks"

  command -v gcloud >/dev/null 2>&1 || die "gcloud not found. Install: https://cloud.google.com/sdk/docs/install"
  ok "gcloud installed"

  command -v jq >/dev/null 2>&1 || die "jq not found. Install: sudo apt install jq  /  brew install jq"
  ok "jq installed"

  command -v curl >/dev/null 2>&1 || die "curl not found."
  ok "curl installed"

  if (( BASH_VERSINFO[0] < 4 )); then
    die "Bash 4+ required (you have $BASH_VERSION). On macOS: brew install bash"
  fi
  ok "bash $BASH_VERSION"

  GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
  if [[ -z "$GCLOUD_ACCOUNT" || "$GCLOUD_ACCOUNT" == "(unset)" ]]; then
    die "Not authenticated to gcloud. Run: gcloud auth login"
  fi
  ok "Authenticated as $GCLOUD_ACCOUNT"

  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    warn "Application-default credentials not set."
    if confirm "Run 'gcloud auth application-default login' now?" Y; then
      gcloud auth application-default login
    fi
  fi

  # Detect laptop timezone for digest scheduling
  if [[ -L /etc/localtime ]]; then
    LAPTOP_TZ=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif command -v timedatectl >/dev/null 2>&1; then
    LAPTOP_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  fi
  LAPTOP_TZ="${LAPTOP_TZ:-UTC}"
  ok "Detected laptop timezone: $LAPTOP_TZ"
}

# ---------- intro ----------

show_intro() {
  cat <<EOF | tee -a "$LOG_FILE"

${c_bold}wg-vpn-bot installer v${SCRIPT_VERSION}${c_reset}

This will create a WireGuard VPN server on Google Cloud:
  • A new GCP project with one e2-micro VM running Debian 12
  • Managed via a Telegram bot you create (or reuse)
  • SSH protected by Google IAP (no public port 22)
  • Install time: ~10 minutes

${c_yellow}${c_bold}COST WARNING${c_reset}
The GCP free tier covers one e2-micro VM in us-west1/us-central1/us-east1,
30 GB disk, and 1 GB outbound traffic/month. Rules change.

  ${c_bold}You are responsible for any charges.${c_reset}

A static external IP attached to a running VM is free. If you STOP the
VM but leave the static IP reserved, GCP charges ~\$7/month for it.
Best practice: when not using the VPN, run ./uninstall.sh — it deletes
the project, which is reversible for 30 days.

Verify current free-tier limits: https://cloud.google.com/free

EOF
  confirm "Proceed?" Y || die "Cancelled."
}

# ---------- random hex ----------

gen_hex() {
  od -An -N2 -tx1 /dev/urandom | tr -d ' \n'
}

# ---------- gcp project ----------

create_new_project() {
  hdr "GCP project"

  HEX_SUFFIX=$(gen_hex)
  local default_id="wg-vpn-$HEX_SUFFIX"
  PROJECT_ID=$(prompt "New project ID" "$default_id")

  choose_org
}

choose_org() {
  local orgs_json org_count
  orgs_json=$(gcloud organizations list --format=json 2>>"$LOG_FILE" || echo "[]")
  org_count=$(echo "$orgs_json" | jq 'length')

  if (( org_count == 0 )); then
    info "No organizations found — project will be created under 'No organization'."
    info "${c_yellow}Note:${c_reset} in Cloud Console, select 'No organization' from the org picker to see it."
    ORG_ID=""
    return
  fi

  echo "Available organizations:"
  echo "$orgs_json" | jq -r '.[] | "  \(.name | sub("organizations/"; ""))  \(.displayName)"'
  echo "  (or enter 'none' for No organization)"
  echo

  if (( org_count == 1 )); then
    local single_org single_name
    single_org=$(echo "$orgs_json" | jq -r '.[0].name | sub("organizations/"; "")')
    single_name=$(echo "$orgs_json" | jq -r '.[0].displayName')
    if confirm "Create under '$single_name' ($single_org)?" Y; then
      ORG_ID="$single_org"
    else
      ORG_ID=""
    fi
  else
    local pick
    pick=$(prompt "Organization ID (or 'none')" "none")
    if [[ "$pick" == "none" ]]; then
      ORG_ID=""
    else
      ORG_ID="$pick"
    fi
  fi
}

apply_project_create() {
  hdr "Creating project $PROJECT_ID"
  if [[ -n "$ORG_ID" ]]; then
    run gcloud projects create "$PROJECT_ID" --organization="$ORG_ID"
  else
    run gcloud projects create "$PROJECT_ID"
  fi
  ok "Project created."
}

# ---------- billing ----------

link_billing() {
  hdr "Billing account"

  local billing_json count
  billing_json=$(gcloud billing accounts list --filter="open=true" --format=json 2>>"$LOG_FILE" || echo "[]")
  count=$(echo "$billing_json" | jq 'length')

  if (( count == 0 )); then
    err "No open billing accounts found."
    err "Set one up: https://console.cloud.google.com/billing"
    die "Cannot proceed without a billing account."
  fi

  if (( count == 1 )); then
    BILLING_ACCOUNT=$(echo "$billing_json" | jq -r '.[0].name | sub("billingAccounts/"; "")')
    info "Auto-linking the only billing account: $BILLING_ACCOUNT"
  else
    echo "Open billing accounts:"
    echo "$billing_json" | jq -r '.[] | "  \(.name | sub("billingAccounts/"; ""))  \(.displayName)"'
    BILLING_ACCOUNT=$(prompt "Billing account ID")
  fi

  run gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" \
    || die "Failed to link billing. Check permissions for $BILLING_ACCOUNT."
  ok "Billing linked."
}

# ---------- region / zone / vm name ----------

choose_region() {
  hdr "Region and zone"
  info "Free-tier eligible regions (US only): ${FREE_TIER_REGIONS[*]}"
  info "If you need a region elsewhere (e.g. europe-west1, me-west1),"
  info "  type it — be aware it will not be free."

  REGION=$(prompt "Region" "$DEFAULT_REGION")
  local ok_region="false"
  for r in "${FREE_TIER_REGIONS[@]}"; do
    [[ "$r" == "$REGION" ]] && ok_region="true"
  done
  if [[ "$ok_region" != "true" ]]; then
    warn "$REGION is not in the free-tier list. This may incur charges."
    confirm "Continue?" N || die "Cancelled."
  fi

  ZONE="${REGION}${DEFAULT_ZONE_SUFFIX}"
  ok "Zone: $ZONE"
}

choose_vm_name() {
  VM_NAME=$(prompt "VM name" "wg-vpn-$HEX_SUFFIX")
}

choose_first_peer() {
  FIRST_PEER=$(prompt "First WireGuard peer name" "vpn-$HEX_SUFFIX")
  if [[ ! "$FIRST_PEER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
    die "Peer name must match ^[a-zA-Z0-9_-]{1,32}$"
  fi
}

# ---------- telegram bot ----------

choose_bot() {
  hdr "Telegram bot"

  cat <<EOF
You can either:
  1) Create a NEW Telegram bot (recommended for a fresh deployment)
  2) Reuse an EXISTING bot you've already created in @BotFather

${c_yellow}If you reuse an existing bot:${c_reset} that bot must not be running on any other
machine. Telegram delivers each message to whichever long-poller asks first,
so two running instances will randomly steal messages from each other.

EOF
  local choice
  choice=$(prompt "[N]ew or [E]xisting?" "N")

  if [[ "$choice" =~ ^[Ee] ]]; then
    cat <<EOF

To get the token of an existing bot:
  1. Open Telegram, message @BotFather
  2. Send: /token
  3. Pick the bot from the list
  4. Copy the token

EOF
  else
    guide_botfather_new
  fi

  while :; do
    BOT_TOKEN=$(prompt "Telegram bot token")
    if [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
      ok "Token format looks valid."
      break
    fi
    warn "Token format unexpected. Should look like 123456789:ABC..."
  done

  if [[ "$DRY_RUN" != "true" ]]; then
    verify_bot_token
  fi
}

guide_botfather_new() {
  local suggested_name="WG VPN ${HEX_SUFFIX} Bot"
  local suggested_username="wgvpn_${HEX_SUFFIX}_bot"

  cat <<EOF

To create a new bot:

  1. Open Telegram, search for: ${c_bold}@BotFather${c_reset}
  2. Send: ${c_bold}/newbot${c_reset}
  3. Name (suggested): ${c_bold}${suggested_name}${c_reset}
  4. Username, must end in 'bot' (suggested): ${c_bold}${suggested_username}${c_reset}
     (must be globally unique — try variants if taken)
  5. Copy the token BotFather sends you and paste below.

  Optional but recommended: enable Privacy Mode (default ON) and disable
  "Allow Groups" (BotFather → /mybots → Bot Settings).

EOF
}

verify_bot_token() {
  local resp
  resp=$(curl -s -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" || echo '{}')
  if ! echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    warn "Bot token did not validate against Telegram API."
    warn "Response: $(echo "$resp" | jq -c . 2>/dev/null || echo "$resp")"
    confirm "Continue anyway?" N || die "Cancelled."
    return
  fi
  BOT_USERNAME=$(echo "$resp" | jq -r '.result.username')
  ok "Bot verified: @${BOT_USERNAME}"

  # Detect existing usage: check if there are pending updates already
  local updates
  updates=$(curl -s -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=1" \
            | jq -r '.result | length' 2>/dev/null || echo 0)
  if [[ "${updates:-0}" -gt 0 ]]; then
    warn "Bot has pending updates — it may already be in use somewhere."
    warn "If you reused this bot, stop the other instance before continuing."
  fi
}

# ---------- gcp apis ----------

enable_apis() {
  hdr "Enabling required GCP APIs"
  local apis=(compute.googleapis.com iap.googleapis.com)
  for api in "${apis[@]}"; do
    run gcloud services enable "$api" --project="$PROJECT_ID"
  done
  ok "APIs enabled."
}

# ---------- firewall ----------

create_firewall() {
  hdr "Firewall rules"

  # GCP's default network ships with permissive built-in rules, including
  # default-allow-ssh (tcp:22 from 0.0.0.0/0 with NO target tag, so it
  # applies to every instance). Our wg-allow-ssh-iap rule is ADDITIVE, not a
  # replacement — firewall rules are a union, so the permissive default wins
  # and port 22 stays open to the whole internet. We must delete the default
  # permissive rules explicitly. default-allow-rdp is equally useless here.
  for rule in default-allow-ssh default-allow-rdp; do
    if gcloud compute firewall-rules describe "$rule" \
         --project="$PROJECT_ID" >/dev/null 2>&1; then
      run gcloud compute firewall-rules delete "$rule" \
        --project="$PROJECT_ID" --quiet
    fi
  done

  run gcloud compute firewall-rules create wg-allow-vpn \
    --project="$PROJECT_ID" \
    --direction=INGRESS --action=ALLOW \
    --rules="udp:${DEFAULT_WG_PORT}" \
    --source-ranges="0.0.0.0/0" \
    --target-tags=wg-vpn

  run gcloud compute firewall-rules create wg-allow-ssh-iap \
    --project="$PROJECT_ID" \
    --direction=INGRESS --action=ALLOW \
    --rules="tcp:22" \
    --source-ranges="$IAP_SSH_RANGE" \
    --target-tags=wg-vpn

  # Verify no rule other than ours permits tcp:22. If anything still allows
  # 22 from a non-IAP range, fail loudly rather than ship an open VM.
  #
  # Note: this check must never abort the script by itself. Under `set -e` a
  # command substitution that exits non-zero would kill us silently. We list
  # ALL port-22 rules (a simple, reliable filter) and inspect their source
  # ranges in the shell, appending '|| true' so a gcloud hiccup can't abort.
  local rules22 bad22=""
  rules22=$(gcloud compute firewall-rules list \
    --project="$PROJECT_ID" \
    --filter="allowed.ports~22" \
    --format="csv[no-heading](name,sourceRanges.list())" 2>/dev/null || true)
  if [[ -n "$rules22" ]]; then
    while IFS=, read -r rname rsrc; do
      [[ -z "$rname" ]] && continue
      # Anything whose source is not exactly the IAP range is a problem.
      if [[ "$rsrc" != "$IAP_SSH_RANGE" ]]; then
        bad22+="${rname} (${rsrc}) "
      fi
    done <<< "$rules22"
  fi
  if [[ -n "$bad22" ]]; then
    err "Firewall verification FAILED — these rules allow tcp:22 from outside"
    err "the IAP range: $bad22"
    err "Delete them:  gcloud compute firewall-rules delete <name> --project=$PROJECT_ID"
    exit 1
  fi

  ok "Firewall: WG/UDP open; SSH restricted to IAP range; no public port 22."
}

# ---------- iap iam ----------

grant_iap() {
  hdr "Granting IAP SSH access to $GCLOUD_ACCOUNT"
  run gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="user:$GCLOUD_ACCOUNT" \
    --role="roles/iap.tunnelResourceAccessor" \
    --condition=None

  run gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="user:$GCLOUD_ACCOUNT" \
    --role="roles/compute.instanceAdmin.v1" \
    --condition=None

  ok "IAP access granted."
}

# ---------- pairing token ----------

gen_pairing_token() {
  # /dev/urandom (not $RANDOM, which is a predictable LCG). Rejection
  # sampling: accept bytes 0..247 (8*31) so modulo 31 is unbiased.
  local chars="ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  local out="" byte
  while (( ${#out} < 12 )); do
    byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
    (( byte < 248 )) && out+="${chars:byte % 31:1}"
  done
  printf '%s-%s-%s' "${out:0:4}" "${out:4:4}" "${out:8:4}"
}

# ---------- vm creation ----------

create_vm() {
  hdr "Creating VM $VM_NAME"

  PAIRING_TOKEN=$(gen_pairing_token)
  local bundle_dir
  bundle_dir=$(mktemp -d)
  cp -r vm/* "$bundle_dir/"

  # Render config.yaml
  local expiry
  expiry=$(date -u -d '+30 minutes' +%s 2>/dev/null || date -u -v+30M +%s)
  cat > "$bundle_dir/config.yaml" <<EOF
# wg-vpn-bot config (v${SCRIPT_VERSION})
timezone: $LAPTOP_TZ
admin:
  user_id: null
  pairing_token: "$PAIRING_TOKEN"
  pairing_token_expires: $expiry
telegram:
  bot_token: "$BOT_TOKEN"
  bot_username: "$BOT_USERNAME"
wireguard:
  subnet: $DEFAULT_WG_SUBNET
  port: $DEFAULT_WG_PORT
  dns: [1.1.1.1, 1.0.0.1]
  interface: wg0
digest:
  enabled: true
  vm_time: "13:00"
  wg_time: "13:05"
first_peer:
  name: "$FIRST_PEER"
EOF

  # tar the bundle
  tar -C "$bundle_dir" -czf "$bundle_dir/bundle.tar.gz" \
    bot sudoers.d systemd watchers wg-helpers config.yaml startup.sh
  local bundle_b64
  bundle_b64=$(base64 < "$bundle_dir/bundle.tar.gz" | tr -d '\n')

  # cloud-init style startup
  cat > "$bundle_dir/cloud-init.sh" <<EOF
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/wg-vpn-bot-install.log) 2>&1
echo "[\$(date)] wg-vpn-bot bootstrap starting (v${SCRIPT_VERSION})"
mkdir -p /opt/wg-vpn-bot
echo "$bundle_b64" | base64 -d | tar -xz -C /opt/wg-vpn-bot
bash /opt/wg-vpn-bot/startup.sh
echo "[\$(date)] wg-vpn-bot bootstrap complete"
EOF

  # Reserve static IP first
  run gcloud compute addresses create "${VM_NAME}-ip" \
    --project="$PROJECT_ID" --region="$REGION"

  local ext_ip
  ext_ip=$(run_capture gcloud compute addresses describe "${VM_NAME}-ip" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(address)')
  ok "Reserved external IP: $ext_ip"

  run gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$DEFAULT_MACHINE_TYPE" \
    --image-family="$DEFAULT_IMAGE_FAMILY" \
    --image-project="$DEFAULT_IMAGE_PROJECT" \
    --boot-disk-size="${DEFAULT_DISK_SIZE_GB}GB" \
    --boot-disk-type=pd-standard \
    --tags=wg-vpn \
    --address="$ext_ip" \
    --metadata="enable-oslogin=TRUE,wg-vpn-version=$SCRIPT_VERSION,wg-vpn-external-ip=$ext_ip" \
    --metadata-from-file="startup-script=$bundle_dir/cloud-init.sh"

  rm -rf "$bundle_dir"

  ok "VM created. Waiting for first-boot script to finish (~3 min)..."
  if [[ "$DRY_RUN" != "true" ]]; then
    if ! wait_for_bot_ready; then
      err "VM is up but the bot is not healthy."
      err "The pairing token below may or may not work depending on the failure."
      err "Recommended: investigate via SSH, or ./uninstall.sh $PROJECT_ID and retry."
      # Don't `die` — we still want to print the pairing info and SSH command
      # so the user can troubleshoot. Just set a flag.
      BOT_HEALTHY="false"
    else
      BOT_HEALTHY="true"
    fi
  fi
}

wait_for_bot_ready() {
  local deadline=$(( $(date +%s) + 360 ))
  echo
  info "Waiting for VM bootstrap to finish (this may take 3-5 min)..."

  # Phase 1: VM is SSH-reachable
  while (( $(date +%s) < deadline )); do
    if gcloud compute ssh "$VM_NAME" \
         --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap \
         --command='echo ssh-ok' --quiet 2>/dev/null | grep -q '^ssh-ok$'; then
      ok "VM is SSH-reachable."
      break
    fi
    printf '.'
    sleep 10
  done

  # Phase 2: startup.sh has finished
  info "Waiting for first-boot bootstrap to complete..."
  while (( $(date +%s) < deadline )); do
    # Use exit code directly — much less brittle than parsing output through
    # gcloud's auxiliary warnings.
    if gcloud compute ssh "$VM_NAME" \
         --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap \
         --command='sudo grep -q "VM bootstrap complete" /var/log/wg-vpn-bot-startup.log 2>/dev/null' \
         --quiet 2>/dev/null; then
      ok "First-boot bootstrap finished."
      break
    fi
    printf '.'
    sleep 10
  done

  # Phase 3: bot is running AND has logged "Application started"
  info "Waiting for bot to report Application started..."
  while (( $(date +%s) < deadline )); do
    # Same trick: rely on exit code, not parsed output.
    if gcloud compute ssh "$VM_NAME" \
         --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap \
         --command='sudo journalctl -u wg-admin-bot --no-pager 2>/dev/null | grep -q "Application started"' \
         --quiet 2>/dev/null; then
      ok "Bot has started (Application started found in logs)."
      # Stability check: still active 10s later?
      sleep 10
      if gcloud compute ssh "$VM_NAME" \
         --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap \
         --command='systemctl is-active --quiet wg-admin-bot' \
         --quiet 2>/dev/null; then
        ok "Bot is stable."
        return 0
      fi
      warn "Bot started but is not stable."
      break
    fi
    printf '.'
    sleep 10
  done

  echo
  err "Bot didn't reach a healthy state within 6 minutes."
  echo
  warn "Last 50 lines of bot log:"
  gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap \
    --command='sudo journalctl -u wg-admin-bot -n 50 --no-pager 2>/dev/null' \
    --quiet 2>/dev/null || true
  echo
  warn "Last 30 lines of startup log:"
  gcloud compute ssh "$VM_NAME" \
    --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap \
    --command='sudo tail -30 /var/log/wg-vpn-bot-startup.log 2>/dev/null' \
    --quiet 2>/dev/null || true
  echo
  warn "To investigate further:"
  echo "  gcloud compute ssh $VM_NAME --project=$PROJECT_ID --zone=$ZONE --tunnel-through-iap"
  echo "  sudo journalctl -u wg-admin-bot -n 200"
  echo "  sudo cat /var/log/wg-vpn-bot-startup.log"
  return 1
}

# ---------- finale ----------

finale() {
  hdr "Done"
  local ext_ip="?"
  if [[ "$DRY_RUN" != "true" ]]; then
    ext_ip=$(gcloud compute addresses describe "${VM_NAME}-ip" \
      --project="$PROJECT_ID" --region="$REGION" --format='value(address)' 2>/dev/null || echo "?")
  fi

  if [[ "$BOT_HEALTHY" == "false" ]]; then
    cat <<EOF

${c_yellow}${c_bold}⚠ Installation completed, but the bot is not healthy.${c_reset}

  Project:        $PROJECT_ID
  VM:             $VM_NAME ($ZONE)
  External IP:    $ext_ip
  Bot:            @${BOT_USERNAME}

Logs were dumped above. Investigate via SSH:

  gcloud compute ssh $VM_NAME --project=$PROJECT_ID --zone=$ZONE --tunnel-through-iap

Common fixes once SSHed in:
  sudo systemctl restart wg-admin-bot
  sudo journalctl -u wg-admin-bot -f

Or start clean:
  exit                              # leave SSH
  ./uninstall.sh $PROJECT_ID
  ./install.sh

EOF
    return
  fi

  cat <<EOF

${c_green}${c_bold}✓ Installation complete.${c_reset}

  Project:        $PROJECT_ID
  VM:             $VM_NAME ($ZONE)
  External IP:    $ext_ip
  WireGuard port: ${DEFAULT_WG_PORT}/udp
  SSH:            IAP only (port 22 closed to public internet)
  Digest TZ:      $LAPTOP_TZ
  Bot:            @${BOT_USERNAME}
  Console:        https://console.cloud.google.com/home/dashboard?project=$PROJECT_ID

${c_bold}NEXT STEPS:${c_reset}

  1. Open Telegram, find your bot: ${c_bold}@${BOT_USERNAME}${c_reset}

  2. Press the ${c_bold}Start${c_reset} button (or send ${c_bold}/start${c_reset} with no argument).
     ${c_dim}Telegram requires this first message before letting you type.${c_reset}
     The bot will reply with a prompt for the pairing token.

  3. Now type and send this exact message:

       ${c_bold}${c_cyan}/start ${PAIRING_TOKEN}${c_reset}

  4. The bot will:
       • Confirm you are the admin
       • Send the config for peer '${FIRST_PEER}' (.conf + QR)
       • Send a command reference

  5. Scan the QR with the WireGuard mobile app. Connect.

${c_yellow}Pairing token expires in 30 minutes.${c_reset}
If it expires, SSH in and run:

  gcloud compute ssh $VM_NAME --project=$PROJECT_ID --zone=$ZONE --tunnel-through-iap
  sudo wg-bot-reset-admin

${c_dim}To uninstall everything: ./uninstall.sh $PROJECT_ID${c_reset}

EOF
}

# ---------- main ----------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN="true" ;;
      --help|-h)
        cat <<EOF
wg-vpn-bot installer v${SCRIPT_VERSION}

Usage:
  ./install.sh             interactive install
  ./install.sh --dry-run   show what would happen, don't change anything
  ./install.sh --help      this message

EOF
        exit 0 ;;
      *) die "Unknown flag: $1 (try --help)" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  [[ -d vm ]] || die "Run this script from the repo root (where ./vm/ lives)."

  LOG_FILE="./install-$(date +%Y%m%d-%H%M%S).log"
  : > "$LOG_FILE"
  info "Logging to $LOG_FILE"
  [[ "$DRY_RUN" == "true" ]] && warn "DRY RUN — no GCP resources will be modified."

  preflight
  show_intro
  create_new_project
  choose_region
  choose_vm_name
  choose_first_peer
  choose_bot

  hdr "Review"
  cat <<EOF
  Project ID:     $PROJECT_ID  (new)
  Organization:   ${ORG_ID:-No organization}
  Region/zone:    $REGION / $ZONE
  VM name:        $VM_NAME (e2-micro, 30 GB)
  First peer:     $FIRST_PEER
  Digest TZ:      $LAPTOP_TZ
  Bot:            @${BOT_USERNAME:-?} (token hidden)
EOF
  confirm "Apply these settings?" Y || die "Cancelled."

  apply_project_create
  link_billing
  enable_apis
  create_firewall
  grant_iap
  create_vm
  finale
}

main "$@"
