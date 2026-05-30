# wg-vpn-bot

Self-hosted WireGuard VPN on Google Cloud, managed entirely from a Telegram
bot. One installer script, fits in the GCP free tier, no web UI.

## Quick start

```bash
git clone https://github.com/YOUR/wg-vpn-bot.git
cd wg-vpn-bot
./install.sh
```

About 10 minutes later, you'll have a VPN.

> ⚠️ Before you run the installer, **please read [DISCLAIMER.md](DISCLAIMER.md)**.
> Short version: this is a hobby tool, GCP can bill you if you exceed the
> free tier, and there's no SLA. If you understand that, carry on.

## Documentation

- **[DISCLAIMER.md](DISCLAIMER.md)** — what this is and what it isn't (read first)
- **[SETUP.md](docs/SETUP.md)** — first-time installation walkthrough
- **[USER.md](docs/USER.md)** — for peers (people who will use the VPN)
- **[ADMIN.md](docs/ADMIN.md)** — day-to-day operating guide
- **[SPEC.md](docs/SPEC.md)** — architecture, design rationale, threat model
- **[SECURITY.md](SECURITY.md)** — how to report a security issue

## What you get

- One e2-micro VM running Debian 12 with WireGuard
- A Telegram bot for admin: `/add johna`, `/reboot YES`, `/status`, `/digest`, …
- `wg-bot-doctor` — read-only audit tool that diagnoses most failure modes
- SSH closed to the internet (Google IAP only)
- Static IP, daily digests, audit log
- Admin uses Telegram. Peers don't — they just receive a `.conf` file
  through whatever channel you already use with them.

## Requirements

- Linux or macOS laptop (bash 4+)
- A Google account with billing set up (free tier covers normal hobby use)
- Telegram on your phone (for the admin only)
- ~10 minutes

## License

[MIT](LICENSE).

## Not for

- Production use serving paying customers
- Privacy-critical use cases (admin commands pass through Telegram's servers)
- More than ~10 peers (e2-micro is small)
- Anyone who needs an SLA

For those, look at [Algo](https://github.com/trailofbits/algo) or
[wg-easy](https://github.com/wg-easy/wg-easy).
