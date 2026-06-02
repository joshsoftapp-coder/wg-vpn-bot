# Disclaimer & Security

## What this is

A simple tool that deploys standard WireGuard on Google Cloud and wires up a Telegram bot to manage it. It is not a commercial product, a managed service, or a custom VPN implementation — it configures standard WireGuard with no modifications to its encryption or tunneling.

## Cost

You are responsible for your GCP billing. The free tier covers one e2-micro in specific US regions, 30 GB disk, and 1 GB outbound per month.

- Outbound over 1 GB/month: \~$0.12/GB
- Static IP while VM is stopped: \~$7/month
- Non-US region: not free

Run `./uninstall.sh` when not in use. Monitor your GCP billing console.

## No warranty

Provided as-is under the MIT License. The authors accept no liability for data loss, service interruption, or unexpected charges.

## Security model

**What is defended:**

- Only UDP/51820 is exposed to the internet
- SSH requires Google IAP — port 22 is closed to the public internet
- The bot ignores all Telegram messages from non-admin users
- The bot runs as an unprivileged system user with a scoped sudo allowlist
- Destructive commands require explicit `YES` confirmation
- Peer private keys are never stored on the server

**Known limitations:**

- Admin commands transit Telegram's servers in cleartext to them
- All peers can reach each other on the WireGuard subnet — no per-peer firewall rules

## Compromise scenarios

**Compromised Telegram account** — an attacker gains full control of the bot and can reboot, shut down, add or remove peers. Mitigate in advance: enable Telegram two-step verification (Settings → Privacy and Security → Two-Step Verification). To recover a compromised account: [telegram.org/support](https://telegram.org/support)

**Compromised Google account** — an attacker can access the VM via IAP, re-pair the bot, and read the server config. Mitigate in advance: enable Google two-factor authentication. To recover a compromised account: [g.co/account-recovery](https://g.co/account-recovery)

**Compromised VM** — the bot token and WireGuard server key are on the VM in plaintext. What an attacker gets: the server identity, the bot token, and the peer name list. What they do not get: peer private keys (never stored on the server), browsing history, or credentials. Recovery is a full rebuild — you lose nothing except having to re-add peers:

```bash
./uninstall.sh PROJECT_ID
./install.sh
```

Rotate the bot token via @BotFather afterwards.

## Reporting security issues

Open a private issue on the [repository](https://github.com/joshsoftapp-coder/wg-vpn-bot) rather than a public bug report.