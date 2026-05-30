# Changelog

## 0.2.10 — 2026-05-30

Critical bug: `/reboot YES` silently unpaired the admin on every reboot.

### Root cause

GCP runs the startup script (`vm/startup.sh`) on **every VM start**, not
just the first boot. The script unconditionally overwrote
`/etc/wg-admin-bot/config.yaml` (wiping the paired `admin_user_id` back
to null) and `/var/lib/wg-admin-bot/state.json` (wiping peer names) on
every reboot. The bot would restart, send "🟢 wg-admin-bot online" (from
its `post_init` hook, using the stale `admin_id` still in memory), then
fail to respond to any further commands because the newly-loaded config
had `admin_user_id: null` and every handler's `@admin_only` check saw a
stranger.

The comment at the top of startup.sh even said "Runs once at first boot"
— this was simply wrong about GCP's behaviour.

### Fix

Three guards added to startup.sh:

- **config.yaml + state.json**: only copied/initialised if config.yaml
  is absent OR has `admin.user_id: null` (i.e. not yet paired). On
  subsequent boots the existing files are preserved; only ownership/mode
  are re-applied.
- **bot code + venv**: only copied/installed if the venv doesn't exist
  yet. Saves ~30s of unnecessary pip install on every reboot.
- **audit.log**: only initialised on first boot (was previously truncated
  on every reboot).

The wg0.conf and first-peer creation were already correctly guarded; this
fix brings config/state/code into line with the same pattern.

## 0.2.9 — 2026-05-28

Correct root-cause fix for the missing VM digest. v0.2.8 fixed the wrong
thing.

### Fixed

- **VM digest HTTP 400 — actual cause identified.** v0.2.8 assumed the
  culprit was a Markdown-special character in the unauthorized DMer's
  *username*. The real cause was the literal label `user_id=` in the
  digest template: the underscore in `user_id` sat OUTSIDE the backtick
  span (only the numeric id was wrapped), so it opened an unterminated
  Markdown italic and Telegram rejected the message. The username
  (`ssegal`, no specials) was never the problem.

  Fix: the whole entry is now wrapped in a single backtick code span
  (`` `id=12345 @username` ``), where Markdown is inert. Username also
  has any backticks stripped defensively so it can't break the span.

- The v0.2.8 plain-text fallback in `send()` remains as a safety net and
  would have rescued this too, but now the message is well-formed in the
  first place.

- **Smoke test rewritten to catch the real bug:** `test_digest_markdown_
  balanced` builds the actual VM digest with unauthorized-DM entries,
  strips inert backtick spans, then asserts `_ * [` are balanced in what
  remains. Verified: it fails on the old `user_id=` template and passes
  on the fix.

## 0.2.8 — 2026-05-28

### Fixed

