# Security

## Reporting

If you find a security issue, please open a private issue on GitHub or
email the maintainer rather than filing a public bug. Coordinate
disclosure if it's exploitable in the wild.

## Threat model

See [docs/SPEC.md](docs/SPEC.md) for the full threat model. Summary:

- Defended against: random scanners, opportunistic exploits, Telegram
  strangers DMing the bot.
- Weakest link by design: the admin's Telegram account. Enable Telegram
  two-step verification.
- Not defended against: targeted attacks by state-level actors,
  compromised Google account, compromised peer device.

## Known limitations

- Telegram messages between admin and bot transit Telegram's servers in
  cleartext to them.
- The bot token is stored on the VM in plain text (`/etc/wg-admin-bot/config.yaml`,
  root:wgbot 0640).
- The server's WG private key is stored on the VM in plain text
  (`/etc/wireguard/wg0.conf`, root:wgbot 0660). If the VM is compromised,
  these are exfiltrated.

## Sensitive data not on the server

The bot does **not** store:
- Peer private keys (generated, delivered once, forgotten)
- Telegram message history
- Peer traffic logs

## Audit log

All admin actions, claim attempts, and unauthorized DMs are logged to
`/var/log/wg-admin-bot/audit.log`. 365-day retention by default.
