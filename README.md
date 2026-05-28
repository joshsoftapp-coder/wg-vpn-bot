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

## Documentation

- **[SETUP.md](docs/SETUP.md)** — first-time installation walkthrough
- **[USER.md](docs/USER.md)** — for peers (people who will use the VPN)
- **[ADMIN.md](docs/ADMIN.md)** — day-to-day operating guide
- **[SPEC.md](docs/SPEC.md)** — architecture, design rationale, threat model

## What you get

- One e2-micro VM running Debian 12 with WireGuard
- A Telegram bot for admin: `/add alice`, `/reboot YES`, `/status`, etc.
- A claim flow so peers receive their configs directly via Telegram
- SSH closed to the internet (Google IAP only)
- Static IP, daily digests, audit log

## Requirements

- Linux or macOS laptop (bash 4+)
- A Google account with billing set up
- Telegram on your phone
- ~10 minutes

## License

[MIT](LICENSE).

## Not for

- Production use serving paying customers
- Privacy-critical use cases (Telegram handles your commands in cleartext)
- More than ~10 peers (e2-micro is small)
- Anyone who needs an SLA

For those, look at [Algo](https://github.com/trailofbits/algo) or
[wg-easy](https://github.com/wg-easy/wg-easy).
