#!/usr/bin/env bash
# audit-external.sh — security audit from OUTSIDE the VM (run on your laptop).
#
# Verifies the VM's attack surface as seen from the public internet and from
# the GCP control plane. Does NOT require SSH; uses gcloud + network probes.
#
# Usage:  ./audit-external.sh PROJECT_ID [VM_NAME] [ZONE]
#         PROJECT_ID            required
#         VM_NAME               optional (default: PROJECT_ID)
#         ZONE                  optional (default: discovered from the VM)
#
# Exit code: 0 = all PASS, 1 = one or more FAIL.

set -uo pipefail

IAP_RANGE="35.235.240.0/20"
WG_PORT="51820"

PROJECT_ID="${1:-}"
VM_NAME="${2:-${PROJECT_ID}}"
ZONE="${3:-}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "usage: $0 PROJECT_ID [VM_NAME] [ZONE]" >&2
  exit 2
fi

pass=0; fail=0
green=$'\033[32m'; red=$'\033[31m'; yel=$'\033[33m'; dim=$'\033[2m'; rst=$'\033[0m'
PASS() { printf '%s  PASS%s  %s\n' "$green" "$rst" "$1"; pass=$((pass+1)); }
FAIL() { printf '%s  FAIL%s  %s\n' "$red"   "$rst" "$1"; fail=$((fail+1)); }
WARN() { printf '%s  WARN%s  %s\n' "$yel"   "$rst" "$1"; }
INFO() { printf '%s        %s%s\n' "$dim" "$1" "$rst"; }

echo "── External audit: project=$PROJECT_ID vm=$VM_NAME ──"
echo

command -v gcloud >/dev/null || { echo "gcloud not found"; exit 2; }

# Discover zone + external IP -------------------------------------------------
if [[ -z "$ZONE" ]]; then
  ZONE=$(gcloud compute instances list --project="$PROJECT_ID" \
          --filter="name=$VM_NAME" --format="value(zone)" 2>/dev/null | head -1)
fi
if [[ -z "$ZONE" ]]; then
  FAIL "Could not find VM '$VM_NAME' in project '$PROJECT_ID'."
  echo; echo "Summary: $pass passed, $fail failed."; exit 1
fi

EXT_IP=$(gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)
INFO "zone=$ZONE external_ip=${EXT_IP:-none}"
echo

# 1. No firewall rule allows tcp:22 from outside the IAP range ----------------
bad22=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
  --filter="allowed.ports=22" \
  --format="csv[no-heading](name,sourceRanges.list())" 2>/dev/null \
  | grep -v "$IAP_RANGE" || true)
if [[ -z "$bad22" ]]; then
  PASS "No firewall rule allows tcp:22 from outside the IAP range."
else
  FAIL "Firewall rule(s) allow tcp:22 from outside IAP:"
  while IFS= read -r line; do INFO "$line"; done <<< "$bad22"
  INFO "Fix: gcloud compute firewall-rules delete <name> --project=$PROJECT_ID"
fi

# 2. default-allow-ssh / default-allow-rdp must not exist ---------------------
for rule in default-allow-ssh default-allow-rdp; do
  if gcloud compute firewall-rules describe "$rule" \
       --project="$PROJECT_ID" >/dev/null 2>&1; then
    FAIL "$rule still exists (permissive default rule)."
  else
    PASS "$rule absent."
  fi
done

# 3. Exactly the expected ingress rules exist ---------------------------------
ingress=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
  --filter="direction=INGRESS" --format="value(name)" 2>/dev/null | sort | tr '\n' ' ')
INFO "ingress rules: ${ingress:-none}"
if echo "$ingress" | grep -q "wg-allow-vpn" && echo "$ingress" | grep -q "wg-allow-ssh-iap"; then
  PASS "Expected rules present (wg-allow-vpn, wg-allow-ssh-iap)."
else
  FAIL "Expected rules missing."
fi

# 4. WG UDP rule is correct (port + open to internet) -------------------------
wgrule=$(gcloud compute firewall-rules describe wg-allow-vpn \
  --project="$PROJECT_ID" \
  --format="value(allowed[0].ports[0],sourceRanges[0])" 2>/dev/null)
if [[ "$wgrule" == "${WG_PORT}"*"0.0.0.0/0"* ]] || [[ "$wgrule" == *"${WG_PORT}"*"0.0.0.0/0"* ]]; then
  PASS "WireGuard rule allows udp:${WG_PORT} from internet."
else
  WARN "WireGuard rule looks unexpected: $wgrule"
fi

# 5. Live probe: TCP 22 must NOT complete a handshake from here ---------------
#    (We are not in the IAP range, so a connect MUST fail/timeout.)
if [[ -n "$EXT_IP" ]]; then
  if command -v nc >/dev/null; then
    if nc -z -w5 "$EXT_IP" 22 >/dev/null 2>&1; then
      FAIL "TCP 22 on $EXT_IP accepted a connection from this host (should be blocked)."
    else
      PASS "TCP 22 on $EXT_IP is not reachable from this host."
    fi
  else
    # Fallback: bash /dev/tcp with a timeout
    if timeout 5 bash -c "echo > /dev/tcp/$EXT_IP/22" >/dev/null 2>&1; then
      FAIL "TCP 22 on $EXT_IP accepted a connection (should be blocked)."
    else
      PASS "TCP 22 on $EXT_IP is not reachable from this host."
    fi
  fi
fi

# 6. WireGuard UDP reachability — interpreted correctly -----------------------
#    WireGuard is silent by design: it never replies to an unauthenticated
#    packet. So a UDP "port scan" can NEVER prove it is up, and a closed
#    result does NOT prove it is down. We therefore do NOT pass/fail on a UDP
#    scan. The firewall check (#4) is the authoritative control-plane signal;
#    real confirmation is a peer completing a handshake (see internal audit).
if [[ -n "$EXT_IP" ]] && command -v nc >/dev/null; then
  INFO "UDP $WG_PORT probe (informational only — WG never answers scans):"
  if nc -u -z -w3 "$EXT_IP" "$WG_PORT" >/dev/null 2>&1; then
    INFO "  socket reported open|filtered (expected; not a proof of health)"
  else
    INFO "  no UDP response (expected for WireGuard; not a proof of failure)"
  fi
  INFO "  Authoritative check: confirm a peer handshake in the internal audit."
fi

# 7. No other ports exposed by firewall --------------------------------------
others=$(gcloud compute firewall-rules list --project="$PROJECT_ID" \
  --filter="direction=INGRESS AND sourceRanges=0.0.0.0/0" \
  --format="csv[no-heading](name,allowed[].map().firewall_rule().list())" 2>/dev/null \
  | grep -viE "udp:${WG_PORT}|wg-allow-vpn" || true)
if [[ -z "$others" ]]; then
  PASS "No unexpected ports open to 0.0.0.0/0."
else
  FAIL "Unexpected internet-facing rules:"
  while IFS= read -r line; do INFO "$line"; done <<< "$others"
fi

echo
echo "── Summary: ${pass} passed, ${fail} failed ──"
[[ "$fail" -eq 0 ]]
