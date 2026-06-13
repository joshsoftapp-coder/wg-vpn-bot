# Guide

## For peers (VPN users)

Your admin sent you a `.conf` file or QR code. That's all you need.

**Phone:** Install the WireGuard app → tap **+** → **Create from QR code**
and scan, or **Create from file** and pick the `.conf` → toggle on.

**Computer:** Install WireGuard from [wireguard.com/install](https://www.wireguard.com/install/)
→ import the `.conf` file → activate.

To verify: visit [whatismyipaddress.com](https://whatismyipaddress.com) —
it should show the server's location, not yours.

If it stops working, toggle off and on. If that fails, ask your admin —
the server may have been rebuilt and you need a fresh config. If your
device is lost or stolen, tell your admin immediately so they can kill
your config and issue a new one.

---

## For the admin

### First-time install

**Prerequisites:** `gcloud` authenticated, `jq`, `curl`, bash 4+, a GCP
billing account, Telegram on your phone. Linux works as-is; macOS needs
`brew install bash` (picked up automatically); Windows is untested — use
WSL with `gcloud` installed inside it, at your own risk.

```bash
git clone https://github.com/joshsoftapp-coder/wg-vpn-bot
cd wg-vpn-bot
./install.sh
```

The installer asks for a project ID, region, bot token (create one via
@BotFather in Telegram), and a name for your first peer. It provisions
the VM and waits for the bot to come up (~5 min).

When done, find your bot in Telegram, press **Start**, then send:
```
/start PAIRING-TOKEN
```
The bot confirms pairing and sends your first peer's `.conf` and QR.
Scan it with the WireGuard app.

Token expired? SSH in and reset:
```bash
gcloud compute ssh VM_NAME --project=PROJECT_ID --zone=ZONE --tunnel-through-iap
sudo wg-bot-reset-admin
```

### Command reference

| Command | What it does |
|---|---|
| `/add NAME` | Create a peer. Bot DMs you `.conf` + QR to forward |
| `/reissue NAME` | New keypair, same name and IP. Old config dies |
| `/remove NAME YES` | Delete peer permanently |
| `/peers` | List all peers |
| `/peer NAME` | Peer detail: IP, key, transfer stats |
| `/status` | Uptime, memory, disk, WG state, public IP |
| `/logs wg\|ssh\|bot` | Tail the journal |
| `/reboot YES` | Reboot (~60s, peers reconnect automatically) |
| `/restart wg` | Restart WireGuard only |
| `/audit` | Security audit summary |
| `/digest` | On-demand status digest |

Security updates apply automatically (unattended-upgrades); the VM
reboots itself at 04:00 UTC when a kernel update requires it (~60s of
VPN downtime, peers reconnect automatically). There is no backup/export
command by design — recovery is rebuild (`./uninstall.sh` + `./install.sh`).

### Data costs (read this)

The free tier includes **1 GB of outbound traffic per month**; beyond that
it's ~$0.12/GB. The default peer config routes **all** your traffic through
the VPN (`AllowedIPs = 0.0.0.0/0`), so streaming video through it will blow
past 1 GB quickly. Two ways to stay free:

- **Android:** WireGuard app → edit tunnel → **Excluded applications** →
  exclude heavy apps (Netflix, YouTube, Zoom, Teams, ...). Their traffic
  bypasses the VPN; everything else stays tunneled. This is the cleanest
  split tunnel — no IP lists to maintain.
- Toggle the tunnel **on only when you need it** (one tap; iOS has no
  per-app exclusion, so this is the iOS answer).
- Advanced: replace `AllowedIPs` with a computed exclusion list of CIDRs.
  Note WireGuard routes by **IP, not domain** — you cannot exclude
  "netflix.com", and big services' IP ranges shift constantly, so prefer
  the two options above.

### SSH access

```bash
gcloud compute ssh VM_NAME --project=PROJECT_ID --zone=ZONE --tunnel-through-iap
```

Port 22 is closed to the internet. IAP requires your Google account.

### Diagnostics

```bash
sudo wg-bot-doctor            # full audit
sudo wg-bot-doctor --fix      # audit + apply safe fixes
sudo wg-bot-doctor --verbose  # show passing checks too
```

### Re-pair the admin

```bash
sudo wg-bot-reset-admin       # prints new token, restart bot
```

Send `/start NEW-TOKEN` from your Telegram account. Peers unaffected.

### When in doubt

```bash
./uninstall.sh PROJECT_ID
./install.sh
```
