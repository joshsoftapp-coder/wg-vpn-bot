"""VM/host operations: status, reboot, shutdown, update, restart."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def uptime_seconds() -> int:
    try:
        return int(float(Path("/proc/uptime").read_text().split()[0]))
    except (OSError, ValueError):
        return 0


def fmt_uptime(s: int) -> str:
    d, r = divmod(s, 86400); h, r = divmod(r, 3600); m, _ = divmod(r, 60)
    if d: return f"{d}d {h}h {m}m"
    if h: return f"{h}h {m}m"
    return f"{m}m"


def load_avg() -> tuple[float, float, float]:
    try:
        v = Path("/proc/loadavg").read_text().split()[:3]
        return tuple(float(x) for x in v)  # type: ignore[return-value]
    except (OSError, ValueError):
        return (0.0, 0.0, 0.0)


def mem_info() -> dict[str, int]:
    info: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            parts = line.split(":")
            if len(parts) == 2:
                val = parts[1].strip().split()[0]
                if val.isdigit():
                    info[parts[0].strip()] = int(val)
    except OSError:
        return {"total_kb": 0, "available_kb": 0, "used_kb": 0}
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", 0)
    return {"total_kb": total, "available_kb": avail, "used_kb": total - avail}


def disk_root() -> dict[str, int]:
    u = shutil.disk_usage("/")
    return {"total_b": u.total, "used_b": u.used, "free_b": u.free,
            "percent": int(u.used * 100 / u.total) if u.total else 0}


def fmt_bytes(n: int | float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def restart_wg() -> tuple[bool, str]:
    try:
        subprocess.check_output(
            ["sudo", "/bin/systemctl", "restart", "wg-quick@wg0"],
            stderr=subprocess.STDOUT, text=True,
        )
        return True, "wg-quick@wg0 restarted"
    except subprocess.CalledProcessError as e:
        return False, f"restart failed: {e.output}"


def tail_journal(target: str, lines: int = 30) -> str:
    unit_map = {"wg": "wg-quick@wg0", "ssh": "ssh", "bot": "wg-admin-bot"}
    unit = unit_map.get(target)
    if not unit:
        return f"refused: '{target}' not allowed (try wg, ssh, bot)"
    try:
        return subprocess.check_output(
            ["sudo", "/usr/bin/journalctl", "-u", unit,
             "-n", str(int(lines)), "--no-pager", "--output=short"],
            stderr=subprocess.STDOUT, text=True,
        )
    except subprocess.CalledProcessError as e:
        return f"error: {e.output}"


def reboot() -> None:
    subprocess.Popen(["sudo", "/sbin/reboot"])


def shutdown() -> None:
    subprocess.Popen(["sudo", "/sbin/shutdown", "-h", "now"])


def apt_dry_run() -> str:
    try:
        subprocess.check_call(["sudo", "/usr/bin/apt-get", "update"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = subprocess.check_output(
            ["sudo", "/usr/bin/apt-get", "-y", "-s", "upgrade"],
            text=True, stderr=subprocess.STDOUT,
        )
        pkgs = [ln.split()[1] for ln in out.splitlines() if ln.startswith("Inst ")]
        if not pkgs:
            return "No upgrades available."
        return f"{len(pkgs)} package(s) would upgrade:\n  " + "\n  ".join(pkgs[:50])
    except subprocess.CalledProcessError as e:
        return f"apt-get failed: {e.output}"


def apt_apply() -> str:
    try:
        subprocess.check_call(["sudo", "/usr/bin/apt-get", "update"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = subprocess.check_output(
            ["sudo", "/usr/bin/apt-get", "-y", "upgrade"],
            text=True, stderr=subprocess.STDOUT,
        )
        pkgs = [ln.split()[1] for ln in out.splitlines() if ln.startswith("Setting up ")]
        return f"Upgrade complete. {len(pkgs)} packages touched."
    except subprocess.CalledProcessError as e:
        return f"apt-get failed:\n{e.output[-1500:]}"
