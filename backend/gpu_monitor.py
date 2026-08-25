"""
gpu_monitor.py
--------------
Per-host GPU sampling via nvidia-smi.

Strategy:
- One asyncio task per host (started lazily on first subscribe / on run start)
- Each task runs `[ssh host] nvidia-smi --query-gpu=... --format=csv,noheader,nounits`
  every POLL_INTERVAL seconds
- For local hosts (LOCAL_SHORT/LOCAL_FQDN/127.0.0.1/localhost) skip ssh
- Aggregate per-GPU into one host-level sample (mean util, total power, average power)
- Push into HostGpuStream ring buffer + fan out to subscribers

No external deps. Uses asyncio.create_subprocess_exec.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import socket
from typing import List, Optional

from .state import STATE, GpuSample, HostGpuStream, now

log = logging.getLogger("gpu_monitor")

POLL_INTERVAL = 1.0           # seconds
SSH_TIMEOUT = 6               # seconds; if exceeded we skip a sample
MAX_CONSECUTIVE_FAILURES = 30 # ~30s of failures before we mark unreachable

NVIDIA_QUERY = (
    "index,name,utilization.gpu,power.draw,memory.used,memory.total"
)

_LOCAL_NAMES: Optional[set] = None


def _local_names() -> set:
    global _LOCAL_NAMES
    if _LOCAL_NAMES is not None:
        return _LOCAL_NAMES
    names = {"localhost", "127.0.0.1", "::1"}
    try:
        names.add(socket.gethostname())
        names.add(socket.gethostname().split(".")[0])
        names.add(socket.getfqdn())
    except Exception:  # noqa: BLE001
        pass
    _LOCAL_NAMES = {n for n in names if n}
    return _LOCAL_NAMES


def _is_local(host: str) -> bool:
    return host in _local_names()




# ---------------------------------------------------------------------------
# GPU type detection
# ---------------------------------------------------------------------------

def canonical_gpu_type(raw_name: str) -> str:
    """Map vendor product strings to the platform GPU type labels."""
    name = (raw_name or "").strip()
    upper = re.sub(r"\s+", " ", name.upper())
    if not upper:
        return "UNKNOWN"

    if "GH200" in upper or "GRACE HOPPER" in upper:
        return "GH200"
    if "A100" in upper:
        return "A100"
    if "H100" in upper or "H200" in upper:
        return "H100"
    if "B300" in upper or "GB300" in upper:
        return "B300"
    if "B200" in upper or "GB200" in upper:
        return "B300"
    if "RTX PRO 6000" in upper or "RTX PRO" in upper:
        return "RTX_PRO_6000"
    if "RTX 6000" in upper:
        return "RTX6000"
    if "V100" in upper:
        return "V100"

    # AMD ROCm families. They may not be supported by every benchmark path,
    # but detecting them explicitly gives honest validation failures.
    if "MI300X" in upper:
        return "MI300X"
    if "MI325X" in upper:
        return "MI325X"
    if "MI350" in upper or "MI355" in upper:
        return "MI350"
    if "AMD" in upper or "RADEON" in upper or "INSTINCT" in upper:
        m = re.search(r"MI\d+[A-Z]*", upper)
        return m.group(0) if m else "AMD"

    return name


def _detect_gpu_type_cmd(host: str) -> List[str]:
    # Keep this shell-only so it works over bare SSH without requiring Python
    # helpers on worker nodes. Some nvidia-smi versions reject --query-gpu
    # unless --format is present, so the preferred command always includes it.
    # If the structured query still fails, fall back to `nvidia-smi -L`, which
    # is broadly available across A100/H100/GH200/RTX PRO/Blackwell systems.
    script = r"""
