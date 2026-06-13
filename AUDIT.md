# Security Audit

Two scripts check the VM's security posture. Both are read-only and print
clear PASS / FAIL lines with a summary count. Exit code is 0 if everything
passes, 1 if anything fails — so they work in scripts and monitoring too.

Run both after every fresh install, and any time something feels off.

## External audit (from your laptop)

Checks the attack surface as seen from outside: firewall rules, that the
permissive GCP defaults are gone, and that SSH is not reachable from a
non-IAP address. Needs `gcloud`; does not need SSH.

```bash
./audit-external.sh PROJECT_ID
# or, if the VM name or zone differ from the defaults:
./audit-external.sh PROJECT_ID VM_NAME ZONE
```

What it verifies:
- No firewall rule allows tcp:22 from outside the IAP range
- `default-allow-ssh` and `default-allow-rdp` do not exist
- Only the expected rules are present (WG UDP, SSH-via-IAP)
- A live TCP-22 connection from your machine is refused
- No unexpected ports are open to the internet

Note: it does **not** pass/fail on a UDP scan of the WireGuard port.
WireGuard never replies to unauthenticated packets, so a scan can neither
confirm nor deny it is running. Real WireGuard health is checked by the
internal audit instead.

## Internal audit (on the VM)

Checks everything that requires being on the host: file permissions,
service state, sudo scope, listening sockets, SSH hardening, token-leak
hygiene, NAT, and WireGuard health.

```bash
gcloud compute ssh VM_NAME --project=PROJECT_ID --zone=ZONE --tunnel-through-iap
sudo bash audit-internal.sh
```

What it verifies:
- Sensitive files have correct owner and mode (config, wg0.conf, server key)
- The bot runs as the unprivileged `wgbot` user, not root
- `wg-quick@wg0` and `wg-admin-bot` are active
- sudoers parses cleanly and grants no blanket `ALL`
- Only sshd listens on TCP; the bot owns no listening socket
- SSH is key-only, root login restricted
- The bot token does not appear in the journal
- IP forwarding on, NAT masquerade present on the real WAN interface
- WireGuard interface is up on the right port (authoritative liveness check)
- Unattended security upgrades enabled

## Deeper diagnosis

If the internal audit flags something, `wg-bot-doctor` gives a fuller,
categorized report (filesystem, bot, WireGuard, network) and can apply safe
fixes:

```bash
sudo wg-bot-doctor             # full read-only audit
sudo wg-bot-doctor --fix       # re-apply known-correct file modes/owners
sudo wg-bot-doctor --section net   # one section only
```

Run the doctor over SSH only — its output includes detail (peer keys, config
internals) that should not be sent through a chat channel.

## What passing looks like

Both scripts end with a summary like:

```
── Summary: 12 passed, 0 failed ──
```

Zero failures is the bar for a freshly installed VM before you rely on it.

## Accepted exposure (by design)

- **The bot token and the one-time pairing token persist in the VM's
  startup-script metadata** for the life of the instance. Anyone with
  read access to the GCP project (and any process on the VM, via the
  metadata server) can recover them. In the single-owner project model
  this adds nothing beyond what project access already grants. To rotate
  the bot token: revoke it in @BotFather, then `./uninstall.sh` +
  `./install.sh`.
- **Admin commands transit Telegram's servers.** Management traffic is
  not private from Telegram; VPN data-plane traffic never touches the
  bot or Telegram.
