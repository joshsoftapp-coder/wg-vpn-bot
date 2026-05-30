# SPEC.md — design and architecture

This is the why-it-is-the-way-it-is document. If you want to understand,
modify, or audit the system, start here.

For day-to-day use, [ADMIN.md](ADMIN.md) is enough.

## Project goal

A self-hosted WireGuard VPN, on Google Cloud's free tier, managed
entirely from Telegram. One admin, a handful of peers, no web UI, no SLA.
If anything breaks weirdly, the answer is `./uninstall.sh && ./install.sh`.

## Threat model

Who we're defending against, with realistic threats:

- **Random internet scanners** — port scans, brute-force, opportunistic
  exploits. Mitigated by: only UDP/51820 exposed, no SSH on internet, no
  web UI.
- **Telegram strangers DMing the bot** — anyone can find the bot via its
  username and DM it. The bot ignores anyone who isn't the admin. Logged
  in a daily summary.
- **Telegram account compromise of the admin** — this is the weakest link.
  Mitigations: (a) admin enables Telegram 2FA, (b) destructive commands
  require explicit `YES`, (c) re-pairing requires physical/IAP access to
  the VM.
- **Loss/theft of a peer's device** — affects only that peer's tunnel.
  Admin runs `/remove NAME YES` to kill the stolen config server-side,
  then `/add NAME` to issue a fresh one for the replacement device.
- **GCP account compromise of the admin** — out of scope. They have the
  cloud console; the bot is a sideshow at that point.

Who we're explicitly **not** defending against:

- A determined attacker with state-level resources targeting you
  specifically
- A nation-state with control over Telegram or Google
- A peer who already has a valid VPN config — they have access to the WG
  subnet; they could attack other peers' devices over WG. This is just
  WireGuard's default behavior; we don't add per-peer firewall rules.

## Trust hierarchy

```
                Google IAP authentication
                          │
                          ▼
              ┌─────────────────────────┐
              │  SSH access to the VM   │  ← can re-pair, reset, do anything
              └─────────────────────────┘
                          │
                          ▼
              ┌─────────────────────────┐
              │  /etc/sudoers.d/wgbot   │  ← root privilege boundary
              └─────────────────────────┘
                          │
                          ▼
              ┌─────────────────────────┐
              │  wgbot system user      │  ← runs the Python bot
              └─────────────────────────┘
                          │
                          ▼
              ┌─────────────────────────┐
              │ Telegram bot token      │  ← long-poll API access
              └─────────────────────────┘
                          │
                          ▼
                   admin user_id
                  (TOFU paired)
```