- **VM digest silently not delivered when an unauthorized DMer's username
  contained a Markdown special character.** The 13:00 VM digest interpolated
  `@username` outside any code span; a username with `_` (e.g. `@some_user`)
  produced unbalanced Markdown, Telegram rejected the whole message with
  HTTP 400 "can't parse entities", and `send()` swallowed it. The 13:05 WG
  digest was unaffected because it doesn't embed arbitrary user strings
  (peer names are inside backticks, where Markdown is inert).

  Fixes:
  - New `_esc()` helper escapes `_ * ` [` in user-controlled strings; the
    VM digest's `@username` is now escaped.
  - `send()` now falls back to plain text (no `parse_mode`) if the Markdown
    attempt returns an error — so a future un-escaped character degrades to
    an unformatted-but-delivered digest instead of silence.
  - `send()` now surfaces the actual HTTP error body in logs instead of a
    generic exception string.

- New smoke test `test_digest_escapes_markdown` covers the escaper.

## 0.2.7 — 2026-05-27

### Added

- **`/digest` command** — on-demand status digest from Telegram, instead
  of waiting for the daily 13:00/13:05 timers. `/digest` sends both the
  VM and WG digests; `/digest vm` or `/digest wg` sends just one. Reuses
  the existing `digest.build_vm_digest()` / `build_wg_digest()` functions
  (same content the timers produce), called in-process. Added to `/help`.

## 0.2.6 — 2026-05-27

Two small targeted changes after v0.2.5 successfully built a working VM.

### Fixed

- **Installer readiness check was reporting healthy bots as unhealthy.**
  The "wait for Application started" loop captured gcloud SSH output
  through `tail -1` and parsed it as an integer. If gcloud emitted any
  auxiliary lines, the parse silently failed and the loop never iterated.
  Now uses `grep -q` and the SSH command's exit code directly — no parsing
  needed. Same fix applied to the bootstrap-complete check.

### Changed

- **`/claim`, `/leave`, `/invite`, `/unclaim` commands disabled** in the
  bot dispatcher. The peer-claim flow has known bugs and is hidden until
  it's repaired. The handler code in `claim.py` and `bot.py` is preserved
  (commented out in `main()` only) so it can be re-enabled cleanly later.
- `/help` no longer mentions the disabled commands.
- `/peers` no longer shows the ✉ claim indicator.
- `/peer NAME` no longer shows the "Claim:" line.
- `/reissue NAME` always sends the config to the admin (no claim fallback).

## 0.2.5 — 2026-05-27

Three real bugs found via end-to-end testing on a real VM, plus a
correctness fix for the peer-name design and a brand-new doctor section.

### Fixed

- **Hardcoded `eth0` in `wg0.conf` PostUp/PostDown rules.** GCP Debian 12
  uses `ens4`, so the MASQUERADE rule attached to a nonexistent interface
  and outbound traffic from the VPN was silently dropped. The startup
  script now auto-detects the outbound interface via
  `ip route get 8.8.8.8` and bakes that into the rules. Fatal error
  raised if detection fails.

- **`config.yaml` mode was `0640` instead of `0660`.** The bot needs to
  write `config.yaml` during TOFU pairing (to record `admin_user_id`)
  and on token refresh. Read-only-for-group made these writes fail.
  Latent since v0.1, only fired now that pairing actually completes.

- **`wg-quick save` strips all comments from `wg0.conf` on every call**,
  including our `# name:` markers. The previous design stored peer names
  ONLY as comments, so every peer add/remove erased every other peer's
  name. The first peer's name vanished as soon as the second peer was
  added.

  **Fix:** peer names now live in `state.json` (`peer_names` dict,
  pubkey→name). `list_peers()` reads kernel state via `wg show wg0 dump`
  and joins with the name map. Comments are still written as a
  human-readability aid but no code relies on them. Bootstrap path:
  if `peer_names` is empty (upgrade from older version), recover names
  from any surviving `# name:` comments in the conf.

### Added

- **New `net` audit section in `wg-bot-doctor`** (5 checks):
  - `net.ip_forward` — sysctl is 1
  - `net.wan_iface` — outbound interface detected
  - `net.wg_conf_iface` — wg0.conf MASQUERADE references the right interface
  - `net.masquerade` — live iptables rule references the right interface
  - `net.forward_rule` — FORWARD chain accepts wg0 traffic
  - `net.outbound` — VM can ping 8.8.8.8 (informational)

  All five have `--fix` support except outbound ping (which is just a
  diagnostic signal).

- **New `--section net` flag** for targeted network audits.

- **New smoke test:** `test_names_survive_comment_stripping` — wipes all
  `# name:` comments from a test wg0.conf and verifies `list_peers()`
  still finds the peer. Would have caught the wg-quick comment-strip
  bug at build time.

### Migration from v0.2.4

If upgrading an existing install where peers have `# name:` comments in
wg0.conf but `state.json` lacks a `peer_names` dict, `list_peers()`
performs a one-shot recovery: scans the conf for `# name:` markers,
populates `peer_names`, persists it. Future operations rely on
`peer_names` exclusively.

For an install where comments were already lost (like the ae1f VM today
before manual recovery), names need to be re-entered. There's no
automated recovery from "we lost the names entirely" — the WG kernel
state has pubkeys, but no source of truth says which pubkey is which
human name.

## 0.2.4 — 2026-05-27

Same class of bug as v0.2.2 fixed in a different module. v0.2.3 finally
reached the admin pairing step (yay) only to fail writing the admin
user_id because of a latent permissions issue that had been there since
v0.2.0 but never previously triggered.

### Fixed

- **`config.save()` was using `.tmp + rename`** which fails when the parent
  directory `/etc/wg-admin-bot/` is `0750 root:wgbot` (the bot can write
  the file but not create siblings in the dir). Switched to in-place
  write, same pattern as `wg_cmds._write_conf`.
- **`state._write()` same change**, for consistency and defense in depth
  (the state dir IS owned by wgbot so it would have worked, but the
  in-place pattern is now uniform across all three persistent writes).
- **Two new smoke tests** verify both write paths don't leave `.tmp` files
  behind. Codebase audit confirms no other `.tmp + rename` patterns
  remain anywhere.

The original PermissionError class is now structurally impossible: every
write path to a file in a non-wgbot-owned directory uses in-place write.

## 0.2.3 — 2026-05-27

UX fix for a Telegram quirk that confused first-time pairing.

### Fixed

- **Telegram's first-chat GUI** hides the text input and shows only a
  Start button when you open a chat with a new bot. That button sends
  a bare `/start` (no argument). Until that first message goes through,
  the user can't type — so the installer's "send /start TOKEN" instruction
  was literally impossible to follow as the first message.

  Now:
  - The bot's reply to a bare `/start` is friendly, names the GUI
    quirk explicitly, and gives the exact next-message template.
  - The installer's NEXT STEPS lists two explicit steps: press Start,
    then send the token message.
  - SETUP.md (admin) and USER.md (peer) both call out the quirk in
    the pairing/claim walkthroughs.

  No behavior change in the actual pairing protocol — just better
  guidance so users don't get stuck on the GUI.

## 0.2.2 — 2026-05-27

Bugfix release. v0.2.1 shipped two regressions that prevented startup
and corrupted file permissions during peer operations. Both fixed,
plus real verification infrastructure to prevent this class of bug.

### Fixed

- **`ApplicationBuilder.post_start` does not exist in python-telegram-bot
  21.x.** Reverted to a single `post_init` callback. The PTBUserWarning
  about tasks not being awaited is a known false-positive — `run_polling()`
  handles task lifecycle correctly. Comment in code documents this.
- **`_write_conf()` was changing wg0.conf ownership and mode on every
  write.** Atomic `.tmp + rename` replaces the file with a new inode
  owned by the writing user (wgbot), leaving wg0.conf as `wgbot:wgbot
  0600`. Switched to in-place truncate-and-write so the existing file's
  ownership and mode are preserved. Tradeoff: not atomic, but wg0.conf
  is <10 KB and writes are rare.
- **`/etc/wireguard` directory mode tightened back to 750.** The 770
  was only needed for the `.tmp + rename` pattern; now that we write
  in place, the bot doesn't need write access on the directory.

### Added

- **`tests/verify_ptb_api.py`** — instantiates `ApplicationBuilder` from
  the installed PTB version and verifies every method `bot.py` calls
  on it actually exists. Would have caught the `post_start` typo at
  build time. Now part of CI.
- **`tests/smoke_wg_cmds.py`** — end-to-end test of peer add/remove
  with a faked WireGuard backend, in a temp directory. Asserts
  ownership/mode of wg0.conf is preserved across every operation
  (the v0.2.1 bug). Catches the regression class directly.
- PTB version pin tightened from `>=21,<22` to `>=21.6,<22`.

## 0.2.1 — 2026-05-27

Bugfix release. v0.2 installed cleanly but failed at pairing time due to
a cascade of permission-related issues; this fixes all of them at the
source instead of papering over with manual recovery.

### Fixed

- **`/etc/wireguard` directory mode** — Debian's wireguard package ships
  the directory at `0700 root:root`, which blocked the `wgbot` user from
  even traversing it. startup.sh now sets `770 root:wgbot` *before* any
  bot operations.
- **`wg-quick save` resetting wg0.conf ownership** — every peer add/remove
  invoked `wg-quick save`, which rewrote the file with umask 077 and
  stripped our group ownership, breaking the next read by the bot. We now
  call it through a new `/usr/local/sbin/wg-save-restore` wrapper that
  performs save + chown + chmod atomically as root.
- **FIFO creation in `/run`** — the bot ran as `wgbot` and couldn't
  `mkfifo` in `/run`. Pre-created via `/etc/tmpfiles.d/wg-admin-bot.conf`
  (survives reboot) with an `ExecStartPre=` belt-and-braces in the
  systemd unit.
- **systemd unit had `StartLimitIntervalSec` in `[Service]`** instead of
  `[Unit]`. Moved. Restart-loop guard is now actually enforced.
- **First-peer creation failure was swallowed** — `|| echo "WARN: ..."`
  let installs "succeed" with no first peer. Now fatal with diagnostic
  dump.
- **Bot ate messages during crashes** — `drop_pending_updates=True` on
  startup, combined with no error handler, meant `/start` attempts
  vanished if the bot crashed mid-handling. Now: `drop_pending_updates=
  False`, plus a global error handler that logs the exception and replies
  to the user with a brief error code.
- **`Application.create_task` called before start** — PTBUserWarning
  about tasks not being awaited. Task creation moved from `post_init` to
  `post_start` hook.

### Added

- **`wg-bot-doctor`** — standalone audit/debug tool installed at
  `/usr/local/sbin/wg-bot-doctor`. Read-only by default; `--fix` for safe
  auto-repair. Three audit sections (sys, bot, wg) covering file
  ownership, service state, log analysis, Telegram connectivity,
  kernel-vs-config peer consistency, IP allocation conflicts, and
  claim mappings. Outputs human-readable or `--json`. See ADMIN.md.

### Improved

- **Installer readiness check** — was `is-active` (flips true briefly
  during crash loops); now checks for the "Application started" log line
  plus a 10-second stability requirement. On failure, dumps 50 lines of
  bot log + 30 lines of startup log to your terminal directly so you
  don't have to SSH in just to see the error.
- **Installer output is honest** — if the bot isn't healthy at the end
  of the wait window, the final message says so and offers next steps,
  instead of printing a misleading "✓ Installation complete" banner.

### Not changed

- Wire protocol, command surface, peer model, claim flow, sudoers scope
  (other than the new wrapper) — all unchanged from v0.2.

## 0.2.0 — 2026-05-26

Rewrite focused on simplification. ~40% smaller than 0.1, no functional
regressions for the documented use case.

### Changed

- WG peer operations now use `wg set` + `wg-quick save` instead of a
  custom config parser. Peer names stored as `# name: X` comments
  preserved by `wg-quick save`.
- IP allocation now reads `wg show wg0 allowed-ips` (single source of
  truth) instead of a separate state file.
- Removed pause/resume — to disable a peer, `/remove` them. Re-adding
  takes 5 seconds.
- Three orthogonal commands clarified: `/reissue` (new WG keys),
  `/unclaim` (clear Telegram binding only), `/remove` (delete both).
- `/help` now explains the difference between these three.
- Unauthorized DM alerts no longer immediate; surfaced in the daily VM
  digest as a 24-hour count.
- `/status` includes the public IP.
- VM and WG digests both include the public IP.

### Added

- `/leave YES` — claimed peers can self-remove without admin action.
- Planned-outage broadcasts to all claimed peers before `/reboot`,
  `/shutdown`, `/restart wg`, and `/update YES`.
- Installer supports reusing an existing Telegram bot (validates via
  `getMe`).
- Installer detects the laptop's timezone and bakes it into the digest
  timers (VM itself stays in UTC).
- First peer name defaults to `vpn-<hex>` matching the server hex.

### Removed

- Watchdog timer (heartbeat staleness). systemd `Restart=always` is
  sufficient.
- Email fallback alerting.
- Comment-marker DSL for paused-state tracking (no longer needed).
- "Use existing project" path in the installer. Always creates new.

## 0.1.0

Initial private version. ~3500 lines, custom parser, FIFO+watchdog+OnFailure
+PAM+disk-check+heartbeat alerting, pause/resume peers.
