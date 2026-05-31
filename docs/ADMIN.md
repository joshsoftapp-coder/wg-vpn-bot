# ADMIN.md — for the admin

You set this up, you're the admin. This is the day-to-day operating guide.

For first-time setup, see [SETUP.md](SETUP.md). For the design rationale and architecture, see [SPEC.md](SPEC.md). For what your peers should know, see [USER.md](USER.md).

## Daily life

Most days: nothing. Open Telegram if you're curious. Read the daily digest that arrives at 13:00 your local time. Get on with your life.

If something breaks, the bot alerts you. If the bot itself crashes, systemd's `OnFailure=` notifier alerts you. If the VM is fully offline, you'll notice the next time you try to use the VPN.

## Command reference

### Peer management (WG identity)

| Command | What it does |
| --- | --- |
| `/peers` | List all peers with their IP and last handshake. |
| `/peer alice` | Detail: IP, public key, transfer stats. |
| `/add alice` | Create a peer. DMs you the .conf + QR. |
| `/reissue alice` | New keypair for an existing peer. Same name and IP. DMs the new config to you. |
| `/remove alice YES` | Permanently delete the peer. Its config stops working. |

### VM management

| Command | What it does |
| --- | --- |
| `/status` | Uptime, load, mem, disk, WG state, public IP, peer count. |
| `/logs wg | ssh | bot [n]` | Tail journald. Default 30 lines, max 200. |
| `/reboot YES` | Reboot the VM. Peers reconnect automatically when it's back (\~60s). |
| `/shutdown YES` | Power off. Bot becomes unreachable; restart VM from GCP Console. |
| `/restart wg` | Restart `wg-quick@wg0` only. |
| `/update` | Dry-run: show which packages would upgrade. |
| `/update YES` | Apply security upgrades. |
| `/digest [vm|wg]` | Show the status digest on demand (both if no arg). Same content as the daily 13:00/13:05 auto-digests. |

### Misc

| Command | What it does |
| --- | --- |
| `/export` | DM you `wg0.conf` as a backup file. |
| `/whoami` | Confirms your admin status and shows your user_id. |
| `/help` | Command list. |

## `/reissue` vs `/remove`

|  | What happens to keys | Does the old config still work? |
| --- | --- | --- |
| `/reissue alice` | New keypair, same name and IP | **No** — old config is dead, send the new one |
| `/remove alice YES` | Peer deleted entirely | **No** — peer is gone |

- **reissue** = same person, new credentials (lost device, suspected key leak)
- **remove** = that peer is gone for good

After either command the bot DMs *you* the result; you forward the new config to the peer through whatever channel you use with them.

## Common scenarios

### "I want to add a friend"

```
/add bob
```

The bot DMs you `bob.conf` plus a QR. Forward it to Bob however you like — AirDrop, WhatsApp, Signal, email, or show him the QR to scan in person. Bob imports it into the WireGuard app.

### "Bob lost his phone"

```
/reissue bob      (new config DM'd to you; forward it to Bob)
```

Bob's old config is now dead, so a finder of the lost phone can't use it.

### "Bob doesn't need the VPN anymore"

```
/remove bob YES
```

Peer deleted, his config stops working.

### "Bob's device was stolen and I want his access killed now"

```
/remove bob YES   (kills it immediately)
```

Then, if Bob wants access on a replacement device later, `/add bob` for a fresh config.

### "I want to go on vacation and not pay for an unused IP"

Two options:

**Pause** (preserves project, peers, configs):

```
./uninstall.sh PROJECT_ID --keep-vm
```

Stops VMs but keeps the static IP reserved (\~$7/month while reserved). Restart from GCP Console. **Note:** the bot is offline while VMs are stopped, so you can't restart from Telegram — must use the GCP Console or `gcloud`.

**Nuke** (purge everything, redo when needed):

```
./uninstall.sh PROJECT_ID
```

Project is soft-deleted. 30-day recovery window. $0/month. When you come back, run `./install.sh` from scratch — fresh project, fresh keys, fresh peers, fresh everything. Per the project philosophy: if anything's weird, purge and redo.

### "Something is wrong and I don't trust the state"

```
./uninstall.sh PROJECT_ID
./install.sh
```

Per the design: the VM is disposable.

### "I want to migrate to a different region"

There's no in-place migration. The path is:

```
./uninstall.sh OLD_PROJECT_ID
./install.sh               choose the new region
                           /add each peer fresh
                           send each peer their new config
```

You can't restore the old peers with old configs — server identity changes, so peer configs would point at the wrong server keys.

### "I want to back up before doing something risky"

```
/export                    bot DMs you wg0.conf
```

Save the .conf file. To restore: fresh `./install.sh`, then via SSH:

```bash
gcloud compute ssh VM_NAME --tunnel-through-iap
sudo cp ~/wg0.conf /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
```

All previously-issued peer configs continue to work (server identity preserved).

## Alerts you'll receive

### Immediate (critical)

- 🔐 **SSH login** — every time a session opens. Source IP shown.
- 🔴 **WireGuard service down** — followed by 🟢 recovery (or 🟥 if restart failed).
- 🟥 **Disk ≥ 95% full**
- 🔴 **Bot crashed** — from systemd `OnFailure=`. Bot is being restarted.

### Batched (every 5 min, max 1 per batch)

- 🟧 **Disk ≥ 85% full**

### In the daily VM digest

- Uptime, load, mem, disk %, public IP
- WG service state
- Count of unauthorized DM attempts in last 24h (with example senders)

### In the daily WG digest

- Public IP
- Total peer count
- Active peers in last 24h with transfer totals

## Audit log

