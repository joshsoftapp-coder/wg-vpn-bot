# ADMIN.md — for the admin

You set this up, you're the admin. This is the day-to-day operating guide.

For first-time setup, see [SETUP.md](SETUP.md).
For the design rationale and architecture, see [SPEC.md](SPEC.md).
For what your peers should know, see [USER.md](USER.md).

## Daily life

Most days: nothing. Open Telegram if you're curious. Read the daily digest
that arrives at 13:00 your local time. Get on with your life.

If something breaks, the bot alerts you. If the bot itself crashes,
systemd's `OnFailure=` notifier alerts you. If the VM is fully offline,
you'll notice the next time you try to use the VPN.

## Command reference

### Peer management (WG identity)

| Command | What it does |
|---|---|
| `/peers` | List all peers. ✉ marks claimed ones. |
| `/peer alice` | Detail: IP, public key, claim status, transfer stats. |
| `/add alice` | Create a peer. DMs you the .conf + QR. |
| `/reissue alice` | New keypair for an existing peer. Same name and IP. DMs to peer if claimed, else to you. |
| `/remove alice YES` | Permanently delete peer. Also clears claim. |

### Peer claims (Telegram binding)

| Command | What it does |
|---|---|
| `/invite alice` | Generate a 30-min claim token. Forward to Alice via any channel. |
| `/unclaim alice` | Clear Alice's chat_id binding. Her VPN still works; bot stops being able to DM her. |

### VM management

| Command | What it does |
|---|---|
| `/status` | Uptime, load, mem, disk, WG state, public IP, peer count. |
| `/logs wg \| ssh \| bot [n]` | Tail journald. Default 30 lines, max 200. |
| `/reboot YES` | Reboot the VM. Claimed peers get a "rebooting ~60s" message first. |
| `/shutdown YES` | Power off. Bot becomes unreachable; restart VM from GCP Console. |
| `/restart wg` | Restart `wg-quick@wg0` only. |
| `/update` | Dry-run: show which packages would upgrade. |
| `/update YES` | Apply security upgrades. |
| `/digest [vm\|wg]` | Show the status digest on demand (both if no arg). Same content as the daily 13:00/13:05 auto-digests. |

### Misc

| Command | What it does |
|---|---|
| `/export` | DM you `wg0.conf` as a backup file. |
| `/whoami` | Confirms your admin status and shows your user_id. |
| `/help` | Command list. |

## The three "destruction" commands and how they differ

This trips people up, so worth being explicit:

| | Touches WG peer? | Touches claim binding? | Alice's config still works? | Bot can still DM Alice? |
|---|---|---|---|---|
| `/reissue alice` | **Yes** — new keys, same IP | No | **No** — old config dead | Yes |
| `/unclaim alice` | No | **Yes** — cleared | Yes — VPN unchanged | No |
| `/remove alice YES` | **Yes** — deleted | **Yes** — cleared | No — peer gone | No |

Mnemonic:
- **reissue** = new VPN keys
- **unclaim** = new Telegram binding (or none)
- **remove** = everything goes

## Common scenarios

### "I want to add a friend"

If they're with you: `/add bob`, forward the QR via AirDrop / WhatsApp / however.

If they're remote and you want zero forwarding:
```
/add bob          (you receive the config, ignore it)
/invite bob       (you receive a token line)
                  forward the token line to Bob
                  Bob claims, bot DMs him the config
```

### "Bob lost his phone"

If Bob is claimed:
```
/reissue bob      (new config DM'd directly to Bob)
```

If Bob is not claimed:
```
/reissue bob      (new config DM'd to you, then you forward)
```

### "Bob got a new Telegram account"

```
/unclaim bob               (clear the old binding)
/invite bob                (fresh token)
                           Bob claims from the new account
                           Bot DMs new config to new account
                           (no /reissue needed — peer keys unchanged)
```

### "Bob's Telegram and phone are both compromised"

Treat the WG keys and the claim binding as both compromised:
```
/remove bob YES            (clear everything)
/add bob                   (fresh keys, fresh peer)
/invite bob                (fresh token; send via a channel you trust)
```

### "I want to go on vacation and not pay for an unused IP"

Two options:

**Pause** (preserves project, peers, configs):
```
./uninstall.sh PROJECT_ID --keep-vm
```
Stops VMs but keeps the static IP reserved (~$7/month while reserved).
Restart from GCP Console. **Note:** the bot is offline while VMs are
stopped, so you can't restart from Telegram — must use the GCP Console
or `gcloud`.

**Nuke** (purge everything, redo when needed):
```
./uninstall.sh PROJECT_ID
```
Project is soft-deleted. 30-day recovery window. $0/month. When you come
back, run `./install.sh` from scratch — fresh project, fresh keys, fresh
peers, fresh everything. Per the project philosophy: if anything's weird,
purge and redo.

### "Something is wrong and I don't trust the state"

