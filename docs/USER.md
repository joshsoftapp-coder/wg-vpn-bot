# USER.md — for peers (users of the VPN)

If you've been told "here's a VPN, use Telegram to get your config" — this
is the guide for you.

## What you'll get

A WireGuard VPN config that routes all your traffic through a private
server. You'll import it into the WireGuard mobile or desktop app.

## Setup, in 4 steps

### 1. Receive the invite token from your admin

The admin will send you something that looks like this, through any channel
(WhatsApp, SMS, in person):

> Send this to **@your_vpn_bot** in Telegram:
> `/claim ABCD-EFGH-IJKL`
> (Expires in 30 minutes.)

### 2. Open Telegram and find the bot

Search Telegram for the bot's username (`@your_vpn_bot` in the example
above). Tap it.

**Telegram quirk:** the first time you open a chat with a bot, you'll
see a **Start** button instead of a text input. Press it. The bot will
send back a welcome message. Now you can type.

### 3. Send the claim command

Now that the text input is showing, type and send the exact `/claim
ABCD-EFGH-IJKL` line you received.

If everything is fine, the bot will reply:

> ✅ Claimed peer 'alice'.
> Your admin will now /reissue your config — you'll receive it here shortly.

### 4. Import the config the admin sends

A moment later, the admin will run `/reissue` and you'll receive **two
messages from the bot**:

- A file: `alice.conf`
- An image: a QR code

**On your phone:**
1. Install the WireGuard app from the App Store / Play Store
2. Open it, tap "+", choose "Create from QR code"
3. Scan the QR code (you can scan it from the same Telegram screen if you
   only have one device — let me know if you need a workaround)
4. Toggle the connection on

**On a computer:**
1. Install the WireGuard app from <https://www.wireguard.com/install/>
2. Download the `.conf` file from Telegram
3. In the WireGuard app: "Import tunnel(s) from file"
4. Click "Activate"

## You're connected

That's it. Your traffic is now going through the VPN.

You can check that the VPN is working by:
- Visiting <https://whatismyipaddress.com> — should show the server's IP, not yours
- The WireGuard app should show "Active" with bytes counting up

## What the bot will say to you, ever

After claiming, the bot will DM you only in three situations:

- **You requested it** — the admin runs `/reissue` (new config) and you get
  the new files
- **Planned outage** — "VPN is rebooting (~60 seconds)" or "VPN is shutting
  down" — so you know it's planned, not broken
- **Acknowledgment of your /leave** — see below

The bot does **not** send you alerts when the VPN goes briefly offline by
itself, when other peers connect, or anything else. If your connection
drops, your phone will reconnect automatically when the server is back.

## What you can do

You have exactly **one** command:

```
/leave YES
```

This removes your peer from the VPN. Your config stops working immediately.
The admin is notified. You can ask the admin for a new invite later if you
change your mind.

Sending `/leave` without `YES` will ask for confirmation first.

Any other commands you try will get a polite "your only command here is
/leave YES" reply.

## Things to know

### If you lose your phone or get a new one

Tell the admin. They'll run `/reissue alice` (assuming your peer is named
`alice`). The bot will DM you the new config directly — no claim needed,
because you're already claimed.

If you also lost your Telegram account, see "If your Telegram got
compromised" below.

### If your Telegram got compromised

Tell the admin immediately. They'll:
1. `/unclaim alice` — bot stops being able to DM your old account
2. `/reissue alice` — new VPN config issued
3. `/invite alice` — fresh claim token, sent to you via a different channel
4. You claim with the new token from your new Telegram account

Your VPN access is fully reset.

### If you didn't actually need the VPN and want to go away

```
/leave YES
```

You're done. The peer is removed. You can block the bot in Telegram if you
want — it won't be able to DM you again anyway.

### Privacy

The bot stores:
- Your Telegram user_id (bound to your peer name)
- Your username at claim time, for the admin's reference

The bot does **not** store:
- Your WireGuard private key — that's only ever on your device
- Your Telegram messages — they pass through Telegram normally
- Your IP, location, or browsing — the VPN server sees your traffic but
  doesn't log it (unless the admin set up extra logging, which our default
  setup does not)

You can leave at any time with `/leave YES`. The peer is gone, your chat_id
binding is gone, you're done.

## Troubleshooting

**"No such invite, or it expired/was burned."**
The token's 30-minute window passed, or someone else used it first. Ask
your admin for a fresh `/invite alice`.

**"This is a private VPN bot."**
You sent something other than `/claim TOKEN` and you're not claimed yet.
The bot ignores you. Send the claim command.

**The bot doesn't respond at all.**
Make sure you pressed "Start" in the chat first. If still nothing, the
bot is offline — tell the admin.

**My VPN was working, suddenly it's not.**
Try reconnecting in the WireGuard app first. If that doesn't help, ask
your admin to check `/status`. The server might be down or rebooting.

**I scanned the QR but the WireGuard app shows red / no traffic.**
- Make sure the WireGuard toggle is actually ON
- Check that you have data/wifi
- The server's static IP is in the config — if the server was rebuilt
  recently, your config might be stale. Ask admin for `/reissue`.

## That's all

This is intentionally a small surface. You scan a QR, you have a VPN.
Everything else is the admin's problem.
