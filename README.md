# wg-vpn-bot

Self-hosted WireGuard VPN on Google Cloud, managed from a Telegram bot.
One installer script. Fits the GCP free tier. No web UI.

## Quick start

```bash
git clone https://github.com/joshsoftapp-coder/wg-vpn-bot
cd wg-vpn-bot
./install.sh
```

~10 minutes later you have a running VPN.

## What you get

- GCP e2-micro VM (Debian 12) running kernel WireGuard
- Telegram bot to manage peers, reboot, update, and monitor — from your phone
- SSH closed to the internet (Google IAP only)
- Static IP, daily digests, audit log, diagnostic tool (`wg-bot-doctor`)

## Cost

Free tier covers one e2-micro in `us-west1`, `us-central1`, or `us-east1`,
30 GB disk, and 1 GB outbound traffic per month. Beyond that:

- Outbound over 1 GB/month: ~$0.12/GB
- Non-US region: not free
- Static IP while VM is stopped: ~$7/month

Run `./uninstall.sh` when not in use (soft-deletes the project, 30-day
recovery window, $0 while deleted).

## Requirements

- macOS or Linux, bash 4+, `gcloud`, `jq`, `curl`
- Google account with a billing account set up
- Telegram (admin only — peers don't need it)

## Limitations

- Not for production or paying customers
- Not tested beyond ~10 peers
- Admin commands transit Telegram's servers — not suitable for
  privacy-critical management traffic

## Disposable by design

If anything breaks or you don't trust the state:

```bash
./uninstall.sh PROJECT_ID
./install.sh
```

Fresh project, fresh keys. ~10 minutes.

## License

[MIT](LICENSE)
