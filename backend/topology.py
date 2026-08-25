"""
topology.py
-----------
Parse `nvidia-smi topo -m` and derive the GPU -> closest-NIC binding so pods
are placed/configured to use the RDMA NIC physically nearest the GPUs they run
on (mandatory per the deployment policy: e.g. GPU0/GPU1 -> NIC0/mlx5_0).

Affinity strength (best -> worst):  PIX < PXB < PHB < NODE < SYS
We pick, for each GPU, the NIC with the strongest connection.  Ties keep the
lowest NIC index.

Output of build_binding():
  {
    "gpus": { 0: {"nic":"NIC0","device":"mlx5_0","affinity":"PIX"}, ... },
    "nic_devices": {"NIC0":"mlx5_0", ...},
    "nic_to_gpus": {"mlx5_0":[0,1], "mlx5_1":[2,3], ...},
    "raw": "<original matrix text>",
  }

This module only parses text; callers fetch the text from a node (SSH /
kubectl exec) and may cache it.
"""

from __future__ import annotations

import asyncio
import os
import re
import socket
from typing import Dict, List, Optional, Tuple

# best (lowest) wins
_AFFINITY_RANK = {"PIX": 0, "PXB": 1, "PHB": 2, "NODE": 3, "SYS": 4, "X": 99}


def _affinity_rank(token: str) -> int:
    return _AFFINITY_RANK.get(token.strip().upper(), 50)


def parse_topo_matrix(text: str) -> Dict:
    """Parse `nvidia-smi topo -m` output into a GPU<->NIC binding."""
    lines = text.splitlines()

    # 1) header row: find the columns (GPU0 GPU1 ... NIC0 NIC1 ...)
    header_cols: List[str] = []
    header_idx = -1
    for i, ln in enumerate(lines):
        toks = ln.split()
        if toks and any(re.fullmatch(r"GPU\d+", t) for t in toks):
            header_cols = [t for t in toks if re.fullmatch(r"(GPU|NIC)\d+", t)]
            header_idx = i
            break
    if not header_cols:
        return {"gpus": {}, "nic_devices": {}, "nic_to_gpus": {}, "raw": text, "error": "no header row"}

    nic_cols = [c for c in header_cols if c.startswith("NIC")]

    # 2) NIC legend: "NIC0: mlx5_0"
    nic_devices: Dict[str, str] = {}
    for ln in lines:
        m = re.match(r"\s*(NIC\d+):\s*(\S+)", ln)
        if m:
            nic_devices[m.group(1)] = m.group(2)

    # 3) GPU rows: "GPU0  X  NV18 ... PIX SYS SYS ..."
    gpus: Dict[int, Dict] = {}
    for ln in lines[header_idx + 1:]:
        toks = ln.split()
        if not toks or not re.fullmatch(r"GPU\d+", toks[0]):
            continue
        gpu_idx = int(toks[0][3:])
        # cells align to header_cols; the row's cells are toks[1:1+len(header_cols)]
        cells = toks[1: 1 + len(header_cols)]
        if len(cells) < len(header_cols):
            continue
        # map each header column to its cell
        cell_by_col = dict(zip(header_cols, cells))
        best_nic: Optional[str] = None
        best_rank = 999
        for nic in nic_cols:
            rank = _affinity_rank(cell_by_col.get(nic, "SYS"))
            if rank < best_rank:
                best_rank = rank
                best_nic = nic
        if best_nic is not None:
            inv = {v: k for k, v in _AFFINITY_RANK.items()}
            gpus[gpu_idx] = {
                "nic": best_nic,
                "device": nic_devices.get(best_nic, best_nic),
                "affinity": inv.get(best_rank, "SYS"),
            }

    nic_to_gpus: Dict[str, List[int]] = {}
    for g, info in sorted(gpus.items()):
        dev = info["device"]
        nic_to_gpus.setdefault(dev, []).append(g)

    return {
        "gpus": gpus,
        "nic_devices": nic_devices,
        "nic_to_gpus": nic_to_gpus,
        "raw": text,
    }


def devices_for_gpus(binding: Dict, gpu_indices: List[int]) -> List[str]:
    """Ordered, de-duplicated list of NIC devices for the given GPU indices."""
    gpus = binding.get("gpus", {})
    out: List[str] = []
    for g in gpu_indices:
        info = gpus.get(g) or gpus.get(int(g)) if g is not None else None
        if info and info["device"] not in out:
            out.append(info["device"])
    return out