```
./uninstall.sh PROJECT_ID
./install.sh
```

Per the design: the VM is disposable.

### "I want to migrate to a different region"

There's no in-place migration. The path is:
```
/export                    download current wg0.conf (for reference)
./uninstall.sh OLD_PROJECT_ID
./install.sh               choose the new region
                           /add each peer fresh
                           /invite each peer
```

You can't restore the old peers with old configs — server identity changes,
so peer configs would point at the wrong server keys.

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
All previously-issued peer configs continue to work (server identity
preserved).

## Alerts you'll receive

### Immediate (critical)

- 🔐 **SSH login** — every time a session opens. Source IP shown.
- 🔴 **WireGuard service down** — followed by 🟢 recovery (or 🟥 if restart failed).
- 🟥 **Disk ≥ 95% full**
- 🔴 **Bot crashed** — from systemd `OnFailure=`. Bot is being restarted.

### Batched (every 5 min, max 1 per batch)

- 🟧 **Disk ≥ 85% full**
- 📥 **Peer claimed** — when someone successfully runs `/claim`

### In the daily VM digest

- Uptime, load, mem, disk %, public IP
- WG service state
- Count of unauthorized DM attempts in last 24h (with example senders)

### In the daily WG digest

- Public IP
- Total/claimed peer counts
- Active peers in last 24h with transfer totals

## Audit log

Everything is logged to `/var/log/wg-admin-bot/audit.log`:
- Every command you run (admin)
- Every claim attempt (success or fail)
- Every peer add/remove/reissue
- Every unauthorized DM attempt
- Pairing events

Tail it via Telegram: `/logs bot 100` (shows the bot's journald, which
includes audit-relevant events).

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

Public port 22 is **closed**. Only the IAP range can reach SSH. You
authenticate to GCP, GCP tunnels you in.

## Re-pairing the admin

If your Telegram account is compromised, or you want to transfer the bot
to a different Telegram account:

```bash
gcloud compute ssh VM_NAME --tunnel-through-iap
sudo wg-bot-reset-admin
```

This:
1. Clears the stored admin user_id
2. Clears all peer claim bindings (peers will re-claim)
3. Generates a new pairing token (30-min TTL)
4. Restarts the bot

Send `/start NEW-TOKEN` from your new Telegram account.

**Note:** all peers need to re-claim after admin reset. Their VPN configs
keep working — only the Telegram bindings are cleared.

## Diagnosing problems with wg-bot-doctor

If the bot is misbehaving — silent commands, crash-looping, mysterious
permission errors, peer counts that don't match — run the doctor before
anything else:

```bash
gcloud compute ssh VM_NAME --tunnel-through-iap
sudo wg-bot-doctor
```

The doctor reads (never writes by default) every file, service state,
and runtime invariant the bot depends on, then prints a categorized
report of what's wrong. Four sections:

- **sys** — file ownership/modes, FIFO, tmpfiles rule, sudoers, systemd units
- **bot** — service state, crash history, log analysis, Telegram reachability, config integrity
- **wg** — kernel-vs-config peer consistency, IP allocation conflicts, claim mappings, handshake freshness
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

The `--fix` mode is conservative: it only re-applies known-correct
ownership/modes to filesystem objects (wg0.conf, wg directory, FIFO).
It does not touch your data, your config, or your peers. If a fix
isn't safe (e.g. a peer mismatch between kernel and conf — which one
should win?), it tells you and lets you decide.

Exit code is 0 if no failures, 1 if any failures. Useful for cron or
monitoring scripts.

## Recommended Telegram account hardening

Since your Telegram account is the only authentication factor between you
and the bot's destructive commands, harden it:

1. **Enable two-step verification** in Telegram settings (Settings → Privacy
   and Security → Two-Step Verification). Set a password.
2. **Set a strong session password** so SIM-swap attackers can't log in
   with just SMS.
3. Periodically review **active sessions** in Telegram settings and
   terminate ones you don't recognize.

The bot itself has no way to enforce this; it's on you.

## What the bot will never do

For peace of mind, here's what's structurally outside the bot's capability:

- Run arbitrary shell commands (sudoers is a strict allowlist)
- Install packages other than security upgrades (`apt-get upgrade` only,
  not `install`)
- Read your wg0.conf to anyone but you (the admin)
- Run anything as root that isn't in `/etc/sudoers.d/wgbot`
- Initiate DMs to anyone who hasn't first messaged the bot

## What the bot's limitations are

Things this design deliberately does not do:

- **No per-peer traffic caps.** WG doesn't enforce them natively.
- **No multi-admin.** One admin only.
- **No webhook mode.** Long-poll only. Adds maybe 200-500ms vs webhooks.
- **No bot self-update from Telegram.** Update by re-running install
  (after `/export` for backup).
- **No automatic backups.** Run `/export` yourself if you care.
- **No fancy ACLs between peers.** All peers see each other on the WG
  network (default WG behavior).
