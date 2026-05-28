#!/usr/bin/env bash
# wg-vpn-bot uninstaller
# Deletes the GCP project. Reversible for 30 days via `gcloud projects undelete`.

set -euo pipefail

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
c_green=$'\033[32m'; c_yellow=$'\033[33m'

die() { printf '%s\n' "${c_red}✗${c_reset} $*" >&2; exit 1; }
ok()  { printf '%s\n' "${c_green}✓${c_reset} $*" >&2; }

KEEP_VM="false"
PROJECT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-vm) KEEP_VM="true" ;;
    --help|-h)
      cat <<EOF
Usage: ./uninstall.sh PROJECT_ID [--keep-vm]

  PROJECT_ID    The GCP project to remove.
  --keep-vm     Only stop VMs; leave project, firewall, IP intact.
                Static IP costs ~\$7/month while reserved without a running VM.
EOF
      exit 0 ;;
    *) PROJECT_ID="$1" ;;
  esac
  shift
done

[[ -z "$PROJECT_ID" ]] && die "Usage: ./uninstall.sh PROJECT_ID [--keep-vm]"

gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 \
  || die "Project '$PROJECT_ID' not found or no access."

if [[ "$KEEP_VM" == "true" ]]; then
  printf '%s\n' "${c_yellow}Stopping VMs in $PROJECT_ID (resources preserved)...${c_reset}"
  vms=$(gcloud compute instances list --project="$PROJECT_ID" \
          --format='value(name,zone)' 2>/dev/null || true)
  if [[ -z "$vms" ]]; then
    ok "No VMs running."
  else
    while read -r name zone; do
      [[ -z "$name" ]] && continue
      gcloud compute instances stop "$name" --project="$PROJECT_ID" --zone="$zone" --quiet
      ok "Stopped $name"
    done <<< "$vms"
    printf '\n%s\n' "${c_yellow}Heads-up:${c_reset} the static external IP is still reserved (~\$7/mo)."
  fi
  exit 0
fi

cat <<EOF
${c_bold}${c_red}This will DELETE the project '$PROJECT_ID'.${c_reset}

  • All VMs, disks, IPs, firewall rules, and IAM bindings will be removed.
  • The project enters a 30-day soft-delete window.
  • You can recover within 30 days:
       gcloud projects undelete $PROJECT_ID
  • After 30 days the deletion is permanent.

EOF

read -r -p "Type the project ID to confirm: " confirm
[[ "$confirm" == "$PROJECT_ID" ]] || die "Mismatch — cancelled."

gcloud projects delete "$PROJECT_ID" --quiet
ok "Project $PROJECT_ID scheduled for deletion."
echo "Recover within 30 days with: gcloud projects undelete $PROJECT_ID"