def binding_env(devices: List[str]) -> Dict[str, str]:
    """RDMA env vars to pin NCCL/UCX/NIXL to the chosen NIC device(s)."""
    if not devices:
        return {}
    csv = ",".join(devices)
    # UCX wants <dev>:<port>; default IB port 1
    ucx = ",".join(f"{d}:1" for d in devices)
    return {
        "NCCL_IB_HCA": csv,
        "UCX_NET_DEVICES": ucx,
        "NVSHMEM_HCA_LIST": csv,
        "NCCL_IB_DISABLE": "0",
    }


# ---------------------------------------------------------------------------
# fetching `nvidia-smi topo -m` from a node
# ---------------------------------------------------------------------------

_LOCAL: Optional[set] = None


def _local_names() -> set:
    global _LOCAL
    if _LOCAL is None:
        names = {"localhost", "127.0.0.1", "::1"}
        try:
            names.add(socket.gethostname())
            names.add(socket.gethostname().split(".")[0])
            names.add(socket.getfqdn())
        except Exception:  # noqa: BLE001
            pass
        _LOCAL = {n for n in names if n}
    return _LOCAL


def _topo_cmd(host: str) -> List[str]:
    smi = ["nvidia-smi", "topo", "-m"]
    if host in _local_names():
        return smi
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new", host, " ".join(smi)]


_CACHE: Dict[str, Dict] = {}


async def fetch_binding(host: str, *, use_cache: bool = True) -> Dict:
    """Run `nvidia-smi topo -m` on host (or via kubectl exec fallback) and parse."""
    if use_cache and host in _CACHE:
        return _CACHE[host]

    cmd = _topo_cmd(host)
    text = ""
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=15)
        if proc.returncode == 0:
            text = out.decode("utf-8", errors="replace")
        else:
            return {"error": (err.decode("utf-8", errors="replace") or "nvidia-smi topo failed")[:300],
                    "host": host, "gpus": {}, "nic_to_gpus": {}}
    except FileNotFoundError:
        return {"error": "nvidia-smi/ssh not found", "host": host, "gpus": {}, "nic_to_gpus": {}}
    except asyncio.TimeoutError:
        return {"error": "nvidia-smi topo timed out", "host": host, "gpus": {}, "nic_to_gpus": {}}

    binding = parse_topo_matrix(text)
    binding["host"] = host
    _CACHE[host] = binding
    return binding


# ---------------------------------------------------------------------------
# free-GPU selection (auto pick N free GPUs on a host)
# ---------------------------------------------------------------------------

def _gpu_state_cmd(host: str) -> List[str]:
    # index, memory.used (MiB), utilization.gpu, processes count
    q = "nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader,nounits"
    if host in _local_names():
        return ["bash", "-lc", q]
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=accept-new", host, q]


async def find_free_gpus(host: str, count: int = 4,
                         max_mem_used_mib: int = 200,
                         max_util_pct: int = 5) -> Dict:
    """Pick ``count`` 'free' GPUs on a host (low memory used + low util).

    Returns:
      {
        "gpus": [0,1,2,3],
        "nics": ["mlx5_0", "mlx5_1"],   # derived from topology binding
        "binding": {0:"mlx5_0", 1:"mlx5_0", 2:"mlx5_1", 3:"mlx5_1"},
        "all": [{index, mem_mib, util, free:bool}, ...]
      }
    """
    cmd = _gpu_state_cmd(host)
    rows: List[Dict] = []
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"})
        out, err = await asyncio.wait_for(proc.communicate(), timeout=12)
        if proc.returncode != 0:
            return {"error": (err.decode("utf-8", errors="replace") or "nvidia-smi failed")[:300],
                    "host": host, "gpus": [], "nics": []}
        for ln in out.decode("utf-8", errors="replace").splitlines():
            parts = [s.strip() for s in ln.split(",")]
            if len(parts) < 3:
                continue
            try:
                idx = int(parts[0]); mem = int(float(parts[1])); util = int(float(parts[2]))
            except ValueError:
                continue
            rows.append({"index": idx, "mem_mib": mem, "util": util,
                         "free": mem <= max_mem_used_mib and util <= max_util_pct})
    except (FileNotFoundError, asyncio.TimeoutError) as e:
        return {"error": str(e), "host": host, "gpus": [], "nics": []}

    free_idx = sorted([r["index"] for r in rows if r["free"]])
    picked = free_idx[:count]
    binding = await fetch_binding(host)
    gpu_map = binding.get("gpus", {})
    per_gpu = {g: gpu_map.get(g, {}).get("device") for g in picked}
    nics: List[str] = []
    for g in picked:
        d = per_gpu.get(g)
        if d and d not in nics:
            nics.append(d)
    return {
        "host": host,
        "gpus": picked,
        "nics": nics,
        "binding": per_gpu,
        "requested": count,
        "all": rows,
    }