Each level is a different identity:
- IAP → real Google identity (the admin's email)
- sudoers → unix user, not network identity
- wgbot → can do operational things, can't escalate
- bot token → Telegram, distinct from admin's Telegram account
- admin user_id → Telegram's user_id integer (a peer's user_id is not
  tracked; peers don't interact with the bot)

## Why these choices

### Why Telegram and not Signal / Matrix / etc.

- **Long-poll bot API works out of the box** — no webhook, no public HTTPS
  endpoint needed, the bot pulls from `api.telegram.org`. Net inbound
  attack surface: zero (excluding WG).
- **Rich UI in the chat** — files, images (QR codes), markdown formatting.
- **Bots don't require a phone number** — created via @BotFather, identified
  by token.
- **Signal alternatives** require running signal-cli (JVM, 250-400 MB
  resident), which doesn't fit on a 1 GB e2-micro alongside everything
  else. Signal also requires a phone number for the bot itself.
- **Matrix** would work but is more setup. Telegram is "open the app, send
  a message" — minimal cognitive overhead for casual peers.

The tradeoff: messages flow through Telegram's servers in cleartext-to-them.
For a hobby VPN where Telegram itself is the user's normal messaging tool,
that's fine.

### Why GCP and not Oracle / Hetzner / Fly.io

- **Free tier sufficient for the use case** — one e2-micro, 30 GB disk,
  1 GB outbound/month, in three US regions. Enough for ~5 peers doing
  modest browsing.
- **IAP (Identity-Aware Proxy)** — lets us close port 22 to the public
  internet entirely while still allowing SSH access through Google's
  authenticated tunnel. This is a structural security win that's hard
  to replicate elsewhere.
- **Static IP free while attached to a running VM.** Many providers charge
  for static IPs regardless.
- **Soft-delete window** — `gcloud projects delete` gives you 30 days to
  recover. Matches the "if in doubt, nuke it" philosophy.
- **Oracle Free Tier** is generous on paper (4 OCPU, 24 GB RAM, 10 TB
  egress) but has a history of reclaiming "idle" instances and the
  console UX is messy. Bad fit for "set and forget."

### Why a custom bot and not a ready-made tool (wg-easy, Algo, pivpn)

- **wg-easy** — web UI on port 51821, exposed (with basic auth). We want
  no web surface.
- **Algo** — Ansible playbook to install a stack including IPsec/WG. Heavy.
  Doesn't help with ongoing management — you SSH in for changes.
- **pivpn** — designed for Raspberry Pi at home, assumes you'll SSH in to
  manage. We want phone-based management.

The closest is **Made-By-Adem/linux-server-telegram-bot** (8 stars,
Docker-centric). Differences from ours: theirs runs privileged in Docker;
ours runs as a constrained unix user. Theirs doesn't have IAP-protected
SSH or TOFU pairing. Theirs is generic Linux management; ours is
WG-specific.

There's no perfect off-the-shelf match. This codebase exists to fill that
gap, narrowly.

### Why systemd and not Docker

- **e2-micro has 1 GB of RAM.** Docker daemon + Python in a container =
  meaningful overhead. Native is leaner.
- **systemd is already there.** No extra moving parts to maintain.
- **Service constraints** (`User=`, `ReadWritePaths=`, etc.) give us
  sandboxing similar to Docker for one service.
- **OnFailure= and timers** give us the alerting infrastructure for free.
- **Logs go straight to journald**, which we tail via `/logs`.

The cost: porting to a different OS family would mean rewriting some
systemd-isms. Acceptable; this is targeted at Debian.

### Why systemd timers and not cron

- **Cron has historically been timezone-confused.** systemd timers accept
  `OnCalendar=*-*-* 13:00:00 Asia/Jerusalem` and Do The Right Thing.
- **`Persistent=true`** runs missed timers after VM resume — useful if the
  digest time was during downtime.
- **systemd handles logging, dependencies, and failure** uniformly with
  the rest of the services.

### Why TOFU pairing and not a pre-shared admin key

- We don't know the admin's Telegram user_id at install time.
- The installer can't "log into Telegram" to discover it.
- The TOFU flow ("first valid `/start TOKEN` becomes admin") is the
  minimum-config way to establish that binding.
- Token has a 30-minute TTL to limit the window for accidental leakage.
- Token is single-use to prevent replay.

The reset path (`sudo wg-bot-reset-admin`) is gated behind IAP-SSH access,
which is gated behind Google identity. So losing access to your Telegram
account is recoverable as long as you still have GCP access.

### Why `wg set` + `wg-quick save` and not a custom config parser

In v0.1 we had a custom parser with comment-marker DSL for pause/resume
states. It worked but was 400 lines of code maintaining an invariant that
WireGuard's own tools already maintain.

v0.2 uses the native approach:
- **Adding a peer:** `wg set wg0 peer PUBKEY allowed-ips IP` (kernel state)
  + `wg-quick save wg0` (writes to wg0.conf)
- **Removing a peer:** `wg set wg0 peer PUBKEY remove` + `wg-quick save`
- **Listing peers:** read kernel state via `wg show wg0 dump` for membership
  and IPs, then join names from `state.json` (see below)
- **IP allocation:** read `wg show wg0 allowed-ips` for ground truth

We dropped pause/resume entirely. To disable a peer, remove them.
Re-adding takes about three seconds via `/add NAME`.

### Why peer names live in state.json, not in wg0.conf comments

WireGuard's config format has no "Name" field on `[Peer]` blocks. The
native tool's view of a peer is just `(public key, preshared key, allowed
IPs)`. We need to map our human-friendly names to public keys somewhere.

**v0.1–v0.2.4 stored names as `# name: X` comments in wg0.conf.** This was
wrong. `wg-quick save` serializes kernel state via `wg showconf`, which
strips **all** comments on every save. So every peer add or remove erased
every other peer's name — the first peer's name vanished as soon as a
second peer was added. This bug shipped latent for several versions because
earlier failures blocked us from ever reaching a multi-peer state on a real
VM.