set -o pipefail
if command -v nvidia-smi >/dev/null 2>&1; then
  found=0

  # Preferred path. `--format=csv,noheader` is mandatory on drivers that print
  # '"--format=" switch is missing.' when only --query-gpu is used.
  if nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
    | awk 'NF{print "NVIDIA|" $0; found=1} END{exit found?0:1}'; then
    found=1
  fi

  # Fallback path for drivers where the query interface is unavailable or
  # partially incompatible. Example:
  #   GPU 0: NVIDIA A100-SXM4-80GB (UUID: ...).
  if [ "$found" -eq 0 ]; then
    if nvidia-smi -L 2>/dev/null \
      | sed -E 's/^GPU [0-9]+:[[:space:]]*//; s/[[:space:]]*\(UUID:.*$//' \
      | awk 'NF{print "NVIDIA|" $0; found=1} END{exit found?0:1}'; then
      found=1
    fi
  fi

  # Last-resort text fallback for unusual nvidia-smi variants.
  if [ "$found" -eq 0 ]; then
    nvidia-smi 2>/dev/null \
      | awk '/NVIDIA (A100|H100|H200|GH200|B200|B300|GB200|GB300|RTX)/ { line=$0; sub(/^.*NVIDIA /, "NVIDIA ", line); sub(/[[:space:]]{2,}.*$/, "", line); if (length(line)) print "NVIDIA|" line }' \
      | sort -u
  fi
  exit 0
fi
if command -v rocm-smi >/dev/null 2>&1; then
  rocm-smi --showproductname 2>/dev/null | awk '/Card series/ { sub(/^.*Card series:[[:space:]]*/, ""); if (length($0)) print "AMD|" $0 } /GPU\[[0-9]+\]/ && /:/ { sub(/^.*:[[:space:]]*/, ""); if (length($0)) print "AMD|" $0 }'
  exit 0