Everything is logged to `/var/log/wg-admin-bot/audit.log`:

- Every command you run (admin)
- Every peer add/remove/reissue
- Every unauthorized DM attempt
- Pairing events

Tail it via Telegram: `/logs bot 100` (shows the bot's journald, which includes audit-relevant events).

For raw audit log:

```bash
gcloud compute ssh VM_NAME --tunnel-through-iap
sudo less /var/log/wg-admin-bot/audit.log
```

Retention: 365 days (configurable in `/etc/wg-admin-bot/config.yaml`).

## SSH access

```bash
gcloud compute ssh VM_NAME --project=PROJECT_ID --zone=ZONE --tunnel-through-iap
```

Public port 22 is **closed**. Only the IAP range can reach SSH. You authenticate to GCP, GCP tunnels you in.

## Re-pairing the admin

If your Telegram account is compromised, or you want to transfer the bot to a different Telegram account:

```bash
gcloud compute ssh VM_NAME --tunnel-through-iap
sudo wg-bot-reset-admin
```

This:

1. Clears the stored admin user_id
2. Generates a new pairing token (30-min TTL)
3. Restarts the bot

Send `/start NEW-TOKEN` from your new Telegram account.

**Note:** peers are unaffected by an admin reset. Their VPN configs keep working throughout — this only changes who controls the bot.

## Recovering from a suspected VM compromise

If you think the VM itself is compromised — not just your Telegram account — the recommended path is to **purge and rebuild**:

```bash
./uninstall.sh PROJECT_ID    # deletes the entire GCP project (soft-delete; 30d to undelete)
./install.sh                 # makes a new project, new VM, new server keys
                             # /add each peer fresh
                             # send each peer their new config
```

This is fine to do casually. The VM has nothing on it that would be worth recovering from the attacker's perspective:

- The WireGuard server private key — irrelevant once you've issued new configs from the new server.
- Peer public keys and the human names you chose (`johna`, `vpn-a3f9`, etc.). At most mildly embarrassing.
- The Telegram bot token — rotate it via @BotFather if you're cautious; otherwise it just goes idle once the old VM is gone.
- An audit log of which Telegram users DM'd the bot.

There is **no user data, no browsing history, no stored credentials** on this server. It's a stateless WireGuard endpoint with a small management bot. Rebuilding is \~10 minutes; the only inconvenience to peers is importing the new config you send them.

Whenever you're uncertain, run `sudo wg-bot-doctor --verbose` first — it audits every file, service, and runtime invariant the bot depends on, and will surface most classes of compromise or misconfiguration without guessing. If the doctor reports green and you still feel uneasy, purge and rebuild — that path is what the project is built around.

## Diagnosing problems with wg-bot-doctor

If the bot is misbehaving — silent commands, crash-looping, mysterious permission errors, peer counts that don't match — run the doctor before anything else:

```bash
gcloud compute ssh VM_NAME --tunnel-through-iap
sudo wg-bot-doctor
```

The doctor reads (never writes by default) every file, service state, and runtime invariant the bot depends on, then prints a categorized report of what's wrong. Four sections:

- **sys** — file ownership/modes, FIFO, tmpfiles rule, sudoers, systemd units
- **bot** — service state, crash history, log analysis, Telegram reachability, config integrity
- **wg** — kernel-vs-config peer consistency, IP allocation conflicts, peer-name mapping, handshake freshness
- **net** — IP forwarding, NAT masquerade rules, outbound interface, FORWARD chain

Common flags:

```bash
sudo wg-bot-doctor                 # full audit, no changes
sudo wg-bot-doctor --fix           # audit + apply safe automatic fixes
sudo wg-bot-doctor --section net   # only network checks (NAT, forwarding)
sudo wg-bot-doctor --section bot   # only bot-related checks
sudo wg-bot-doctor --verbose       # show passing checks too
sudo wg-bot-doctor --json          # machine-readable for scripting
```

The `--fix` mode is conservative: it only re-applies known-correct ownership/modes to filesystem objects (wg0.conf, wg directory, FIFO). It does not touch your data, your config, or your peers. If a fix isn't safe (e.g. a peer mismatch between kernel and conf — which one should win?), it tells you and lets you decide.

Exit code is 0 if no failures, 1 if any failures. Useful for cron or monitoring scripts.

## Recommended Telegram account hardening

Since your Telegram account is the only authentication factor between you and the bot's destructive commands, harden it:

1. **Enable two-step verification** in Telegram settings (Settings → Privacy and Security → Two-Step Verification). Set a password.
2. **Set a strong session password** so SIM-swap attackers can't log in with just SMS.
3. Periodically review **active sessions** in Telegram settings and terminate ones you don't recognize.

The bot itself has no way to enforce this; it's on you.

## What the bot will never do

For peace of mind, here's what's structurally outside the bot's capability:

- Run arbitrary shell commands (sudoers is a strict allowlist)
- Install packages other than security upgrades (`apt-get upgrade` only, not `install`)
- Read your wg0.conf to anyone but you (the admin)
- Run anything as root that isn't in `/etc/sudoers.d/wgbot`
- Initiate DMs to anyone who hasn't first messaged the bot

## What the bot's limitations are

Things this design deliberately does not do:

- **No per-peer traffic caps.** WG doesn't enforce them natively.
- **No multi-admin.** One admin only.
- **No webhook mode.** Long-poll only. Adds maybe 200-500ms vs webhooks.
- **No bot self-update from Telegram.** Update by re-running install (after `/export` for backup).
- **No automatic backups.** Run `/export` yourself if you care.
- **No fancy ACLs between peers.** All peers see each other on the WG network (default WG behavior).