**v0.2.5 onward: names live in `state.json`** as a `peer_names` dict of
`{pubkey: name}`. `state.json` is owned by the bot (`wgbot:wgbot 0600`) and
written in place, so it survives every `wg-quick save`. Peer membership and
IPs still come from the kernel (the real source of truth for "who can
connect"); only the human label comes from `state.json`.

We still write a `# name:` comment into wg0.conf at creation time as a
courtesy for anyone reading the file by hand — but no code relies on it,
and it's expected to be stripped on the next save. On upgrade from an older
version, `list_peers()` does a one-shot bootstrap: if `peer_names` is empty
but comments survive in the conf, it recovers names from them and persists
to `state.json`.

### One identity, not two: the dropped claim flow

Earlier designs had a second "claim" identity binding a Telegram `chat_id`
to a peer, so the bot could DM peers directly (reissues, outage notices).
The `/claim`, `/invite`, `/unclaim`, and `/leave` commands implemented this.

**As of v0.2.6 the claim flow is disabled.** It was buggy, and it added a
whole second identity model (and second source of truth) for marginal
benefit. The code is preserved but unregistered in `bot.py`, so it can be
revived later if wanted.

The current model is simpler: a peer is **only** a WG identity (private
key, public key, IP). There is no Telegram binding. The admin creates a
peer with `/add`, receives the config, and couriers it to the peer through
whatever channel they already use (AirDrop, Signal, WhatsApp, email, in
person). Peers never interact with the bot at all — they just import a
`.conf` into the WireGuard app.

This means `/reissue` and `/remove` both deliver their result to the admin,
who forwards as needed. No `chat_id`, no claim bindings, no peer-facing
Telegram surface to secure.

### Why YES confirmations

For commands that can't be undone within the chat (`/reboot`, `/shutdown`,
`/remove`, `/update`), we require `YES` as the next argument. This guards
against:
- Fat-fingering: `/remove alice` alone doesn't do anything
- Telegram autocomplete: if you accidentally tap a saved command, it
  doesn't fire
- Shoulder-surfing / handed-the-phone: same reason

It's the lightest possible safety net, not a security control.

### Why no pause/resume in v0.2

v0.1 had `/pause alice` to disable a peer's connectivity without removing
them. Use case: "Alice is leaving for a month; I'll re-enable when she's
back."

Reality check: that use case is rare for a hobby VPN. Re-adding a peer
takes 5 seconds. The complexity to implement pause (a "disabled" state
machine, a marker in wg0.conf, special handling in IP allocation, special
handling in display) wasn't worth it.

If you genuinely need pause/resume, the v0.1 branch has it.

### Why no real-time unauthorized-DM alerts

