# SETUP.md — first-time install walkthrough

You'll go from "nothing" to "VPN running on a server, controllable from
Telegram" in about 10 minutes. About 2 minutes interactive, 8 minutes
waiting on Google Cloud.

For the day-to-day operator's guide afterwards, see [ADMIN.md](ADMIN.md).

## Before you start

You need:

- A **laptop or workstation** running Linux or macOS (bash 4+).
- A **Google account** with billing set up (i.e. one you can attach to
  a GCP billing account; a free-trial credit account works).
- The **Google Cloud SDK** (`gcloud`) installed and authenticated.
- **Telegram** installed on your phone.
- About **10 minutes**.

## Cost reality

The GCP free tier covers an `e2-micro` VM in `us-west1`, `us-central1`, or
`us-east1`, a 30 GB standard disk, and 1 GB/month of outbound traffic.
Read [cloud.google.com/free](https://cloud.google.com/free) — the rules
change. As of now, this setup is **$0/month for one user using ~1 GB of
traffic** anywhere outside Australia/China.

Things that *can* cost money:
- **More than 1 GB outbound traffic/month** — about $0.12/GB after that
- **Running in a non-US region** (e.g. europe, asia) — not free at all
- **Stopping the VM but keeping the static IP** — about $7/month for
  the idle IP. Either keep the VM running or `./uninstall.sh` entirely.

## Step 1 — install prerequisites on your laptop

### gcloud

```bash
# macOS
brew install --cask google-cloud-sdk

# Debian/Ubuntu
sudo apt install apt-transport-https ca-certificates gnupg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
  sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
sudo apt update && sudo apt install google-cloud-cli
```

Other platforms: <https://cloud.google.com/sdk/docs/install>

### jq, curl

```bash
# macOS
brew install jq curl
# Debian/Ubuntu
sudo apt install jq curl
```

### Authenticate

```bash
gcloud auth login
gcloud auth application-default login
```

Both will open a browser window. Sign in with the Google account you want
to own the VM.

Verify:
```bash
gcloud config get-value account
# should print your email
```

## Step 2 — get a billing account

You need an open GCP billing account. If you've used GCP before, you
probably have one already:
```bash
gcloud billing accounts list --filter="open=true"
```

If the list is empty, set one up at
<https://console.cloud.google.com/billing>. The installer will refuse to
proceed without one.

## Step 3 — create the Telegram bot (or pick an existing one)

### Option A: new bot (recommended)

1. Open Telegram, search for **@BotFather**, start a chat
2. Send `/newbot`
3. Pick a **name** (shown to users, can have spaces) — the installer will
   suggest something based on your hex suffix, like "WG VPN a3f9 Bot"
4. Pick a **username** (must end in `bot`, globally unique, no spaces) —
   the installer suggests `wgvpn_a3f9_bot` style
5. Copy the **token** BotFather sends. Looks like `123456789:ABC-DEF...`
6. Optional but recommended: BotFather → `/mybots` → your bot → "Bot
   Settings" → make sure Privacy Mode is ON (default)

### Option B: reuse an existing bot

Only do this if the bot is currently not running on any other machine.
Two long-pollers fight for messages and you'll get random behavior.

1. Message @BotFather: `/token`
2. Pick your existing bot from the list
3. Copy the token

The installer will ask which path you want and validate the token before
proceeding.

## Step 4 — clone and run the installer

```bash
git clone https://github.com/YOUR/wg-vpn-bot.git
cd wg-vpn-bot
./install.sh
```

(If you got the source as a tarball, just `tar xzf wg-vpn-bot.tar.gz &&
cd wg-vpn-bot`.)

The installer will:

1. **Preflight checks** — verify gcloud, jq, curl, your auth
2. **Show a cost warning** — confirm you've read it
3. **Project ID** — suggests `wg-vpn-<hex>`, you accept or change
4. **Organization** — if you have one, asks if you want to create the
   project under it. Otherwise creates under "No organization".
   - ⚠ Projects under "No organization" can be hard to find in Cloud
     Console — select "No organization" from the org picker top-left.
5. **Billing account** — auto-links if you have only one; otherwise
   shows the list to pick from
6. **Region** — defaults to `us-central1`, accepts any region. Warns if
   you pick a non-free-tier region.
7. **VM name** — defaults to `wg-vpn-<hex>`
8. **First peer name** — defaults to `vpn-<hex>` matching the VM. This
   will be your phone's config. Override to something more memorable
   if you like (e.g. `my-phone`).
9. **Telegram bot** — paste the token. Validates against the Telegram API.
10. **Review** — shows what's about to happen, asks "Apply?"

Then it applies:
- Creates the GCP project, links billing, enables APIs
- Sets up firewall (WG UDP open, SSH IAP-only)
- Grants you IAP SSH access
- Reserves a static IP
- Creates the VM with a startup script that installs WireGuard, Python,
  the bot, systemd units, watchers, sudoers, etc.
- Waits up to 6 minutes for the bot to come up

When done, you see:

```
✓ Installation complete.

  NEXT STEPS:

  1. Open Telegram, find your bot: @wgvpn_a3f9_bot

  2. Send this exact message to pair as admin:

       /start ABCD-EFGH-IJKL

  3. The bot will:
       • Confirm you are the admin
       • Send the config for peer 'vpn-a3f9' (.conf + QR)
       • Send a command reference

  4. Scan the QR with the WireGuard mobile app. Connect.
```

## Step 5 — pair as admin

In Telegram, find your bot.

**Telegram quirk:** the first time you open a chat with a new bot, the
text input is hidden and Telegram shows a **Start** button instead. You
must press Start (which sends a bare `/start`) before Telegram lets you
type. The bot will reply with a prompt — that's normal. After that, the
text input appears and you can type the real pairing message.

So the pairing flow is:

1. Find `@your_bot`, press **Start**. The bot replies with a "pairing
   needed" prompt.
2. Now you can type. Send `/start ABCD-EFGH-IJKL` (with the actual token
   from the installer output).

The bot replies with:
- ✅ Paired confirmation
- Your first peer's `.conf` file
- A QR code image
- The full command reference (matches [ADMIN.md](ADMIN.md))

The pairing token is single-use. After successful pairing, it's burned.

## Step 6 — install WireGuard on your phone, scan the QR

1. App Store / Play Store → search "WireGuard" → install the official app
   (icon is a stylized dragon)
2. Open the app → tap "+" → "Create from QR code"
3. Point your phone camera at the QR code on your laptop screen
4. Name the tunnel (e.g. "Home VPN")
5. Toggle it on

Test it: visit <https://whatismyipaddress.com>. It should show your VM's
public IP (which `/status` in the bot will confirm).

## Step 7 — verify a few things

In Telegram, send your bot:

```
/status
```

Expected: green WG, 1 peer, your public IP.

```
/peers
```

Expected: one peer named `vpn-a3f9` (or whatever you named it), with a
recent handshake.

You're done.

## Inviting other peers later

```
/add alice                 (bot DMs you alice's config; if she's nearby
                            you can scan her phone with the QR directly)

/invite alice              (bot gives you a token; send to Alice via any
                            channel; she opens the bot in Telegram and
                            runs /claim, then the bot DMs her the config)
```

The claim flow is preferred when Alice is remote — no config files need
to traverse insecure channels.

## What if something went wrong

### "Bot didn't report active within 6 minutes"

The installer prints how to investigate:

```bash
gcloud compute ssh VM_NAME --project=PROJECT_ID --zone=ZONE \
    --tunnel-through-iap --command='sudo journalctl -u wg-admin-bot -n 100'
```

Common causes:
- **First-boot script still running** — check
  `/var/log/wg-vpn-bot-install.log` and `/var/log/wg-vpn-bot-startup.log`
  on the VM
- **Bad bot token** — bot service will be in `Activating (auto-restart)`
- **pip install failing** — check internet from the VM with `curl
  https://pypi.org`

### "Pairing token expired"

It's only valid for 30 minutes. SSH in:
```bash
gcloud compute ssh VM_NAME --project=PROJECT_ID --zone=ZONE --tunnel-through-iap
sudo wg-bot-reset-admin
```

The script prints a new token. Send `/start NEW-TOKEN` to the bot.

### "I want to start over"

```bash
./uninstall.sh PROJECT_ID
```

This soft-deletes the GCP project (30-day recovery window). Then run
`./install.sh` again with whatever you want to change.

### "I made a typo in the bot username"

The bot username can't be changed after creation, but BotFather lets you
delete the bot (`/deletebot`) and create a new one. You'd then run
`./install.sh` again to deploy with the new bot — pick "new project" so
the old one gets cleaned up, or `./uninstall.sh` the old one first.

## What you've ended up with

After this is all done:

- One GCP project containing one VM with a static external IP
- WireGuard listening on UDP/51820, accessible from the public internet
- SSH on port 22 closed to the public internet, accessible only via Google
  IAP tunnel (which requires GCP auth)
- A `wgbot` system user running the Telegram bot under systemd, with a
  scoped sudo allowlist
- A `/etc/wireguard/wg0.conf` containing your server identity and one peer
- A daily VM digest at 13:00 local time, WG digest at 13:05
- Audit log at `/var/log/wg-admin-bot/audit.log` (365-day retention)
- Unattended security upgrades enabled (no automatic reboot)

The system has no exposed services other than the WireGuard UDP port.
There's no web UI, no admin API, no SSH from the internet. Telegram is
the only interaction channel.

If you find this strange, you're not wrong, but it's the point. The
attack surface from the public internet is one UDP port speaking the
WireGuard protocol, which is a known-good crypto handshake.