fi
exit 127
""".strip()
    if _is_local(host):
        return ["bash", "-lc", script]
    return [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
        "-o", "StrictHostKeyChecking=accept-new", host, script,
    ]


async def detect_gpu_type(host: str) -> dict:
    """Best-effort accelerator type detection for one host.

    Returns {host, gpu_type, raw_names, source, error}. If one host has mixed
    product families, gpu_type is MIXED and raw_names preserves all values.
    """
    cmd = _detect_gpu_type_cmd(host)
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=12)
    except FileNotFoundError:
        return {"host": host, "gpu_type": "UNKNOWN", "raw_names": [], "source": "", "error": f"command not found: {cmd[0]}"}
    except asyncio.TimeoutError:
        return {"host": host, "gpu_type": "UNKNOWN", "raw_names": [], "source": "", "error": "gpu type detection timed out"}

    text = out.decode("utf-8", errors="replace")
    if proc.returncode != 0 and not text.strip():
        return {
            "host": host,
            "gpu_type": "UNKNOWN",
            "raw_names": [],
            "source": "",
            "error": (err.decode("utf-8", errors="replace") or f"gpu type detection exit {proc.returncode}")[:300],
        }

    raw_names = []
    sources = []
    for line in text.splitlines():
        line = line.strip()
        if not line or "|" not in line:
            continue
        src, raw = line.split("|", 1)
        raw = raw.strip()
        if raw:
            raw_names.append(raw)
            sources.append(src.strip())

    canonical = [canonical_gpu_type(x) for x in raw_names]
    known = [x for x in canonical if x and x != "UNKNOWN"]
    unique = sorted(set(known))
    if not unique:
        gpu_type = "UNKNOWN"
    elif len(unique) == 1:
        gpu_type = unique[0]
    else:
        gpu_type = "MIXED"
    return {
        "host": host,
        "gpu_type": gpu_type,
        "raw_names": raw_names,
        "source": sorted(set(sources))[0] if sources else "",
        "error": "" if known else "no GPU product name detected",
    }


def _build_cmd(host: str) -> List[str]:
    smi = (
        "nvidia-smi "
        f"--query-gpu={NVIDIA_QUERY} "
        "--format=csv,noheader,nounits"
    )
    # Also read RDMA port counters (units of 4 bytes per IB spec) so we can
    # derive per-NIC bandwidth.  Output after a marker so we can split.
    nic = (
        "echo '###NIC###'; "
        "for p in /sys/class/infiniband/*/ports/*; do "
        "dev=$(echo \"$p\" | sed -E 's#/sys/class/infiniband/##; s#/ports/.*##'); "
        "tx=$(cat \"$p/counters/port_xmit_data\" 2>/dev/null); "
        "rx=$(cat \"$p/counters/port_rcv_data\" 2>/dev/null); "
        "[ -n \"$tx\" ] && echo \"$dev $tx $rx\"; done 2>/dev/null || true"
    )
    combined = f"{smi}; {nic}"
    if _is_local(host):
        return ["bash", "-c", combined]
    return [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "StrictHostKeyChecking=accept-new",
        host,
        combined,
    ]


def _to_float(value: str) -> float:
    value = value.strip()
    if value in ("[N/A]", "N/A", ""):
        return 0.0
    # Be tolerant if a driver ignores nounits and returns values like "67.12 W".
    m = value.split()[0]
    try:
        return float(m)
    except ValueError:
        return 0.0


def _parse_smi_output(text: str) -> List[dict]:
    """Parse nvidia-smi CSV output into list of dicts (one per GPU)."""
    rows: List[dict] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 6:
            continue
        try:
            rows.append({
                "index": int(parts[0]),
                "name": parts[1],
                "util": _to_float(parts[2]),
                "power_w": _to_float(parts[3]),
                "mem_used_gb": _to_float(parts[4]) / 1024.0,
                "mem_total_gb": _to_float(parts[5]) / 1024.0,
            })
        except ValueError:
            continue
    return rows


def _parse_nic_counters(text: str) -> dict:
    """Parse '<dev> <tx> <rx>' lines into {dev: (tx_bytes, rx_bytes)}.

    IB port_xmit_data/port_rcv_data are in units of 4 bytes (per lane-octet
    convention), so multiply by 4 to get bytes.
    """
    out: dict = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        dev = parts[0]
        try:
            tx = int(parts[1]) * 4
            rx = int(parts[2]) * 4
        except ValueError:
            continue
        out[dev] = (tx, rx)
    return out


def _split_sections(text: str) -> tuple:
    """Split combined nvidia-smi + NIC output on the ###NIC### marker."""
    if "###NIC###" in text:
        gpu_part, nic_part = text.split("###NIC###", 1)
    else:
        gpu_part, nic_part = text, ""
    return gpu_part, nic_part


def _aggregate(per_gpu: List[dict]) -> GpuSample:
    if not per_gpu:
        return GpuSample(
            ts=now(), util_avg=0, util_max=0,
            power_total_w=0, power_avg_w=0,
            mem_used_gb=0, mem_total_gb=0,
            gpu_count=0, per_gpu=[],
        )
    n = len(per_gpu)
    utils = [g["util"] for g in per_gpu]
    powers = [g["power_w"] for g in per_gpu]
    mu = sum(g["mem_used_gb"] for g in per_gpu)
    mt = sum(g["mem_total_gb"] for g in per_gpu)
    return GpuSample(
        ts=now(),
        util_avg=sum(utils) / n,
        util_max=max(utils),
        power_total_w=sum(powers),
        power_avg_w=sum(powers) / n,
        mem_used_gb=mu,
        mem_total_gb=mt,
        gpu_count=n,
        per_gpu=per_gpu,
    )


async def _run_once(host: str) -> tuple:
    cmd = _build_cmd(host)
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
        )
    except FileNotFoundError as e:
        raise RuntimeError(f"command not found: {cmd[0]}") from e

    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=SSH_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        try:
            await proc.wait()
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError("nvidia-smi timed out")

    if proc.returncode != 0:
        err = stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"nvidia-smi exit {proc.returncode}: {err[:200]}")

    text = stdout.decode("utf-8", errors="replace")
    gpu_part, nic_part = _split_sections(text)
    return _parse_smi_output(gpu_part), _parse_nic_counters(nic_part)


