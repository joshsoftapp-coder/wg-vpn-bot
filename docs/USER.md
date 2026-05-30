# USER.md — for peers (users of the VPN)

If someone set up a VPN for you and sent you a config file, this is your
guide. It takes about two minutes.

## What you'll get

Your admin will send you a WireGuard config — either a file named something
like `johna.conf`, or a QR code image, or both. They'll send it through
whatever channel you already use with them (WhatsApp, Signal, email, AirDrop,
in person). You do **not** need Telegram, an account, or any login. You just
import the config into the free WireGuard app.

## Setup

### On your phone

1. Install the **WireGuard** app from the App Store or Google Play.
2. Open it, tap the **+** button.
3. Choose **Create from QR code** and scan the QR your admin sent — or
   choose **Create from file or archive** and pick the `.conf` file.
4. Give it any name you like (e.g. "My VPN").
5. Toggle it **on**.

### On a computer

1. Install WireGuard from <https://www.wireguard.com/install/>.
2. Save the `.conf` file your admin sent you.
3. In the WireGuard app: **Import tunnel(s) from file**, pick the `.conf`.
4. Click **Activate**.

## You're connected

That's it — your traffic now routes through the VPN server.

Check it's working:
- Visit <https://whatismyipaddress.com> — it should show the server's
  location, not yours.
- The WireGuard app shows "Active" with the data counters ticking up.

To pause the VPN, toggle it off in the app. To resume, toggle it on. Your
phone reconnects automatically if the connection briefly drops.

## Things to know

### This VPN routes all your traffic

While the tunnel is on, all your internet traffic goes through the server.
That's the point — it hides your traffic from the local network (coffee-shop
wifi, hotel, airport) and makes you appear to be in the server's location.

### If you get a new phone or lose your config

Just ask your admin to send you the config again, or to issue a fresh one.
There's nothing for you to "recover" — the config is a small text file.

### If your device is lost or stolen

Tell your admin. They can remove your peer from the server so the lost
config stops working, and issue you a new one for your replacement device.

### Privacy

Your WireGuard private key lives only inside the config on your device. The
server sees your traffic in transit (as any VPN or ISP would) but the
default setup keeps no browsing logs. Ask your admin if you want specifics
about their setup.

## Troubleshooting

**The WireGuard app shows red / no traffic.**
- Make sure the toggle is actually ON.
- Make sure you have wifi or mobile data.
- If the server was recently rebuilt, your config may be stale — ask your
  admin for a fresh one.

**It connects but websites don't load.**
Toggle the tunnel off and on. If it still fails, tell your admin — the
server may be rebooting.

**I can't import the QR / file.**
Make sure you installed the official WireGuard app (not a lookalike). The
QR must be scanned from *within* the WireGuard app's "add tunnel" screen,
not your camera app.

## That's all

You scan a code, you have a VPN. Everything else is the admin's job.
