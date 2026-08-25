"""
state.py
--------
In-memory state container for the platform.

What's new in v2:
  * RunState carries a `kind` ("mlperf" | "vllm_bench" | "pd_bench") and a
    free-form `params` dict that holds tab-specific config (engine, model,
    bench_data, prefill/decode hosts, ...).
  * RunState now ALSO buffers GPU samples per-host while it is active.
    The deque inside HostGpuStream only holds ~5min of samples, which is
    fine for live charts but loses early data for long runs.  The new
    per-run buffer is uncapped (well, capped at a generous number of
    points) so that the run report can render the FULL run window.
  * HostState gets a `metric_summary` slot used for finished runs by the
    report endpoint.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Deque, Dict, List, Optional


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class LogLine:
    ts: float
    host: str         # "" for orchestrator-level lines (no [host] prefix)
    line: str
    level: str = "info"   # info | warn | error | phase


@dataclass
class HostState:
    """State for a single host inside a run."""
    host: str
    status: str = "pending"     # pending | running | success | failed | stopped | error
    phase: str = ""             # validate | prepare | run | collect | done | stop
    exit_code: Optional[int] = None
    started_at: Optional[float] = None
    ended_at: Optional[float] = None
    log_dir: Optional[str] = None
    container_name: Optional[str] = None
    result_summary: Optional[dict] = None      # parsed from *_RESULT_JSON
    result_metrics: Optional[dict] = None      # parsed from result_dir contents
    result_error: Optional[str] = None         # parser error message if any
    metric_summary: Optional[dict] = None      # cached UI-friendly metric snapshot


@dataclass
class RunState:
    run_id: str
    suite: str
    version: str
    gpu_type: str
    benchmark: str
    hosts: List[str]
    created_at: float
    kind: str = "mlperf"          # mlperf | vllm_bench | pd_bench
    params: Dict[str, Any] = field(default_factory=dict)
    node_gpu_map: Dict[str, str] = field(default_factory=dict)
    dry_run: bool = False
    status: str = "pending"
    pid: Optional[int] = None
    cmd: Optional[List[str]] = None
    host_states: Dict[str, HostState] = field(default_factory=dict)
    log_buffer: Deque[LogLine] = field(default_factory=lambda: deque(maxlen=20000))
    log_subscribers: List[asyncio.Queue] = field(default_factory=list)
    finished_at: Optional[float] = None
    # per-run per-host GPU sample buffer.  We keep dicts (asdict(GpuSample))
    # so that the report renderer can serialize them straight to JSON.
    # 7200 ≈ 2 hours @ 1Hz which is plenty for typical benchmarks.
    gpu_samples: Dict[str, Deque[dict]] = field(default_factory=dict)


@dataclass
class GpuSample:
    """One nvidia-smi snapshot for one host (aggregated across GPUs)."""
    ts: float
    util_avg: float
    util_max: float
    power_total_w: float
    power_avg_w: float
    mem_used_gb: float
    mem_total_gb: float
    gpu_count: int
    per_gpu: List[dict] = field(default_factory=list)
    # RDMA NIC bandwidth (per device) sampled on the same host, plus totals.
    # Each entry: {device, tx_gbps, rx_gbps, gpus:[idx...]}
    nics: List[dict] = field(default_factory=list)
    nic_tx_gbps: float = 0.0
    nic_rx_gbps: float = 0.0


@dataclass
class HostGpuStream:
    host: str
    samples: Deque[GpuSample] = field(default_factory=lambda: deque(maxlen=300))
    subscribers: List[asyncio.Queue] = field(default_factory=list)
    last_error: Optional[str] = None
    reachable: bool = True
    monitor_task: Optional[asyncio.Task] = None
    ref_count: int = 0


# ---------------------------------------------------------------------------
# Persistent run history
# ---------------------------------------------------------------------------

TERMINAL_STATUSES = {"success", "failed", "partial", "stopped", "error"}
ACTIVE_STATUSES = {"pending", "running"}
RUN_HISTORY_MAX = int(os.environ.get("POC_PLATFORM_RUN_HISTORY_MAX", "500"))
_PROJECT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_PROJECT_PARENT_DIR = os.path.abspath(os.path.join(_PROJECT_DIR, ".."))
# Keep run history outside the versioned poc-platform-vX.Y directory by default.
# This makes Recent Runs survive zip upgrades such as v6.6 -> v6.8, while still
# allowing an explicit override for shared/locked-down deployments.
STATE_DIR = os.environ.get(
    "POC_PLATFORM_STATE_DIR",
    os.path.join(_PROJECT_PARENT_DIR, ".poc_platform_state"),
)
LEGACY_STATE_DIR = os.path.join(_PROJECT_DIR, ".platform_state")
DASHBOARD_MAX = int(os.environ.get("POC_PLATFORM_DASHBOARD_MAX", "2000"))


def _safe_dashboard_id_part(value: Any) -> str:
    import re
    text = str(value or "").strip()
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("_")
    return text or "unknown"


def _dashboard_pin_semantic_key(item: Dict[str, Any]) -> str:
    rid = str(item.get("run_id") or "").strip()
    if rid:
        dims = item.get("dims") if isinstance(item.get("dims"), dict) else {}
        host = str(item.get("host") or dims.get("host") or item.get("log_host") or "all").strip() or "all"
        return f"run:{rid}::host:{host}"
    pid = str(item.get("id") or "").strip()
    return f"id:{pid}" if pid else ""


def _stable_dashboard_pin_id(item: Dict[str, Any]) -> str:
    rid = str(item.get("run_id") or "").strip()
    if not rid:
        return str(item.get("id") or "").strip()
    dims = item.get("dims") if isinstance(item.get("dims"), dict) else {}
    host = str(item.get("host") or dims.get("host") or item.get("log_host") or "all").strip() or "all"
    return f"pin_{_safe_dashboard_id_part(rid)}_{_safe_dashboard_id_part(host)}"


def _sanitize_dashboard_pin(raw: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(raw, dict):
        return None
    # Keep the schema intentionally loose; the frontend owns field semantics.
    # Use run_id+host as the stable identity so dashboard pins do not multiply
    # when localStorage and backend state are merged across platform upgrades.
    item = dict(raw)
    pid = _stable_dashboard_pin_id(item)
    if not pid:
        return None
    item["id"] = pid
    return item


def _logline_to_dict(line: LogLine) -> Dict[str, Any]:
    return {"ts": line.ts, "host": line.host, "line": line.line, "level": line.level}


def _logline_from_dict(data: Dict[str, Any]) -> LogLine:
    return LogLine(
        ts=float(data.get("ts") or 0),
        host=str(data.get("host") or ""),
        line=str(data.get("line") or ""),
        level=str(data.get("level") or "info"),
    )


def _host_to_dict(host: HostState) -> Dict[str, Any]:
    return {
        "host": host.host,
        "status": host.status,
        "phase": host.phase,
        "exit_code": host.exit_code,
        "started_at": host.started_at,
        "ended_at": host.ended_at,
        "log_dir": host.log_dir,
        "container_name": host.container_name,
        "result_summary": host.result_summary,
        "result_metrics": host.result_metrics,
        "result_error": host.result_error,
        "metric_summary": host.metric_summary,
    }


def _host_from_dict(data: Dict[str, Any]) -> HostState:
    allowed = {
        "host", "status", "phase", "exit_code", "started_at", "ended_at",
        "log_dir", "container_name", "result_summary", "result_metrics",
        "result_error", "metric_summary",
    }
    clean = {k: data.get(k) for k in allowed if k in data}
    return HostState(**clean)


def _run_to_dict(run: RunState) -> Dict[str, Any]:
    return {
        "run_id": run.run_id,
        "suite": run.suite,
        "version": run.version,
        "gpu_type": run.gpu_type,
        "benchmark": run.benchmark,
        "hosts": list(run.hosts or []),
        "created_at": run.created_at,
        "kind": run.kind,
        "params": run.params or {},
        "node_gpu_map": run.node_gpu_map or {},
        "dry_run": run.dry_run,
        "status": run.status,
        "pid": None,
        "cmd": run.cmd,
        "finished_at": run.finished_at,
        "host_states": {h: _host_to_dict(hs) for h, hs in (run.host_states or {}).items()},
        "log_buffer": [_logline_to_dict(ll) for ll in list(run.log_buffer)[-20000:]],
        "gpu_samples": {h: list(samples)[-7200:] for h, samples in (run.gpu_samples or {}).items()},
    }


def _run_from_dict(data: Dict[str, Any]) -> RunState:
    raw_status = str(data.get("status") or "running")
    finished_at = data.get("finished_at")

    # The backend owns the launcher subprocesses.  If the web platform is
    # stopped or upgraded, those subprocesses cannot be safely reattached.
    # Therefore any saved non-terminal run is restored as stopped rather than
    # being displayed as still running.
    if raw_status in TERMINAL_STATUSES:
        status = raw_status
    else:
        status = "stopped"
        finished_at = finished_at or now()

    host_states = {}
    for h, raw in (data.get("host_states") or {}).items():
        hs = _host_from_dict(raw or {"host": h})
        if status in TERMINAL_STATUSES and hs.status not in TERMINAL_STATUSES:
            hs.status = "stopped" if status == "stopped" else status
            hs.ended_at = hs.ended_at or finished_at
        host_states[h] = hs

    hosts = list(data.get("hosts") or host_states.keys())
    for h in hosts:
        host_states.setdefault(h, HostState(host=h, status=status))

    return RunState(
        run_id=str(data.get("run_id") or ""),
        suite=str(data.get("suite") or ""),
        version=str(data.get("version") or ""),
        gpu_type=str(data.get("gpu_type") or ""),
        benchmark=str(data.get("benchmark") or ""),
        hosts=hosts,
        created_at=float(data.get("created_at") or 0),
        kind=str(data.get("kind") or "mlperf"),
        params=dict(data.get("params") or {}),
        node_gpu_map=dict(data.get("node_gpu_map") or {}),
        dry_run=bool(data.get("dry_run") or False),
        status=status,
        pid=None,
        cmd=data.get("cmd"),
        host_states=host_states,
        log_buffer=deque([_logline_from_dict(x) for x in data.get("log_buffer") or []], maxlen=20000),
        log_subscribers=[],
        finished_at=finished_at,
        gpu_samples={h: deque(list(v or [])[-7200:], maxlen=7200) for h, v in (data.get("gpu_samples") or {}).items()},
    )


# ---------------------------------------------------------------------------
# Container
# ---------------------------------------------------------------------------


class PlatformState:
    """Singleton-style in-memory state."""

    def __init__(self) -> None:
        self.runs: Dict[str, RunState] = {}
        self.gpu_streams: Dict[str, HostGpuStream] = {}
        self._lock = asyncio.Lock()
        self.storage_dir = STATE_DIR
        self.runs_file = os.path.join(self.storage_dir, "runs.json")
        self.dashboard_file = os.path.join(self.storage_dir, "dashboard.json")
        self.load_runs()

    def _candidate_run_files(self) -> List[str]:
        candidates: List[str] = []
        primary = self.runs_file
        candidates.append(primary)
        candidates.append(os.path.join(LEGACY_STATE_DIR, "runs.json"))
        try:
            parent = _PROJECT_PARENT_DIR
            for name in sorted(os.listdir(parent), reverse=True):
                path = os.path.join(parent, name, ".platform_state", "runs.json")
                if name.startswith("poc-platform-v") and path not in candidates:
                    candidates.append(path)
        except Exception:
            pass
        # Preserve order while removing duplicates.
        seen = set()
        out = []
        for path in candidates:
            if path and path not in seen:
                seen.add(path)
                out.append(path)
        return out

    def load_runs(self) -> None:
        self.runs = {}
        loaded_any = False
        for path in self._candidate_run_files():
            try:
                if not os.path.isfile(path):
                    continue
                with open(path, "r", encoding="utf-8") as f:
                    payload = json.load(f)
                loaded = payload.get("runs") if isinstance(payload, dict) else payload
                for raw in loaded or []:
                    run = _run_from_dict(raw or {})
                    if run.run_id:
                        current = self.runs.get(run.run_id)
                        if current is None or (run.created_at or 0) >= (current.created_at or 0):
                            self.runs[run.run_id] = run
                loaded_any = True
            except Exception:
                # Do not block platform start because one history file is corrupt.
                continue
        if loaded_any:
            self.persist_runs()

    def persist_runs(self) -> None:
        try:
            os.makedirs(self.storage_dir, exist_ok=True)
            runs = sorted(self.runs.values(), key=lambda r: r.created_at)[-RUN_HISTORY_MAX:]
            payload = {
                "schema": 1,
                "saved_at": time.time(),
                "runs": [_run_to_dict(r) for r in runs],
            }
            tmp = f"{self.runs_file}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, self.runs_file)
        except Exception:
            pass

    # --- dashboard pins ---

    def _candidate_dashboard_files(self) -> List[str]:
        candidates: List[str] = [self.dashboard_file, os.path.join(LEGACY_STATE_DIR, "dashboard.json")]
        try:
            parent = _PROJECT_PARENT_DIR
            for name in sorted(os.listdir(parent), reverse=True):
                path = os.path.join(parent, name, ".platform_state", "dashboard.json")
                if name.startswith("poc-platform-v") and path not in candidates:
                    candidates.append(path)
        except Exception:
            pass
        seen = set()
        out = []
        for path in candidates:
            if path and path not in seen:
                seen.add(path)
                out.append(path)
        return out

    def load_dashboard(self) -> List[Dict[str, Any]]:
        merged: Dict[str, Dict[str, Any]] = {}
        for path in self._candidate_dashboard_files():
            try:
                if not os.path.isfile(path):
                    continue
                with open(path, "r", encoding="utf-8") as f:
                    payload = json.load(f)
                raw_items = payload.get("pins") if isinstance(payload, dict) else payload
                for raw in raw_items or []:
                    item = _sanitize_dashboard_pin(raw)
                    if not item:
                        continue
                    key = _dashboard_pin_semantic_key(item)
                    if not key:
                        continue
                    merged[key] = {**merged.get(key, {}), **item}
            except Exception:
                continue
        items = list(merged.values())[-DASHBOARD_MAX:]
        if items:
            self.persist_dashboard(items)
        return items

    def persist_dashboard(self, pins: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        clean_by_key: Dict[str, Dict[str, Any]] = {}
        for raw in pins or []:
            item = _sanitize_dashboard_pin(raw)
            if not item:
                continue
            key = _dashboard_pin_semantic_key(item)
            if not key:
                continue
            clean_by_key[key] = {**clean_by_key.get(key, {}), **item}
        clean: List[Dict[str, Any]] = list(clean_by_key.values())
        clean = clean[-DASHBOARD_MAX:]
        try:
            os.makedirs(self.storage_dir, exist_ok=True)
            payload = {"schema": 1, "saved_at": time.time(), "pins": clean}
            tmp = f"{self.dashboard_file}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, self.dashboard_file)
        except Exception:
            pass
        return clean

    # --- generic JSON documents ---
    # Whole-document stores (accelerator_perf, gpu_tco_table). Unlike dashboard
    # pins these have no per-item identity to merge on, so the newest readable
    # file wins and older deployment folders are only a fallback.

    def _document_file(self, name: str) -> str:
        return os.path.join(self.storage_dir, f"{name}.json")

    def _candidate_document_files(self, name: str) -> List[str]:
        candidates: List[str] = [
            self._document_file(name),
            os.path.join(LEGACY_STATE_DIR, f"{name}.json"),
        ]
        try:
            parent = _PROJECT_PARENT_DIR
            for entry in sorted(os.listdir(parent), reverse=True):
                path = os.path.join(parent, entry, ".platform_state", f"{name}.json")
                if entry.startswith("poc-platform-v") and path not in candidates:
                    candidates.append(path)
        except Exception:
            pass
        return candidates

    def load_document(self, name: str, default: Any = None) -> Any:
        for path in self._candidate_document_files(name):
            try:
                if not os.path.isfile(path):
                    continue
                with open(path, "r", encoding="utf-8") as f:
                    payload = json.load(f)
            except Exception:
                continue
            # Files written by persist_document are wrapped; a hand-placed file
            # may be the bare document.
            if isinstance(payload, dict) and "document" in payload:
                return payload["document"]
            return payload
        return default

    def persist_document(self, name: str, document: Any) -> Any:
        path = self._document_file(name)
        try:
            os.makedirs(self.storage_dir, exist_ok=True)
            payload = {"schema": 1, "saved_at": time.time(), "document": document}
            tmp = f"{path}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, path)
        except Exception:
            pass
        return document

    # --- runs ---

    def add_run(self, run: RunState) -> None:
        self.runs[run.run_id] = run
        for h in run.hosts:
            run.host_states.setdefault(h, HostState(host=h))
            run.gpu_samples.setdefault(h, deque(maxlen=7200))
        self.persist_runs()

    def get_run(self, run_id: str) -> Optional[RunState]:
        return self.runs.get(run_id)

    def delete_run(self, run_id: str) -> bool:
        run = self.runs.pop(run_id, None)
        if run is None:
            return False
        for q in list(getattr(run, "log_subscribers", []) or []):
            try:
                q.put_nowait(LogLine(ts=time.time(), host="", line="[platform] run deleted"))
            except Exception:
                pass
        self.persist_runs()
        return True

    def list_runs(self) -> List[RunState]:
        return list(self.runs.values())

    def list_active_runs_for_host(self, host: str) -> List[RunState]:
        """Active = not yet finalized AND host is part of run."""
        out: List[RunState] = []
        for r in self.runs.values():
            if r.finished_at is not None:
                continue
            if host in r.hosts:
                out.append(r)
        return out

    # --- log fan-out ---

    def push_log(self, run: RunState, line: LogLine) -> None:
        run.log_buffer.append(line)
        dead: List[asyncio.Queue] = []
        for q in run.log_subscribers:
            try:
                q.put_nowait(line)
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            try:
                run.log_subscribers.remove(q)
            except ValueError:
                pass

    def subscribe_logs(self, run: RunState) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=2000)
        run.log_subscribers.append(q)
        return q

    def unsubscribe_logs(self, run: RunState, q: asyncio.Queue) -> None:
        try:
            run.log_subscribers.remove(q)
        except ValueError:
            pass

    # --- gpu streams ---

    def get_or_create_gpu_stream(self, host: str) -> HostGpuStream:
        s = self.gpu_streams.get(host)
        if s is None:
            s = HostGpuStream(host=host)
            self.gpu_streams[host] = s
        return s

    def push_gpu_sample(self, host: str, sample: GpuSample) -> None:
        s = self.get_or_create_gpu_stream(host)
        s.samples.append(sample)
        # Also append to every active run that uses this host.  This is what
        # lets the report endpoint render the FULL run window even after the
        # 300-sample live deque has rotated.
        from dataclasses import asdict as _asdict
        sample_dict = _asdict(sample)
        for r in self.list_active_runs_for_host(host):
            buf = r.gpu_samples.setdefault(host, deque(maxlen=7200))
            buf.append(sample_dict)
        # fan-out to live subscribers
        dead: List[asyncio.Queue] = []
        for q in s.subscribers:
            try:
                q.put_nowait(sample)
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            try:
                s.subscribers.remove(q)
            except ValueError:
                pass

    def subscribe_gpu(self, host: str) -> asyncio.Queue:
        s = self.get_or_create_gpu_stream(host)
        q: asyncio.Queue = asyncio.Queue(maxsize=300)
        s.subscribers.append(q)
        return q

    def unsubscribe_gpu(self, host: str, q: asyncio.Queue) -> None:
        s = self.gpu_streams.get(host)
        if s is None:
            return
        try:
            s.subscribers.remove(q)
        except ValueError:
            pass


# Single global instance.
STATE = PlatformState()


def now() -> float:
    return time.time()
