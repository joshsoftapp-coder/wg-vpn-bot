"""
WireGuard peer operations using wg's own tools.

Source of truth: /etc/wireguard/wg0.conf.
Peer names are stored as comment lines: '# name: <name>' immediately before
the [Peer] block. wg-quick save preserves these comments.

We do NOT pause/resume — to disable a peer, remove it.
We do NOT store private keys server-side — they exist only in the .conf
we hand to the user once.
"""
from __future__ import annotations

import ipaddress
import logging
import re
import subprocess
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import config

log = logging.getLogger(__name__)

WG_CONF = Path("/etc/wireguard/wg0.conf")
WG_IFACE = "wg0"
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
NAME_COMMENT_RE = re.compile(r"^#\s*name:\s*([A-Za-z0-9_-]{1,32})\s*$")


@dataclass
class Peer:
    name: str
    public_key: str
    allowed_ips: str
    preshared_key: str | None = None
    private_key: str | None = None  # only known at creation


# ---------- low-level helpers ----------

def _run_text(cmd: list[str], **kw) -> str:
    return subprocess.check_output(cmd, text=True, **kw).strip()


def _wg_genkey() -> str: return _run_text(["wg", "genkey"])
def _wg_pubkey(priv: str) -> str: return _run_text(["wg", "pubkey"], input=priv)
def _wg_genpsk() -> str: return _run_text(["wg", "genpsk"])


def _read_conf() -> str:
    return WG_CONF.read_text()


def _write_conf(text: str) -> None:
    """Write wg0.conf in place.

    We deliberately do NOT use the atomic .tmp + rename pattern: rename
    replaces the file with a new inode owned by the writing user (wgbot),
    which would change wg0.conf to wgbot:wgbot mode 600 and break the
    next read by `wg-quick up`. In-place truncate-and-write preserves
    the file's existing ownership and mode (root:wgbot 0660).

    Atomicity tradeoff: wg0.conf is small (<10 KB typical) and writes
    are rare (peer add/remove only). The partial-write window is
    microseconds. If a crash truly hit mid-write, restoring from
    `wg-quick showconf wg0` would recover the state.
    """
    with open(WG_CONF, "w") as f:
        f.write(text)


def _save_runtime() -> None:
    """Persist current kernel state to wg0.conf via the wg-save-restore wrapper.

    The wrapper runs `wg-quick save wg0` and then restores root:wgbot 0660
    on the file. wg-quick save uses umask 077 internally and would otherwise
    leave the file as 600 root:root, breaking the next read by wgbot.
    """
    subprocess.check_call(["sudo", "/usr/local/sbin/wg-save-restore"])


# ---------- name <-> pubkey mapping ----------
#
# Design note (v0.2.5):
# `wg-quick save` does not preserve comments in wg0.conf — it serializes the
# kernel state via `wg showconf` which strips everything. So we cannot store
# peer names as `# name: X` comments in wg0.conf; they would be lost on the
# next `wg-quick save`.
#
# Instead, the source of truth for pubkey→name is `state.json`'s `peer_names`
# dict: { pubkey: name }. Peer membership comes from the kernel (via `wg
# show wg0`), peer keys come from wg0.conf, peer names come from state.json.
#
# We still write `# name:` comments into wg0.conf at peer-creation time as a
# debugging aid for humans reading the file — but we never RELY on them being
# there. Parsing always falls back to the state.json mapping.

import state


def _names_map() -> dict[str, str]:
    """Return the pubkey→name map from state. Always returns a dict."""
    m = state.get("peer_names", {}) or {}
    return {str(k): str(v) for k, v in m.items()}


def _set_name(pubkey: str, name: str) -> None:
    def mutate(cur):
        cur = cur or {}
        cur[pubkey] = name
        return cur
    state.update("peer_names", mutate)


def _drop_name(pubkey: str) -> None:
    def mutate(cur):
        cur = cur or {}
        cur.pop(pubkey, None)
        return cur
    state.update("peer_names", mutate)


def _parse_named_peers(conf_text: str) -> list[Peer]:
    """Walk the conf and pair '# name: X' comments with [Peer] blocks.

    DEPRECATED for production use — kept for compatibility and tests.
    Real peer enumeration goes through list_peers() which reads kernel state
    and the state.json name map.
    """
    peers: list[Peer] = []
    lines = conf_text.splitlines()
    i = 0
    while i < len(lines):
        m = NAME_COMMENT_RE.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        # Look for the following [Peer] block
        j = i + 1
        # Skip blank/comment lines between marker and [Peer]
        while j < len(lines) and not lines[j].strip().startswith("[Peer]"):
            if lines[j].strip().startswith("[") or NAME_COMMENT_RE.match(lines[j]):
                # Hit another section; this marker is orphan
                break
            j += 1
        if j >= len(lines) or not lines[j].strip().startswith("[Peer]"):
            i += 1
            continue
        # Parse the [Peer] block
        pub = ""
        psk = None
        ips = ""
        k = j + 1
        while k < len(lines):
            ln = lines[k].strip()
            if not ln:
                k += 1
                continue
            if ln.startswith("[") or NAME_COMMENT_RE.match(lines[k]):
                break
            if ln.lower().startswith("publickey"):
                pub = ln.split("=", 1)[1].strip()
            elif ln.lower().startswith("presharedkey"):
                psk = ln.split("=", 1)[1].strip()
            elif ln.lower().startswith("allowedips"):
                ips = ln.split("=", 1)[1].strip()
            k += 1
        if pub and ips:
            peers.append(Peer(name=name, public_key=pub, allowed_ips=ips, preshared_key=psk))
        i = k
    return peers


