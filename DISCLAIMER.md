# Disclaimer & Security

## What this is

A hobby tool that deploys standard WireGuard on Google Cloud and wires up
a Telegram bot to manage it. It is not a commercial product, a managed
service, or a custom VPN implementation — it configures standard WireGuard
with no modifications to its encryption or tunneling.

## Cost

You are responsible for your GCP billing. The free tier covers one e2-micro
in specific US regions, 30 GB disk, and 1 GB outbound per month.

- Traffic over 1 GB/month: ~$0.12/GB charged to your billing account
- Static IP while VM is stopped: ~$7/month
- Non-US region: not free

Run `./uninstall.sh` when not in use. Monitor your GCP billing console.

## No warranty

Provided as-is under the MIT License. The authors accept no liability for
data loss, service interruption, or unexpected charges.

## Security model

**What is defended:**
- Only UDP/51820 is exposed to the internet
- SSH requires Google IAP — port 22 is closed to the public internet
- The bot ignores all Telegram messages from non-admin users
- The bot runs as an unprivileged system user with a scoped sudo allowlist
- Destructive commands require explicit `YES` confirmation
- Peer private keys are never stored on the server

**Weakest link:** your Telegram account. It is the only authentication
factor for destructive commands. Enable Telegram two-step verification
(Settings → Privacy and Security → Two-Step Verification).

**Known limitations:**
- Admin commands transit Telegram's servers in cleartext to them
- The bot token and WireGuard server private key are stored in plaintext
  on the VM. If the VM is compromised, run `./uninstall.sh && ./install.sh`
  and rotate the bot token via @BotFather
- All peers can reach each other on the WireGuard subnet — no per-peer
  firewall rules

## Reporting security issues

Open a private issue on the
[repository](https://github.com/joshsoftapp-coder/wg-vpn-bot) rather than
a public bug report.
