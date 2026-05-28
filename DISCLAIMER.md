# DISCLAIMER

> ⚠️ **CRITICAL NOTICE:** Read this document entirely before running the `./install.sh` script. By deploying this software, you acknowledge that you understand the financial, operational, and architectural boundaries outlined below.

---

## 🛠️ WHAT THIS PROJECT ACTUALLY IS (MANAGE YOUR EXPECTATIONS)

* **Just a Deployment Wrapper:** In the bottom line, this project is primarily an infrastructure deployment system driven by an installer shell script. It is not a commercial software product, a standalone application, or a custom VPN network service.
* **Standard WireGuard Under the Hood:** This script does not invent its own encryption or tunneling mechanisms; it simply provisions a standard virtual machine and configures standard, native **WireGuard**. The core performance and routing security are entirely dependent on WireGuard's default behaviors.
* **No Advanced Features:** Because this relies strictly on native WireGuard defaults, it explicitly lacks enterprise features such as per-peer traffic shaping, bandwidth limits, custom peer firewalls, or a graphical web administration interface.

---

## 💰 CHARGE MAY APPLY (GCP Infrastructure Costs)

* **Free Tier Limitations:** The Google Cloud Platform (GCP) free tier only covers highly specific usage limits: one `e2-micro` instance, a 30 GB standard disk, and up to 1 GB of outbound data traffic per month.
* **Egress Overages:** If your VPN peers exceed the cumulative 1 GB monthly outbound traffic limit, Google will automatically charge your linked billing account approximately $0.12 per GB for all subsequent traffic.
* **Idle Static IP Fees:** If you pause or stop the virtual machine but do not fully delete the project infrastructure, Google Cloud charges approximately $7.00 per month for retaining an unattached static IP address.
* **Avoiding Charges:** To guarantee that you accumulate $0/month in fees when the VPN is not in use, you must fully purge the infrastructure by running `./uninstall.sh` rather than simply stopping the instance.
* **Billing Responsibility:** You are solely responsible for monitoring your Google Cloud billing console; the automated management bot has no capability to track, report, or limit your real-world financial exposure.

---

## 🛑 NO WARRANTY & AT YOUR OWN RISK

* **Provided "As Is":** This software is open-source and provided entirely "as is" under the terms of the MIT License.
* **Zero Liability:** The authors and maintainers express absolutely no warranties of any kind and assume zero liability for data loss, service drops, configuration corruption, or unexpected cloud infrastructure charges.
* **Not for Production:** This architecture is explicitly designed for casual hobby use among a small group of peers (fewer than 10). It is strictly **not** for production environments, enterprise deployments, or serving paying customers.
* **Disposable Design:** There is no service level agreement (SLA) or automated backup mechanism built into this deployment. If the system enters an unresolvable or corrupted state, the primary recovery path is to completely nuke the setup using `./uninstall.sh` and build it fresh from scratch via `./install.sh`.

---

## 🧠 KNOW WHAT YOU ARE DOING

* **Administrative Role:** You are the system administrator. You must possess a basic understanding of computer networking, Linux system administration, and firewall security configurations to securely manage this tool.
* **The Weakest Link:** Your personal Telegram account serves as the absolute authentication factor for highly destructive commands such as `/reboot YES`, `/shutdown YES`, and `/remove YES`. If your personal Telegram session is compromised, an attacker gains full control over your VPN topology and server operational states.
* **Privacy Constraints:** All command exchanges and configuration distributions between the admin and the bot pass directly through Telegram's commercial servers in cleartext to them. Do not utilize this setup if your threat model demands absolute transport invisibility or protection from corporate/state-level metadata surveillance.