def _kernel_peer_blocks() -> list[dict]:
    """Read peers from the kernel (ground truth for membership + IPs)."""
    try:
        out = _run_text(["sudo", "/usr/bin/wg", "show", WG_IFACE, "dump"])
    except subprocess.CalledProcessError:
        return []
    rows = out.splitlines()[1:]  # skip interface line
    peers = []
    for row in rows:
        cols = row.split("\t")
        if len(cols) < 4:
            continue
        peers.append({
            "pubkey": cols[0],
            "psk": cols[1] if cols[1] != "(none)" else None,
            "endpoint": cols[2] if cols[2] != "(none)" else "",
            "allowed_ips": cols[3],
        })
    return peers


def list_peers() -> list[Peer]:
    """Enumerate peers from kernel state, joining names from state.json.

    Falls back to wg0.conf comments only when state.json has no mapping —
    this matters for the very first run after upgrading from v0.2.4 where
    state.json's peer_names is empty but conf comments exist.
    """
    names = _names_map()
    # Fallback: bootstrap names from conf comments if state is empty
    if not names:
        for p in _parse_named_peers(_read_conf()):
            names[p.public_key] = p.name
        if names:
            # Persist what we recovered for future runs
            state.set_("peer_names", names)

    peers: list[Peer] = []
    for kp in _kernel_peer_blocks():
        name = names.get(kp["pubkey"], f"unnamed-{kp['pubkey'][:8]}")
        peers.append(Peer(
            name=name,
            public_key=kp["pubkey"],
            allowed_ips=kp["allowed_ips"],
            preshared_key=kp["psk"],
        ))
    return peers


def get_peer_by_name(name: str) -> Peer | None:
    for p in list_peers():
        if p.name == name:
            return p
    return None


def peer_name_taken(name: str) -> bool:
    return any(p.name == name for p in list_peers())


# ---------- IP allocation ----------

def _allocated_ips() -> set[str]:
    """Read allowed-ips from `wg show wg0 allowed-ips` (single source of truth)."""
    try:
        out = _run_text(["sudo", "/usr/bin/wg", "show", WG_IFACE, "allowed-ips"])
    except subprocess.CalledProcessError:
        return set()
    ips: set[str] = set()
    for ln in out.splitlines():
        # Format: <pubkey>\t<ip1>,<ip2>...
        parts = ln.split("\t", 1)
        if len(parts) < 2:
            continue
        for ip in parts[1].split(","):
            ip = ip.strip()
            if "/" in ip:
                ips.add(ip.split("/")[0])
            elif ip:
                ips.add(ip)
    return ips


def _next_ip() -> str:
    subnet = ipaddress.ip_network(config.get("wireguard.subnet", "10.13.13.0/24"))
    used = _allocated_ips()
    server_ip = str(ipaddress.ip_address(int(subnet.network_address) + 1))
    used.add(server_ip)
    for host in subnet.hosts():
        if str(host) not in used:
            return f"{host}/32"
    raise RuntimeError("WireGuard subnet is full")


# ---------- peer ops ----------

def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def add(name: str) -> Peer:
    if not NAME_RE.match(name):
        raise ValueError("Peer name must match ^[A-Za-z0-9_-]{1,32}$")
    if peer_name_taken(name):
        raise ValueError(f"Peer '{name}' already exists. Pick another name or /remove first.")

    priv = _wg_genkey()
    pub = _wg_pubkey(priv)
    psk = _wg_genpsk()
    ip = _next_ip()

    # Add to running interface via wg set
    # We pass the PSK via a temp file because wg set wants a path.
    import tempfile
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write(psk)
        psk_path = f.name
    try:
        subprocess.check_call([
            "sudo", "/usr/bin/wg", "set", WG_IFACE,
            "peer", pub,
            "preshared-key", psk_path,
            "allowed-ips", ip,
        ])
    finally:
        Path(psk_path).unlink(missing_ok=True)

    # CRITICAL: record the pubkey→name mapping in state BEFORE wg-quick save.
    # If anything goes wrong between here and the comment write, the name
    # is still recoverable from state.json.
    _set_name(pub, name)

    # Persist to wg0.conf via wg-quick save (strips all comments — that's OK,
    # the name lives in state.json now).
    _save_runtime()

    # Best-effort: write a '# name:' comment into the conf for human
    # readability. It WILL be stripped on the next wg-quick save, but it's
    # nice for anyone reading the file by hand right after creation.
    _add_name_comment(pub, name)

    return Peer(name=name, public_key=pub, allowed_ips=ip,
                preshared_key=psk, private_key=priv)