Telegram bots are publicly findable via their username. Strangers will
inevitably DM. Real-time alerts ("Stranger DM!" "Stranger DM!" "Stranger
DM!") add noise without action — there's nothing the admin can do about
it. The bot ignores them anyway.

The daily digest summary ("X unauthorized DMs in 24h, here are 3 example
senders") is enough to notice anomalies without being a notification
treadmill.

### Why a static IP

WireGuard clients need to know the server's `Endpoint = IP:PORT`. If the
IP changes, every peer's config breaks until reissued. A static IP is
free while the VM is running. The cost of forgetting is high (everyone
needs reissued configs); the cost of having it is zero.

When the VM is stopped but the IP is reserved, GCP charges ~$7/month for
the IP. To avoid this, `./uninstall.sh` deletes the project entirely. If
you want to "pause" without deleting, `./uninstall.sh --keep-vm` stops
VMs but accepts that ~$7/month cost.

## Data layout

### Files on the VM

```
/etc/wireguard/wg0.conf          server config + peers
                                 root:wgbot 0660 (so wgbot can edit)
                                 (peer names live in state.json, not here)
/etc/wireguard/server.key        backup of server private key
                                 root:root 0600

/etc/wg-admin-bot/config.yaml    bot config (token, admin id, schedules)
                                 root:wgbot 0660
                                 (0660 not 0640: the bot writes admin_id
                                 and pairing tokens here. See schema below.)

/var/lib/wg-admin-bot/state.json runtime state (peer_names, unauthorized
                                 DM log, etc.)
                                 wgbot:wgbot 0600

/var/log/wg-admin-bot/audit.log  append-only audit trail
                                 wgbot:wgbot 0640

/opt/wg-admin-bot/               bot code + venv
                                 root:root 0755

/etc/sudoers.d/wgbot             scoped allowlist for wgbot
                                 root:root 0440

/usr/local/sbin/wg-bot-*         helper scripts (reset-admin, doctor, watchers)
                                 root:root 0755

/run/wg-bot.fifo                 named pipe; watchers → bot
                                 0622 (any user can write)
```

### config.yaml schema

```yaml
timezone: Asia/Jerusalem      # for digest scheduling
admin:
  user_id: 12345              # null until paired
  pairing_token: "ABCD-..."   # null when expired/used
  pairing_token_expires: 1716220000  # unix epoch
telegram:
  bot_token: "123:ABC..."
  bot_username: "wgvpn_a3f9_bot"
wireguard:
  subnet: 10.13.13.0/24
  port: 51820
  dns: [1.1.1.1, 1.0.0.1]
  interface: wg0
digest:
  enabled: true
  vm_time: "13:00"            # in `timezone`
  wg_time: "13:05"
first_peer:
  name: "vpn-a3f9"            # used by startup.sh once
```

### state.json schema

```json
{
  "admin_user_id": 12345,
  "peer_names": { "DEF=": "vpn-a3f9", "JKL=": "johna" },
  "unauthorized_dms": [
    {"ts": 1716200000, "user_id": 999, "username": "rando", "text": "hi"}
  ],
  "first_peer_secret": null
}
```

`peer_names` maps WireGuard public keys to human names — the canonical
name mapping (see "Why peer names live in state.json"). The disabled claim
flow's keys (`peer_chat_ids`, `pending_invites`) are no longer written;
old installs may still carry them harmlessly.

Two state stores by design:
- `config.yaml` for things that survive bot restarts and are
  human-editable (bot token, schedules, subnet)
- `state.json` for runtime data that the bot owns and rewrites
  frequently (peer names, unauthorized-DM log)

### wg0.conf example

```
[Interface]
Address = 10.13.13.1/24
ListenPort = 51820
PrivateKey = ABC=
# The outbound interface is detected at install time via
# `ip route get 8.8.8.8`. On GCP Debian 12 it's ens4; on other clouds /
# distros it may be eth0 or enp0s*. Hardcoding eth0 would break NAT.
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens4 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens4 -j MASQUERADE

[Peer]
PublicKey = DEF=
PresharedKey = GHI=
AllowedIPs = 10.13.13.2/32

[Peer]
PublicKey = JKL=
PresharedKey = MNO=
AllowedIPs = 10.13.13.3/32
```

The bot also writes `# name: <name>` comments at peer-creation time, but
they're stripped on the next `wg-quick save` so they're not shown above.
The authoritative name mapping is in `state.json`'s `peer_names` dict.

## Module layout

```
vm/bot/
├── bot.py          ~700 lines — Telegram handlers, dispatcher
├── wg_cmds.py      ~470 lines — WG peer ops; name map; in-place writes
├── vm_cmds.py      ~120 lines — VM ops (status/reboot/update/logs)
├── claim.py        ~95 lines  — invite/claim flow (disabled; handlers
│                                unregistered in v0.2.6; code preserved
│                                for possible future re-enable)
├── auth.py         ~85 lines  — TOFU pairing, audit log
├── alerts.py       ~95 lines  — FIFO listener, batching
├── config.py       ~85 lines  — YAML loader, in-place save
├── state.py        ~50 lines  — JSON state store, in-place writes
├── digest.py       ~165 lines — daily VM + WG digests, on-demand /digest
├── cli.py          ~45 lines  — first-peer creation for startup.sh
└── requirements.txt

vm/wg-helpers/
├── reset-admin.sh           — sudo wg-bot-reset-admin
├── wg-save-restore.sh       — wraps wg-quick save to restore wg0.conf perms
└── wg-bot-doctor            — read-only audit + optional --fix (4 sections:
                                sys, bot, wg, net)
```

Each module has one job. `bot.py` is the only one that imports Telegram
classes; everything else is testable without a network.

## Threat-aware behaviors

### Why the bot doesn't store peer private keys

WG private keys are generated at `/add` or `/reissue` time, delivered
once via the chat, and forgotten by the server. The server only ever has
public keys + preshared keys.

Consequence: if the bot's state is leaked (state.json, config.yaml, even
wg0.conf), an attacker doesn't get peers' private keys — those exist
only on peers' devices. They do get the server's identity, which lets
them impersonate the server to peers, but that's a different attack.

### Why we re-issue rather than rotating

WG has no notion of "rotate this peer's key in place." A peer's identity
is `(public_key)`; changing it means a new identity. Old configs become
invalid.

This is fine for `/reissue` (admin intent: invalidate the old config).
It's bad for any imagined "rotate keys monthly" automation, which is why
we don't have that.

### Why sudoers has explicit commands, not wildcards

`/etc/sudoers.d/wgbot` lists every exact command the bot can run as root.
There are no wildcards in command paths. There are no `*` in arguments.

This means:
- Bot can run `journalctl -u wg-quick@wg0 *` (the `*` here is glob for
  args, but the leading `-u UNIT` is fixed) — it can't redirect logs from
  arbitrary units
- Bot can run `wg-quick up wg0` but not `wg-quick up some-other-iface`
- Bot can run `apt-get -y upgrade` but not `apt-get install ANYTHING`
- Bot can run `reboot` and `shutdown -h now` but nothing else from `/sbin`

Validated via `visudo -c` at install time.

### Why the FIFO is mode 0622

Watchers run as root (PAM hook), as wgbot (disk timer), or as system
(systemd OnFailure). All three need to write the FIFO. The bot reads as
wgbot. Mode 0622 = world-writable, owner-readable. This is intentional;
anyone on the VM can write a fake alert, but anyone on the VM is already
root or otherwise privileged. Defense-in-depth that costs nothing.

## Failure modes and recovery

### Bot crashes
- systemd `Restart=always` brings it back in 10 seconds
- `OnFailure=` sends a Telegram alert about the crash
- `StartLimitBurst=10/300s` — if it crashes 10x in 5 minutes, systemd
  gives up. Manual `systemctl start wg-admin-bot` needed.

### WG service crashes
- `OnFailure=` runs `wg-bot-wg-health.sh` which restarts WG and reports
- Bot DMs admin: "🔴 WG down" then "🟢 recovered" or "🟥 still dead"
- Peers reconnect automatically on their end (WG protocol is stateless
  from peers' POV — they just keep trying handshakes)

### Disk fills up
- Hourly check via systemd timer
- ≥85% → batched routine alert
- ≥95% → immediate critical alert
- Bot crashes if state.json can't be written; systemd restarts it; same
  failure repeats. Admin must SSH in to clean up.

### Telegram API outage
- `python-telegram-bot` library handles transient failures with backoff
- If Telegram is fully down, the bot is silent. WG keeps working
  (it's kernel-level, doesn't depend on the bot).

### Bot becomes unresponsive but is "running"
- Restart from another channel:
  `gcloud compute ssh ... --command='sudo systemctl restart wg-admin-bot'`

### Admin loses Telegram access
- SSH to VM (uses Google identity, not Telegram)
- `sudo wg-bot-reset-admin`
- New pairing token printed; pair from new Telegram account
- Peers are unaffected: their WG configs keep working throughout

### VM is fully unreachable
- Most likely: GCP outage in that region, or accidental shutdown
- Restart via GCP Console
- Last-resort: `./uninstall.sh && ./install.sh` from your laptop
- All peer configs become invalid; everyone needs a fresh config

### VM is suspected compromised (or just in a corrupted state you can't diagnose)

**Recommended path: purge and rebuild.** This is the disposable-by-design
recovery, and it's by far the cleanest.

```bash
./uninstall.sh OLD_PROJECT_ID
./install.sh                  # makes a new GCP project, new VM, new keys
                              # /add each peer fresh
                              # send each peer their new config
```

Why this is fine to do casually: the VM has nothing on it worth stealing
back. The "secrets" on the box are:

- The WireGuard server private key — useless to an attacker because peers
  re-derive trust from the new server when they import the new config.
- Peer public keys and human-friendly names. The names you chose
  (`johna`, `vpn-a3f9`, etc.) are at most mildly embarrassing.
- The Telegram bot token — rotate it via @BotFather if you want; otherwise
  it just stops being polled by anything once the VM is gone.
- The audit log of who DM'd the bot. Not sensitive.

There's no user data, no browsing history, no stored credentials. The VM
is a stateless WireGuard server with a small management bot. Rebuilding
takes ~10 minutes and the only inconvenience to peers is "import the new
config your admin just sent you."

This is the same response as a peer device theft, scaled up: nuke the
affected key material, reissue. The architecture is built for it —
that's why there's no SLA, no backups, no migration tooling.

When you might **not** want a full rebuild:
- The compromise is unconfirmed and rebuilding is more disruption than
  it's worth. `sudo wg-bot-doctor --verbose` first; it'll surface most
  classes of misconfiguration without any guessing.
- You suspect only the admin Telegram account, not the VM itself. Then
  `sudo wg-bot-reset-admin` is enough (covered above).

## Performance notes

- **Bot idle memory:** ~60 MB RSS (Python interpreter + python-telegram-bot)
- **Bot CPU:** near-zero between events
- **wg-quick save:** ~50 ms per call (rewrites wg0.conf)
- **wg set:** ~10 ms per call
- **Telegram long-poll latency:** 200-500 ms typical
- **Command processing:** typically <1s end-to-end
- **`/update YES` runtime:** depends on packages, usually 30s-3min
- **Digest generation:** ~200 ms

The e2-micro spec (1 GB RAM, ~2x burst vCPU) is overkill for this
workload. Most of the 1 GB is unused.

## Build vs buy summary

|  | Custom (this) | wg-easy + Telegram | Algo + manual |
|---|---|---|---|
| Setup time | ~10 min | ~30 min | ~1 hour |
| Public attack surface | UDP/51820 only | UDP/51820 + TCP/51821 | UDP/51820 |
| Phone-based admin | Yes | Half (web UI) | No |
| Phone-based peer onboarding | N/A — admin couriers config | No | No |
| Maintenance | `/update` from phone | SSH | SSH |
| Tested at scale | No (≤10 peers) | Yes (thousands) | Yes (thousands) |
| You wrote it | Yes | No | No |

We're trading "battle-tested" for "fits the use case exactly." That's
the right tradeoff for one admin and a handful of friends.

## Future work explicitly out of scope

These are intentionally not built and not planned:

- **Webhooks instead of long-poll** — would require a public HTTPS endpoint,
  TLS cert management, and adds attack surface. Long-poll is fine.
- **Multi-region failover** — overkill; if the VM dies, redeploy.
- **Per-peer ACLs** — WG has no native concept; would need iptables marks.
- **Traffic shaping / QoS** — not what a hobby VPN needs.
- **A web admin UI** — the whole point is to not have one.
- **A REST API** — same.
- **Multiple admins** — the trust model assumes one. Two would need a
  consensus mechanism for destructive commands or risk fighting.
- **Reviving the peer claim flow** — the `/claim` / `/invite` flow exists
  in the code but is unregistered (v0.2.6+). Reviving it would need
  another debugging pass; the current "admin couriers configs" model is
  simpler and good enough for the target use case.

If you want any of these, fork it and have fun. The codebase is small
enough to make that easy.