async def _monitor_loop(host: str) -> None:
    stream = STATE.get_or_create_gpu_stream(host)
    consecutive_failures = 0
    log.info("gpu monitor started: host=%s", host)

    prev_nic: dict = {}        # dev -> (tx_bytes, rx_bytes)
    prev_ts: Optional[float] = None
    # GPU->NIC binding for this host (best-effort; empty if topo unavailable)
    binding = {}
    try:
        from . import topology
        binding = (await topology.fetch_binding(host)).get("nic_to_gpus", {})
    except Exception:  # noqa: BLE001
        binding = {}

    def _nic_samples(counters: dict, dt: float) -> tuple:
        nics = []
        tx_tot = rx_tot = 0.0
        for dev, (tx, rx) in sorted(counters.items()):
            ptx, prx = prev_nic.get(dev, (tx, rx))
            # bytes/s -> Gbit/s ; guard against counter resets (negative delta)
            d_tx = max(0.0, (tx - ptx)) / dt if dt > 0 else 0.0
            d_rx = max(0.0, (rx - prx)) / dt if dt > 0 else 0.0
            tx_gbps = d_tx * 8 / 1e9
            rx_gbps = d_rx * 8 / 1e9
            tx_tot += tx_gbps
            rx_tot += rx_gbps
            nics.append({
                "device": dev,
                "tx_gbps": round(tx_gbps, 3),
                "rx_gbps": round(rx_gbps, 3),
                "gpus": binding.get(dev, []),
            })
        return nics, round(tx_tot, 3), round(rx_tot, 3)

    try:
        while stream.ref_count > 0 or stream.subscribers:
            try:
                rows, nic_counters = await _run_once(host)
                stream.last_error = None
                stream.reachable = True
                consecutive_failures = 0
                sample = _aggregate(rows or [])
                now_ts = sample.ts
                dt = (now_ts - prev_ts) if prev_ts else POLL_INTERVAL
                if nic_counters:
                    nics, tx_tot, rx_tot = _nic_samples(nic_counters, dt)
                    sample.nics = nics
                    sample.nic_tx_gbps = tx_tot
                    sample.nic_rx_gbps = rx_tot
                    prev_nic = nic_counters
                    prev_ts = now_ts
                STATE.push_gpu_sample(host, sample)
            except Exception as e:  # noqa: BLE001
                consecutive_failures += 1
                stream.last_error = str(e)
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    stream.reachable = False
                STATE.push_gpu_sample(host, GpuSample(
                    ts=now(), util_avg=0, util_max=0,
                    power_total_w=0, power_avg_w=0,
                    mem_used_gb=0, mem_total_gb=0,
                    gpu_count=0, per_gpu=[],
                ))

            await asyncio.sleep(POLL_INTERVAL)
    except asyncio.CancelledError:
        log.info("gpu monitor cancelled: host=%s", host)
        raise
    finally:
        stream.monitor_task = None
        log.info("gpu monitor stopped: host=%s", host)


def ensure_monitor(host: str) -> HostGpuStream:
    """Create monitor task if not already running; return the stream."""
    stream = STATE.get_or_create_gpu_stream(host)
    if stream.monitor_task is None or stream.monitor_task.done():
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return stream
        stream.monitor_task = loop.create_task(_monitor_loop(host))
    return stream


def acquire_host(host: str) -> None:
    """Increment ref count (used when a run starts)."""
    s = STATE.get_or_create_gpu_stream(host)
    s.ref_count += 1
    ensure_monitor(host)


def release_host(host: str) -> None:
    """Decrement ref count (used when a run ends)."""
    s = STATE.gpu_streams.get(host)
    if s is None:
        return
    if s.ref_count > 0:
        s.ref_count -= 1
    # let the loop notice ref_count==0 and terminate naturally if no subscribers