def _add_name_comment(pubkey: str, name: str) -> None:
    """Best-effort: insert '# name:' comment in wg0.conf for human readability.

    NOTE: wg-quick save strips all comments, so this comment is ephemeral —
    valid only until the next save. The authoritative name mapping lives
    in state.json's peer_names dict, not here.
    """
    text = _read_conf()
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    inserted = False
    while i < len(lines):
        # If we hit a [Peer] block, peek to see if its PublicKey matches
        if lines[i].strip() == "[Peer]" and not inserted:
            block = [lines[i]]
            j = i + 1
            while j < len(lines) and not lines[j].strip().startswith("[") \
                  and not NAME_COMMENT_RE.match(lines[j]):
                block.append(lines[j])
                j += 1
            block_text = "\n".join(block)
            m = re.search(r"PublicKey\s*=\s*(\S+)", block_text)
            if m and m.group(1) == pubkey:
                # Don't double-insert: check the line above isn't already our comment
                if not (out and NAME_COMMENT_RE.match(out[-1] if out else "")):
                    out.append(f"# name: {name}")
                    inserted = True
            out.extend(block)
            i = j
            continue
        out.append(lines[i])
        i += 1
    _write_conf("\n".join(out) + "\n")


def remove(name: str) -> Peer:
    p = get_peer_by_name(name)
    if not p:
        raise ValueError(f"Peer '{name}' not found")

    subprocess.check_call([
        "sudo", "/usr/bin/wg", "set", WG_IFACE,
        "peer", p.public_key, "remove",
    ])
    _save_runtime()
    # Drop the name from state.json (the authoritative mapping).
    _drop_name(p.public_key)
    # Best-effort cleanup of any leftover '# name:' comment in conf (though
    # wg-quick save already stripped all comments).
    _strip_orphan_name_comments()
    return p


def _strip_orphan_name_comments() -> None:
    """Remove '# name: X' lines that aren't followed by a [Peer] block."""
    text = _read_conf()
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        if NAME_COMMENT_RE.match(lines[i]):
            # Look ahead — is the next non-blank line a [Peer] block?
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j >= len(lines) or not lines[j].strip().startswith("[Peer]"):
                i += 1  # skip this orphan comment
                continue
        out.append(lines[i])
        i += 1
    _write_conf("\n".join(out) + "\n")


def reissue(name: str) -> Peer:
    """Remove the old peer with this name, then add a fresh one (same name)."""
    old = get_peer_by_name(name)
    if not old:
        raise ValueError(f"Peer '{name}' not found")
    remove(name)
    return add(name)


# ---------- runtime status from wg show ----------

def runtime_status() -> dict[str, dict]:
    try:
        out = _run_text(["sudo", "/usr/bin/wg", "show", WG_IFACE, "dump"])
    except subprocess.CalledProcessError:
        return {}
    result: dict[str, dict] = {}
    rows = out.splitlines()[1:]  # first row is interface info
    for line in rows:
        cols = line.split("\t")
        if len(cols) < 8:
            continue
        pub, psk, endpoint, allowed, last_hs, rx, tx, keepalive = cols[:8]
        result[pub] = {
            "endpoint": endpoint if endpoint != "(none)" else "",
            "allowed_ips": allowed,
            "last_handshake": int(last_hs) if last_hs.isdigit() else 0,
            "rx": int(rx) if rx.isdigit() else 0,
            "tx": int(tx) if tx.isdigit() else 0,
        }
    return result


def wg_active() -> bool:
    try:
        out = _run_text(["sudo", "/bin/systemctl", "is-active", "wg-quick@wg0"],
                        stderr=subprocess.DEVNULL)
        return out == "active"
    except subprocess.CalledProcessError:
        return False


# ---------- client .conf rendering ----------

def render_client_conf(peer: Peer, server_endpoint: str) -> str:
    if not peer.private_key:
        raise ValueError("private_key not available (only at creation time)")

    server_pub = _run_text(["sudo", "/usr/bin/wg", "show", WG_IFACE, "public-key"])
    port = config.get("wireguard.port", 51820)
    dns_list = config.get("wireguard.dns", ["1.1.1.1", "1.0.0.1"])
    dns = ", ".join(dns_list)

    lines = [
        "[Interface]",
        f"PrivateKey = {peer.private_key}",
        f"Address = {peer.allowed_ips}",
        f"DNS = {dns}",
        "",
        "[Peer]",
        f"PublicKey = {server_pub}",
    ]
    if peer.preshared_key:
        lines.append(f"PresharedKey = {peer.preshared_key}")
    lines += [
        f"Endpoint = {server_endpoint}:{port}",
        "AllowedIPs = 0.0.0.0/0, ::/0",
        "PersistentKeepalive = 25",
    ]
    return "\n".join(lines) + "\n"


def server_external_ip() -> str:
    """External IP from GCP metadata server."""
    try:
        req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip",
            headers={"Metadata-Flavor": "Google"},
        )
        return urllib.request.urlopen(req, timeout=2).read().decode().strip()
    except Exception:
        return ""
