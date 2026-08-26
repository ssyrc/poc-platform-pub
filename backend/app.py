"""
app.py
------
FastAPI application exposing the GPU benchmark platform.

Endpoints:
  Static
    GET  /                                    -> frontend index.html
    GET  /vendor/*                            -> air-gapped JS deps

  Runs
    POST /api/runs                            start a run (any kind)
    GET  /api/runs                            list runs
    GET  /api/runs/{run_id}                   snapshot
    POST /api/runs/{run_id}/stop              stop entire run
    POST /api/runs/{run_id}/stop/{host}       stop one host
    GET  /api/runs/{run_id}/logs              historical
    GET  /api/runs/{run_id}/logs/stream       SSE
    GET  /api/runs/{run_id}/results           parsed results
    GET  /api/runs/{run_id}/report            *NEW* downloadable HTML report
    GET  /api/runs/{run_id}/gpu_samples       *NEW* per-host GPU samples buffered for this run

  Hosts / GPU
    GET  /api/hosts/{host}/gpu                recent samples
    GET  /api/hosts/{host}/gpu/stream         SSE

  Meta
    GET  /api/config
    GET  /api/health
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from dataclasses import asdict
from html import escape as _esc
from typing import Any, Dict, List, Optional

from fastapi import Response, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from sse_starlette.sse import EventSourceResponse

from . import cluster, gpu_monitor, runner
from .parser import parse_log_buffer_lines, parse_result_dir
from .runner import RunRequest
from .seed import DEFAULT_ACCELERATOR_PERF, DEFAULT_GPU_TCO_TABLE
from .state import LogLine, STATE


logging.basicConfig(
    level=os.environ.get("MLPERF_LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("app")
BACKEND_STARTED_AT = time.time()


# ---------------------------------------------------------------------------
# Validation matrices per kind
# ---------------------------------------------------------------------------

ALL_GPUS = ["V100", "A100", "H100", "GH200", "B300", "RTX6000", "RTX_PRO_6000"]

SUPPORTED_MLPERF = {
    # Keep UI/API validation aligned with the bash scripts so invalid GPU
    # selections fail before launching remote jobs.
    ("training", "v4.1"): {"benchmarks": ["llama2_70b_lora"], "gpus": ["V100", "A100", "H100", "GH200", "B300"]},
    ("training", "v5.1"): {"benchmarks": ["llama2_70b_lora", "llama31_8b"], "gpus": ["V100", "A100", "H100", "RTX6000", "RTX_PRO_6000", "GH200", "B300"]},
    ("inference", "v5.1"): {"benchmarks": ["llama2_70b"], "gpus": ALL_GPUS},
    ("inference", "v6.0"): {"benchmarks": ["llama2_70b"], "gpus": ALL_GPUS},
}

SUPPORTED_VLLM = {
    "engines": ["vllm", "sglang"],
    "bench_data": {
        "vllm": ["sharegpt", "random"],
        "sglang": [],   # TBD
    },
    "gpus": ALL_GPUS,
}

SUPPORTED_PD = {
    "engines": ["vllm", "sglang"],
    "bench_data": {
        "vllm": ["sharegpt", "random"],
        "sglang": [],
    },
    "gpus": ALL_GPUS,
}

# llm-d serving / disaggregated inference on Kubernetes.
# Versions mirror the org's benchmark version tags; each maps to a different
# llm-d / vLLM image + tuning profile inside scripts/llmd/llmd_serve.sh.
SUPPORTED_LLMD = {
    "engines": ["llm-d"],
    "modes": ["serve", "pd"],            # serve = direct decode pod; pd = via EPP gateway
    # UI no longer exposes MLPerf-style versions for inference. Keep values only for
    # backward compatibility with older saved requests.
    "versions": ["guidellm_llmd", "v4.1", "v5.1", "v5.0", "v6.0"],
    "bench_tool": "guidellm",
    "endpoint_modes": ["pod", "service", "proxy", "manual", "deploy"],
    "profiles": ["sweep", "synchronous", "throughput", "concurrent", "constant", "poisson"],
    "default_proxy": os.environ.get("LLMD_PROXY_URL", "http://127.0.0.1:8896"),
    # llm-d targets NVIDIA H100 in this deployment.
    "gpus": ["H100"],
}


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------


class DashboardPinsBody(BaseModel):
    pins: List[Dict[str, Any]] = Field(default_factory=list)


class DocumentBody(BaseModel):
    document: Any = None


class StartRunBody(BaseModel):
    kind: str = Field("mlperf", description="mlperf | mlperf_k8s | llmd_bench | vllm_bench | pd_bench")
    suite: str = Field("training", description="training | inference (mlperf only); pseudo for vllm/pd")
    version: str = Field("v5.1", description="v4.1 | v5.1 | v6.0 (mlperf only)")
    gpu_type: str = "MIXED"
    hosts: List[str] = Field(..., min_length=1)
    benchmark: Optional[str] = None
    dry_run: bool = False
    docker_image: Optional[str] = None
    log_root: Optional[str] = None
    config_path: Optional[str] = None
    node_gpu_map: Optional[Dict[str, str]] = None
    params: Optional[Dict[str, Any]] = None  # tab-specific config (vllm/pd)


# ---------------------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------------------

app = FastAPI(title="GPU Bench Platform", version="0.2.0")

@app.get("/favicon.ico")
async def favicon():
    return Response(status_code=204)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

FRONTEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__),
                                            "..", "frontend"))


@app.get("/")
async def root_index():
    idx = os.path.join(FRONTEND_DIR, "index.html")
    if not os.path.isfile(idx):
        raise HTTPException(status_code=500, detail=f"frontend not found at {idx}")
    return FileResponse(idx)


if os.path.isdir(os.path.join(FRONTEND_DIR, "vendor")):
    app.mount("/vendor", StaticFiles(directory=os.path.join(FRONTEND_DIR, "vendor")),
              name="vendor")
if os.path.isdir(os.path.join(FRONTEND_DIR, "assets")):
    app.mount("/assets", StaticFiles(directory=os.path.join(FRONTEND_DIR, "assets")),
              name="assets")


@app.on_event("shutdown")
async def _shutdown_active_runs() -> None:
    await runner.stop_active_runs_for_shutdown()


@app.get("/api/health")
async def health():
    return {"ok": True, "backend_started_at": BACKEND_STARTED_AT}


@app.get("/api/config")
async def get_config():
    return {
        "backend_started_at": BACKEND_STARTED_AT,
        "state_dir": STATE.storage_dir,
        "scripts_dir": runner.SCRIPTS_DIR,
        "mlperf_root": runner.MLPERF_ROOT,
        "data_root": runner.DATA_ROOT,
        "log_roots": {f"{a}:{b}": p for (a, b), p in runner.LOG_ROOTS.items()},
        "supported": {
            "mlperf": {f"{s}:{v}": SUPPORTED_MLPERF[(s, v)] for s, v in SUPPORTED_MLPERF},
            "vllm_bench": SUPPORTED_VLLM,
            "pd_bench": SUPPORTED_PD,
            "llmd_bench": SUPPORTED_LLMD,
        },
        "cluster": {
            "warewulf": cluster.ww_meta(),
        },
    }





@app.get("/api/hosts/{host}/gpu_type")
async def detect_host_gpu_type(host: str):
    return await gpu_monitor.detect_gpu_type(host)

def _positive_int_arg(args: Dict[str, Any], *names: str) -> Optional[int]:
    for name in names:
        value = args.get(name)
        if value in (None, ""):
            continue
        try:
            n = int(str(value))
        except (TypeError, ValueError):
            raise HTTPException(400, detail=f"{name} must be a positive integer")
        if n < 1:
            raise HTTPException(400, detail=f"{name} must be >= 1")
        return n
    return None


def _validate_mlperf_training_args(args: Dict[str, Any], *, host: Optional[str] = None) -> None:
    prefix = f"{host}: " if host else ""
    num_gpus = _positive_int_arg(args, "NUM_GPUS", "MLPERF_NUM_GPUS")
    tp = _positive_int_arg(args, "TP", "TENSOR_MODEL_PARALLEL")
    pp = _positive_int_arg(args, "PP", "PIPELINE_MODEL_PARALLEL")
    cp = _positive_int_arg(args, "CP", "CONTEXT_PARALLEL")
    gbs = _positive_int_arg(args, "GBS", "GLOBAL_BATCH_SIZE")
    mbs = _positive_int_arg(args, "MBS", "MICRO_BATCH_SIZE") or 1
    world_gpus = _positive_int_arg(args, "MLPERF_WORLD_SIZE", "WORLD_SIZE_GPUS") or num_gpus
    missing = [name for name, value in [("NUM_GPUS", num_gpus), ("TP", tp), ("PP", pp), ("CP", cp), ("GBS", gbs)] if value is None]
    if missing:
        raise HTTPException(400, detail=f"{prefix}missing MLPerf training argument(s): {', '.join(missing)}")
    mp = tp * pp * cp
    if mp > world_gpus:
        raise HTTPException(400, detail=f"{prefix}TP*PP*CP={mp} exceeds WORLD_SIZE_GPUS={world_gpus}")
    if world_gpus % mp != 0:
        raise HTTPException(400, detail=f"{prefix}WORLD_SIZE_GPUS={world_gpus} must be divisible by TP*PP*CP={mp}")
    dp = world_gpus // mp
    min_gbs = mbs * dp
    if gbs < min_gbs:
        raise HTTPException(400, detail=f"{prefix}GBS={gbs} must be >= MBS({mbs})*DP({dp})={min_gbs}")
    if gbs % min_gbs != 0:
        raise HTTPException(400, detail=f"{prefix}GBS={gbs} must be divisible by MBS({mbs})*DP({dp})={min_gbs}")


def _merged_host_args(params: Dict[str, Any], host: str) -> Dict[str, Any]:
    base = params.get("args") or {}
    by_host = params.get("args_by_host") or {}
    host_args = by_host.get(host) or {}
    merged = dict(base)
    if isinstance(host_args, dict):
        merged.update(host_args)
    if not merged.get("MBS") and merged.get("MICRO_BATCH_SIZE"):
        merged["MBS"] = merged["MICRO_BATCH_SIZE"]
    if not merged.get("MICRO_BATCH_SIZE") and merged.get("MBS"):
        merged["MICRO_BATCH_SIZE"] = merged["MBS"]
    if merged.get("NUM_GPUS") and not merged.get("MLPERF_NUM_GPUS"):
        merged["MLPERF_NUM_GPUS"] = merged["NUM_GPUS"]
    return merged



def _clean_host_value(value: Any) -> str:
    host = str(value or "").strip()
    # A stale frontend/localStorage bug once sent numeric indices like 0 as
    # hosts, which later became an invalid vLLM --group value.  Real hosts in
    # this platform are hostnames or IPs, not a bare integer index.
    if not host or re.fullmatch(r"\d+", host):
        return ""
    return host


def _clean_gpu_type(value: Any, fallback: str = "H100") -> str:
    gpu = str(value or "").strip().upper()
    aliases = {"RTXPRO6000": "RTX_PRO_6000", "RTX_PRO6000": "RTX_PRO_6000"}
    gpu = aliases.get(gpu, gpu)
    if gpu in ALL_GPUS or gpu == "MIXED":
        return gpu
    return fallback


def _clean_node_specs(specs: Any) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    if not isinstance(specs, list):
        return out
    seen = set()
    for item in specs:
        if isinstance(item, dict):
            host = _clean_host_value(item.get("host"))
            try:
                gpus = int(item.get("gpus") or item.get("num_gpus") or 0)
            except (TypeError, ValueError):
                gpus = 0
        else:
            host = _clean_host_value(item)
            gpus = 0
        if not host or host in seen:
            continue
        seen.add(host)
        row: Dict[str, Any] = {"host": host}
        if gpus > 0:
            row["gpus"] = gpus
        out.append(row)
    return out


def _hosts_from_node_specs(specs: Any) -> List[str]:
    return [row["host"] for row in _clean_node_specs(specs)]


def _hosts_for_gpu_detection(body: StartRunBody) -> List[str]:
    """Return the host list that should drive GPU type detection."""
    if body.kind == "pd_bench":
        p = body.params or {}
        return sorted({*(_hosts_from_node_specs(p.get("prefill_nodes")) or p.get("prefill_hosts") or []),
                       *(_hosts_from_node_specs(p.get("decode_nodes")) or p.get("decode_hosts") or [])})
    if body.kind == "vllm_bench":
        p = body.params or {}
        derived = _hosts_from_node_specs(p.get("serve_nodes"))
        if derived:
            return derived
        return [_clean_host_value(h) for h in (body.hosts or []) if _clean_host_value(h)]
    if body.kind == "llmd_bench":
        p = body.params or {}
        hosts = [_clean_host_value(h) for h in (body.hosts or []) if _clean_host_value(h)]
        deploy_node = _clean_host_value(p.get("deploy_node"))
        if deploy_node and deploy_node not in hosts:
            hosts.append(deploy_node)
        return hosts
    return [_clean_host_value(h) for h in (body.hosts or []) if _clean_host_value(h)]


async def _resolve_gpu_types_for_body(body: StartRunBody) -> None:
    """Best-effort host GPU auto-detection before validation/launch.

    Frontend defaults can become stale or wrong across A100/H100/GH200 nodes.
    The backend is the source of truth: detect each requested host through
    nvidia-smi first, then rocm-smi, and overwrite node_gpu_map when successful.
    """
    hosts = _hosts_for_gpu_detection(body)
    if not hosts:
        return

    existing = dict(body.node_gpu_map or {})
    detections = await asyncio.gather(
        *[gpu_monitor.detect_gpu_type(h) for h in hosts],
        return_exceptions=True,
    )

    resolved = dict(existing)
    records: Dict[str, Any] = {}
    for host, det in zip(hosts, detections):
        if isinstance(det, Exception):
            records[host] = {"host": host, "gpu_type": existing.get(host) or body.gpu_type, "error": str(det)}
            continue
        records[host] = det
        gpu_type = str(det.get("gpu_type") or "").strip()
        if gpu_type and gpu_type not in ("UNKNOWN", "MIXED"):
            resolved[host] = gpu_type
        elif host not in resolved and body.gpu_type:
            resolved[host] = body.gpu_type

    if resolved:
        body.node_gpu_map = resolved
        unique = sorted({str(v) for v in resolved.values() if v and str(v) not in ("UNKNOWN",)})
        if len(unique) == 1:
            body.gpu_type = unique[0]
        elif len(unique) > 1:
            body.gpu_type = "MIXED"

    params = dict(body.params or {})
    params["gpu_detection"] = records
    body.params = params

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def _validate_request(body: StartRunBody) -> None:
    kind = body.kind
    if kind == "mlperf":
        key = (body.suite, body.version)
        if key not in SUPPORTED_MLPERF:
            raise HTTPException(400, detail=f"unsupported suite/version: {body.suite}/{body.version}")
        cap = SUPPORTED_MLPERF[key]
        node_gpu_map = body.node_gpu_map or {}
        if node_gpu_map:
            missing = [h for h in body.hosts if h not in node_gpu_map]
            if missing:
                raise HTTPException(400, detail=f"node_gpu_map missing host(s): {missing}")
            invalid = sorted({gt for gt in node_gpu_map.values() if gt not in cap["gpus"]})
            if invalid:
                raise HTTPException(400,
                    detail=f"GPU type(s) {invalid} not allowed for {body.suite} {body.version}")
        elif body.gpu_type not in cap["gpus"]:
            raise HTTPException(400, detail=f"GPU {body.gpu_type} not allowed")
        if body.benchmark and body.benchmark not in cap["benchmarks"]:
            raise HTTPException(400,
                detail=f"benchmark {body.benchmark} not valid for {body.suite} {body.version}")
        if body.suite == "training":
            params = body.params or {}
            args_by_host = params.get("args_by_host") or {}
            if args_by_host and not isinstance(args_by_host, dict):
                raise HTTPException(400, detail="params.args_by_host must be an object keyed by host")
            unknown_hosts = sorted(set(args_by_host.keys()) - set(body.hosts)) if isinstance(args_by_host, dict) else []
            if unknown_hosts:
                raise HTTPException(400, detail=f"params.args_by_host contains unknown host(s): {unknown_hosts}")
            node_mode = str(params.get("node_mode") or "single").lower()
            if node_mode == "multi":
                merged = dict(params.get("args") or {})
                gpu_counts = params.get("gpu_counts_by_host") or {}
                if isinstance(gpu_counts, dict) and gpu_counts:
                    try:
                        per_node = {int(v) for v in gpu_counts.values()}
                    except Exception:
                        raise HTTPException(400, detail="params.gpu_counts_by_host values must be positive integers")
                    if len(per_node) != 1:
                        raise HTTPException(400, detail="Training bare metal multi-node requires the same GPU count on every node")
                    gpn = next(iter(per_node))
                    merged["NUM_GPUS"] = str(gpn)
                    merged["MLPERF_NUM_GPUS"] = str(gpn)
                    merged["WORLD_SIZE_GPUS"] = str(gpn * len(body.hosts))
                    merged["MLPERF_WORLD_SIZE"] = str(gpn * len(body.hosts))
                _validate_mlperf_training_args(merged, host="multi-node")
            else:
                for host in body.hosts:
                    _validate_mlperf_training_args(_merged_host_args(params, host), host=host)

    elif kind == "mlperf_k8s":
        # MLPerf training launched as a Kubernetes Job. Same version/benchmark
        # matrix as 'mlperf' training, but runs in-cluster on GPU nodes.
        key = ("training", body.version)
        if key not in SUPPORTED_MLPERF:
            raise HTTPException(400, detail=f"unsupported training version: {body.version}")
        cap = SUPPORTED_MLPERF[key]
        if body.benchmark and body.benchmark not in cap["benchmarks"]:
            raise HTTPException(400, detail=f"benchmark {body.benchmark} not valid for training {body.version}")
        if body.gpu_type not in cap["gpus"]:
            raise HTTPException(400, detail=f"GPU {body.gpu_type} not allowed for training {body.version}")
        p = body.params or {}
        if not body.hosts:
            raise HTTPException(400, detail="mlperf_k8s requires at least one GPU node in hosts")
        if not p.get("gpus_per_node"):
            raise HTTPException(400, detail="mlperf_k8s requires params.gpus_per_node")
        # model_path/datadir are intentionally not required from the UI.
        # scripts/training/train_k8s.sh derives known-good defaults from
        # version + benchmark + GPU type under POC_PLATFORM_ROOT/data.
        # docker_image is intentionally not required from the UI.
        # scripts/training/train_k8s.sh derives the default image from
        # version + benchmark + GPU type, reusing the known-good standalone
        # MLPerf script image names.

    elif kind == "vllm_bench":
        p = body.params or {}
        engine = p.get("engine", "vllm")
        if engine not in SUPPORTED_VLLM["engines"]:
            raise HTTPException(400, detail=f"vllm_bench engine must be one of {SUPPORTED_VLLM['engines']}")
        bench_data = p.get("bench_data")
        valid_data = SUPPORTED_VLLM["bench_data"][engine]
        if engine == "sglang":
            raise HTTPException(400, detail="sglang engine not implemented yet")
        if bench_data not in valid_data:
            raise HTTPException(400,
                detail=f"vllm_bench bench_data must be one of {valid_data} (engine={engine})")
        if not p.get("model"):
            raise HTTPException(400, detail="vllm_bench requires params.model/model_name")
        if not p.get("model_path"):
            raise HTTPException(400, detail="vllm_bench requires params.model_path for air-gapped local model serving")
        node_gpu_map = body.node_gpu_map or {}
        if node_gpu_map:
            invalid = sorted({gt for gt in node_gpu_map.values() if gt not in SUPPORTED_VLLM["gpus"]})
            if invalid:
                raise HTTPException(400, detail=f"GPU type(s) {invalid} not supported")

    elif kind == "pd_bench":
        p = body.params or {}
        engine = p.get("engine", "vllm")
        if engine not in SUPPORTED_PD["engines"]:
            raise HTTPException(400, detail=f"pd_bench engine must be one of {SUPPORTED_PD['engines']}")
        if engine == "sglang":
            raise HTTPException(400, detail="sglang PD engine not implemented yet")
        valid_data = SUPPORTED_PD["bench_data"][engine]
        if p.get("bench_data") not in valid_data:
            raise HTTPException(400,
                detail=f"pd_bench bench_data must be one of {valid_data} (engine={engine})")
        if not p.get("model"):
            raise HTTPException(400, detail="pd_bench requires params.model/model_name")
        if not p.get("model_path"):
            raise HTTPException(400, detail="pd_bench requires params.model_path for air-gapped local model serving")
        prefill = p.get("prefill_hosts") or []
        decode = p.get("decode_hosts") or []
        for name in ("prefill_instances", "decode_instances"):
            if p.get(name) not in (None, ""):
                try:
                    n = int(p.get(name))
                except Exception:
                    raise HTTPException(400, detail=f"params.{name} must be a positive integer")
                if n < 1:
                    raise HTTPException(400, detail=f"params.{name} must be >= 1")
        if not prefill or not decode:
            raise HTTPException(400, detail="pd_bench requires non-empty prefill_hosts and decode_hosts")
        if any(h in decode for h in prefill):
            raise HTTPException(400, detail="prefill_hosts and decode_hosts must be disjoint")
        if body.gpu_type not in SUPPORTED_PD["gpus"]:
            raise HTTPException(400, detail=f"GPU {body.gpu_type} not supported")

    elif kind == "llmd_bench":
        p = body.params or {}
        mode = p.get("mode", "serve")
        if mode not in SUPPORTED_LLMD["modes"]:
            raise HTTPException(400, detail=f"llmd_bench mode must be one of {SUPPORTED_LLMD['modes']}")
        # Inference is guidellm + llm-d/vLLM based now; MLPerf version is not a UI concept.
        # Keep body.version only as a run label for backward compatibility.
        # model/processor/model_path are supplied from the single model path field in the UI.
        endpoint_mode = p.get("endpoint_mode", "pod")
        if endpoint_mode not in ("pod", "service", "proxy", "manual", "deploy"):
            raise HTTPException(400, detail="endpoint_mode must be pod|service|proxy|manual|deploy")
        if endpoint_mode in ("manual", "proxy") and not (p.get("target") or p.get("proxy_url")):
            raise HTTPException(400, detail=f"endpoint_mode={endpoint_mode} requires params.target or params.proxy_url")
        if not p.get("model_path") and not p.get("processor"):
            raise HTTPException(400, detail="llmd_bench requires params.model_path")
        # namespace is optional in the simplified UI; the script uses LLMD_NAMESPACE
        # or its built-in default when omitted.
        if endpoint_mode == "deploy":
            # model_path is optional in the UI; the script uses LLMD_MODEL_PATH
            # or its built-in default when omitted.
            # GPU spec: explicit indices in params.gpus OR a count (default 4, auto)
            gpus = p.get("gpus")
            count = int(p.get("gpu_count") or 4)
            if gpus:
                bad = [g for g in str(gpus).split(",") if not g.strip().isdigit()]
                if bad:
                    raise HTTPException(400, detail=f"params.gpus must be comma-separated indices: bad={bad}")
            elif count < 1 or count > 32:
                raise HTTPException(400, detail="params.gpu_count must be 1..32")
            # deploy_node defaults to leader/hosts[0]
            if not p.get("deploy_node") and not body.hosts:
                raise HTTPException(400, detail="endpoint_mode=deploy requires params.deploy_node or hosts[0]")
        if body.gpu_type not in SUPPORTED_LLMD["gpus"]:
            raise HTTPException(400, detail=f"llm-d currently targets {SUPPORTED_LLMD['gpus']} only")
        if not body.hosts:
            raise HTTPException(400, detail="llmd_bench requires at least one host to monitor (the worker node running the pods)")

    else:
        raise HTTPException(400, detail=f"unknown kind: {kind}")


# ---------------------------------------------------------------------------
# Run lifecycle endpoints
# ---------------------------------------------------------------------------


@app.post("/api/runs")
async def start_run(body: StartRunBody):
    await _resolve_gpu_types_for_body(body)
    _validate_request(body)

    # For vllm_bench/pd_bench, hosts comes from params; the StartRunBody.hosts
    # is the union we monitor.  For pd_bench, we union prefill+decode here.
    if body.kind == "pd_bench":
        p = body.params or {}
        all_hosts = _hosts_from_node_specs(p.get("prefill_nodes")) + _hosts_from_node_specs(p.get("decode_nodes"))
        if not all_hosts:
            all_hosts = list({*p.get("prefill_hosts", []), *p.get("decode_hosts", [])})
        hosts = list(dict.fromkeys(_clean_host_value(h) for h in all_hosts if _clean_host_value(h)))
        if not hosts:
            raise HTTPException(400, detail="pd_bench: no hosts derived from prefill/decode")
    elif body.kind == "vllm_bench":
        p = dict(body.params or {})
        clean_serve_nodes = _clean_node_specs(p.get("serve_nodes"))
        hosts = [row["host"] for row in clean_serve_nodes]
        if not hosts:
            hosts = [_clean_host_value(h) for h in (body.hosts or []) if _clean_host_value(h)]
            clean_serve_nodes = [{"host": h} for h in hosts]
        if not hosts:
            raise HTTPException(400, detail="vllm_bench: no valid hosts derived from serve_nodes/hosts")
        p["serve_nodes"] = clean_serve_nodes
        body.params = p
        body.hosts = hosts
    else:
        hosts = [_clean_host_value(h) for h in (body.hosts or []) if _clean_host_value(h)]

    node_gpu_map_raw = dict(body.node_gpu_map or {})
    body_gpu_type = _clean_gpu_type(body.gpu_type, "H100")
    node_gpu_map = {h: _clean_gpu_type(node_gpu_map_raw.get(h), body_gpu_type) for h in hosts}

    req = RunRequest(
        kind=body.kind,
        suite=body.suite,
        version=body.version,
        gpu_type=body.gpu_type,
        hosts=hosts,
        benchmark=body.benchmark,
        dry_run=body.dry_run,
        docker_image=body.docker_image,
        log_root=body.log_root,
        config_path=body.config_path,
        node_gpu_map=node_gpu_map,
        params=body.params,
    )
    state = await runner.start_run(req)
    return runner.run_snapshot(state)


@app.get("/api/runs")
async def list_runs():
    runs = STATE.list_runs()
    runs.sort(key=lambda r: r.created_at, reverse=True)
    return [runner.run_snapshot(r) for r in runs]


@app.get("/api/dashboard")
async def get_dashboard():
    return {"pins": STATE.load_dashboard()}


@app.put("/api/dashboard")
async def put_dashboard(body: DashboardPinsBody):
    pins = STATE.persist_dashboard(body.pins or [])
    return {"ok": True, "pins": pins}


@app.get("/api/accelerator-perf")
async def get_accelerator_perf():
    doc = STATE.load_document("accelerator_perf", None)
    return {"document": doc if doc is not None else DEFAULT_ACCELERATOR_PERF}


@app.put("/api/accelerator-perf")
async def put_accelerator_perf(body: DocumentBody):
    return {"ok": True, "document": STATE.persist_document("accelerator_perf", body.document)}


@app.get("/api/gpu-tco-table")
async def get_gpu_tco_table():
    doc = STATE.load_document("gpu_tco_table", None)
    return {"document": doc if doc is not None else DEFAULT_GPU_TCO_TABLE}


@app.put("/api/gpu-tco-table")
async def put_gpu_tco_table(body: DocumentBody):
    return {"ok": True, "document": STATE.persist_document("gpu_tco_table", body.document)}


@app.get("/api/runs/{run_id}")
async def get_run(run_id: str):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    return runner.run_snapshot(run)


@app.delete("/api/runs/{run_id}")
async def delete_run(run_id: str):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    active = str(run.status or "").lower() not in {"success", "failed", "partial", "stopped", "error"}
    if active:
        await runner.stop_hosts(run, list(run.host_states.keys()))
    if not STATE.delete_run(run_id):
        raise HTTPException(404, detail="run not found")
    return {"ok": True, "run_id": run_id}


@app.post("/api/runs/{run_id}/stop")
async def stop_run(run_id: str):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    rc, tail = await runner.stop_hosts(run, list(run.host_states.keys()))
    return {"ok": rc == 0, "exit_code": rc, "tail": tail}


@app.post("/api/runs/{run_id}/stop/{host}")
async def stop_host(run_id: str, host: str):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    if host not in run.host_states:
        raise HTTPException(400, detail=f"host {host} not in run")
    rc, tail = await runner.stop_hosts(run, [host])
    return {"ok": rc == 0, "exit_code": rc, "tail": tail}


# ---- logs ---------------------------------------------------------------


@app.get("/api/runs/{run_id}/logs")
async def get_logs(run_id: str, host: Optional[str] = None,
                   limit: int = 1000, since: float = 0.0):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    out = []
    for ll in run.log_buffer:
        if since and ll.ts <= since:
            continue
        if host and ll.host != host:
            continue
        out.append(asdict(ll))
    return out[-limit:]


@app.get("/api/runs/{run_id}/logs/stream")
async def stream_logs(run_id: str, replay: bool = False):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")

    async def gen():
        if replay:
            for ll in list(run.log_buffer):
                yield {"event": "log", "data": json.dumps(asdict(ll))}

        q = STATE.subscribe_logs(run)
        try:
            while True:
                if run.finished_at and q.empty():
                    return
                try:
                    ll: LogLine = await asyncio.wait_for(q.get(), timeout=15.0)
                    yield {"event": "log", "data": json.dumps(asdict(ll))}
                except asyncio.TimeoutError:
                    if run.finished_at:
                        return
                    yield {"event": "ping", "data": "1"}
        finally:
            STATE.unsubscribe_logs(run, q)

    return EventSourceResponse(gen())


# ---- results ------------------------------------------------------------


def _collect_host_error_messages(run, host: str) -> List[str]:
    out: List[str] = []
    seen = set()
    for ll in run.log_buffer:
        # K8s launchers often emit orchestrator-level errors without a host
        # prefix. Include those global errors in each host row so failed runs do
        # not show an empty Result Analysis table.
        if ll.host not in (host, ""):
            continue
        line = str(ll.line or "").strip()
        if not line:
            continue
        normalized = line.lstrip()
        is_error = (
            normalized.startswith("[ERROR]")
            or normalized.startswith("[FATAL]")
            or ll.level in ("error", "fatal")
        )
        if not is_error:
            continue
        if line not in seen:
            seen.add(line)
            out.append(line)
    return out


def _build_results(run) -> Dict[str, Any]:
    table = []
    for h in run.hosts:
        hs = run.host_states[h]
        if hs.status in ("pending", "running"):
            ui_status = "analyzing"
        elif hs.status == "success":
            ui_status = "ready" if hs.result_metrics or hs.result_summary else "analyzing"
        elif hs.status == "stopped":
            ui_status = "stopped"
        else:
            ui_status = "error"

        if hs.result_metrics is None and hs.log_dir:
            try:
                metrics, perr = parse_result_dir(hs.log_dir, run.suite, run.kind)
                if metrics:
                    hs.result_metrics = metrics
                if perr:
                    hs.result_error = perr
            except Exception as e:  # noqa: BLE001
                hs.result_error = f"{type(e).__name__}: {e}"

        log_metrics = None
        if run.kind in ("mlperf", "mlperf_k8s"):
            try:
                host_lines = [ll.line for ll in run.log_buffer if ll.host == h]
                parsed_live = parse_log_buffer_lines(host_lines, run.suite)
                if parsed_live.get("metric_display"):
                    log_metrics = parsed_live
            except Exception as e:  # noqa: BLE001
                if not hs.result_error:
                    hs.result_error = f"live-log parse: {type(e).__name__}: {e}"

        metrics_for_ui = hs.result_metrics or log_metrics

        # Merge MLPerf_RESULT_JSON duration and the effective global batch size
        # into the strictly allowed MLPerf metric set.  MAX_STEPS/TP/PP/etc. remain
        # dashboard dimensions, not metrics.
        if metrics_for_ui is not None and run.kind in ("mlperf", "mlperf_k8s"):
            metrics_for_ui = dict(metrics_for_ui)
            mv = dict(metrics_for_ui.get("metric_values") or {})
            display = list(metrics_for_ui.get("metric_display") or [])

            if hs.result_summary:
                dur = hs.result_summary.get("duration_sec")
                if isinstance(dur, (int, float)):
                    mv.setdefault("duration_sec", dur)
                    metrics_for_ui["duration_sec"] = dur
                    if not any(item.get("key") == "duration_sec" for item in display if isinstance(item, dict)):
                        display.append({"key": "duration_sec", "value": dur})

            arg_gbs = (run.params or {}).get("args", {}).get("GBS")
            try:
                gbs_num = float(arg_gbs) if arg_gbs not in (None, "") else None
            except (TypeError, ValueError):
                gbs_num = None
            if gbs_num is not None and "global_batch_size" not in mv:
                gbs_val = int(gbs_num) if gbs_num.is_integer() else gbs_num
                mv["global_batch_size"] = gbs_val
                metrics_for_ui["global_batch_size"] = gbs_val
                if not any(item.get("key") == "global_batch_size" for item in display if isinstance(item, dict)):
                    display.append({"key": "global_batch_size", "value": gbs_val})

            allowed = {"train_loss", "train_step_time", "eval_accuracy", "validation_time",
                       "step", "samples_count", "eval_samples", "global_batch_size", "duration_sec"}
            mv = {k: v for k, v in mv.items() if k in allowed}
            metrics_for_ui["metric_values"] = mv
            metrics_for_ui["metric_display"] = [item for item in display if isinstance(item, dict) and item.get("key") in allowed]

        if metrics_for_ui is None and hs.result_summary:
            if run.kind in ("mlperf", "mlperf_k8s"):
                dur = hs.result_summary.get("duration_sec")
                metric_display = []
                metric_values = {}
                if isinstance(dur, (int, float)):
                    metric_values["duration_sec"] = dur
                    metric_display.append({"key": "duration_sec", "value": dur})
                metrics_for_ui = {
                    "kind": run.kind,
                    "_source": "MLPerf_RESULT_JSON",
                    "result_hint": hs.result_summary.get("result_hint"),
                    "duration_sec": dur,
                    "log_dir": hs.result_summary.get("log_dir"),
                    "metric_values": metric_values,
                    "metric_display": metric_display,
                }
            else:
                metrics_for_ui = {
                    "kind": run.kind,
                    "_source": f"{run.kind.upper()}_RESULT_JSON",
                    "result_hint": hs.result_summary.get("result_hint"),
                    "duration_sec": hs.result_summary.get("duration_sec"),
                    "log_dir": hs.result_summary.get("log_dir"),
                    "status": hs.result_summary.get("status"),
                    "metric_display": [
                        {"key": "status", "value": hs.result_summary.get("status")},
                        {"key": "duration_sec", "value": hs.result_summary.get("duration_sec")},
                    ],
                }

        if hs.status == "success" and (metrics_for_ui or hs.result_summary):
            ui_status = "ready"

        duration_sec = None
        if hs.started_at and hs.ended_at:
            duration_sec = hs.ended_at - hs.started_at
        elif hs.result_summary and hs.result_summary.get("duration_sec") is not None:
            duration_sec = hs.result_summary.get("duration_sec")

        error_messages = _collect_host_error_messages(run, h)
        if hs.result_error:
            error_messages.append(hs.result_error)
        error_messages = list(dict.fromkeys([m for m in error_messages if m]))

        table.append({
            "host": h,
            "status": hs.status,
            "ui_status": ui_status,
            "phase": hs.phase,
            "exit_code": hs.exit_code,
            "duration_sec": duration_sec,
            "log_dir": hs.log_dir,
            "container": hs.container_name,
            "summary": hs.result_summary,
            "metrics": metrics_for_ui,
            "result_error": hs.result_error,
            "error_messages": error_messages,
        })

    return {
        "run_id": run.run_id,
        "kind": run.kind,
        "suite": run.suite,
        "version": run.version,
        "benchmark": run.benchmark,
        "gpu_type": runner.run_snapshot(run).get("gpu_type", run.gpu_type),
        "status": run.status,
        "rows": table,
    }


@app.get("/api/runs/{run_id}/results")
async def get_results(run_id: str):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    return _build_results(run)


# ---- per-run gpu samples (for the report download) ----------------------


@app.get("/api/runs/{run_id}/gpu_samples")
async def get_run_gpu_samples(run_id: str):
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")
    by_host = {}
    for h in run.hosts:
        filtered = []
        for raw in _samples_for_report_host(run, h):
            sample = _filter_sample_for_run(raw, run, h)
            if sample:
                filtered.append(sample)
        by_host[h] = filtered
    return {
        "run_id": run.run_id,
        "started_at": run.created_at,
        "finished_at": run.finished_at,
        "by_host": by_host,
    }


# ---------------------------------------------------------------------------
# REPORT DOWNLOAD - self-contained HTML with inline SVG charts + logs
# ---------------------------------------------------------------------------


def _svg_chart(title: str, unit: str, series: List[Dict[str, Any]],
               y_max: float, width: int = 980, height: int = 240) -> str:
    """Render a small line chart as SVG with no external deps.
    series: [{"host": "...", "color": "#xxxx", "points": [(t, v), ...]}]
    """
    if not series or all(not s["points"] for s in series):
        return f'<div class="chart-empty">{_esc(title)}: no samples</div>'

    pad_l, pad_r, pad_t, pad_b = 56, 16, 28, 28
    plot_w = width - pad_l - pad_r
    plot_h = height - pad_t - pad_b

    all_ts = [t for s in series for (t, _v) in s["points"]]
    if not all_ts:
        return f'<div class="chart-empty">{_esc(title)}: no samples</div>'
    t0 = min(all_ts)
    t1 = max(all_ts)
    t_span = max(0.001, t1 - t0)
    y_max = max(0.001, y_max)

    def x_for(t):
        return pad_l + (t - t0) / t_span * plot_w

    def y_for(v):
        v = max(0.0, min(y_max, v))
        return pad_t + (1 - v / y_max) * plot_h

    parts = [
        f'<svg viewBox="0 0 {width} {height}" '
        f'xmlns="http://www.w3.org/2000/svg" preserveAspectRatio="none">',
        '<style>.gax{stroke:#2a3140;stroke-width:1}'
        '.gtx{fill:#9aa0ad;font:11px ui-monospace,Consolas,monospace}'
        '.gln{fill:none;stroke-width:1.5}'
        '.gtt{fill:#e8eaef;font:13px ui-sans-serif,system-ui,sans-serif}'
        '.gun{fill:#9aa0ad;font:10px ui-monospace,Consolas,monospace}</style>',
        f'<text class="gtt" x="{pad_l}" y="16">{_esc(title)}</text>',
        f'<text class="gun" x="{pad_l}" y="{height - 8}">{_esc(unit)}</text>',
    ]

    # Y axis ticks
    for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
        y = pad_t + (1 - frac) * plot_h
        v = frac * y_max
        parts.append(f'<line class="gax" x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + plot_w}" y2="{y:.1f}"/>')
        parts.append(f'<text class="gtx" x="6" y="{y + 4:.1f}">{v:.0f}</text>')

    # X axis ticks (start, mid, end)
    import datetime as _dt
    for frac in (0.0, 0.5, 1.0):
        t = t0 + frac * t_span
        x = x_for(t)
        lab = _dt.datetime.fromtimestamp(t).strftime("%H:%M:%S")
        parts.append(f'<line class="gax" x1="{x:.1f}" y1="{pad_t}" x2="{x:.1f}" y2="{pad_t + plot_h}"/>')
        parts.append(f'<text class="gtx" x="{x:.1f}" y="{pad_t + plot_h + 14:.1f}" '
                     f'text-anchor="middle">{_esc(lab)}</text>')

    # Lines
    for s in series:
        if not s["points"]:
            continue
        d = []
        for i, (t, v) in enumerate(s["points"]):
            x = x_for(t); y = y_for(v)
            d.append(f"{'M' if i == 0 else 'L'}{x:.1f},{y:.1f}")
        color = s.get("color", "#a3e635")
        parts.append(f'<path class="gln" d="{" ".join(d)}" stroke="{color}"/>')

    # Legend
    lx = pad_l + 12; ly = pad_t + 16
    for s in series:
        color = s.get("color", "#a3e635")
        host = s.get("host", "")
        parts.append(
            f'<rect x="{lx}" y="{ly - 8}" width="10" height="3" fill="{color}"/>'
            f'<text class="gtx" x="{lx + 16}" y="{ly}">{_esc(host)}</text>'
        )
        lx += max(70, len(host) * 7 + 24)

    parts.append('</svg>')
    return "\n".join(parts)


def _color_for_host(host: str) -> str:
    palette = ["#a3e635", "#22d3ee", "#f97316", "#f59e0b", "#22c55e",
               "#ef4444", "#8b5cf6", "#ec4899", "#3b82f6", "#10b981"]
    s = sum(ord(c) for c in host)
    return palette[s % len(palette)]


def _gpu_tdp(gpu_type: str) -> int:
    table = {"V100": 300, "A100": 400, "H100": 700, "GH200": 900,
             "RTX6000": 300, "RTX_PRO_6000": 600, "B300": 1200}
    return table.get(gpu_type, 700)


def _parse_gpu_indices(value: Any) -> Optional[set[int]]:
    if value in (None, ""):
        return None
    if isinstance(value, (list, tuple, set)):
        raw = value
    else:
        raw = re.split(r"[,\s]+", str(value).strip())
    out: set[int] = set()
    for item in raw:
        if item in (None, ""):
            continue
        try:
            idx = int(str(item).strip())
        except (TypeError, ValueError):
            continue
        if idx >= 0:
            out.add(idx)
    return out or None


def _first_n_gpu_indices(value: Any) -> Optional[set[int]]:
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError, AttributeError):
        return None
    if n <= 0:
        return None
    return set(range(n))


def _selected_gpu_indices_for_host(run, host: str) -> Optional[set[int]]:
    params = run.params if isinstance(run.params, dict) else {}
    args = params.get("args") if isinstance(params.get("args"), dict) else {}
    by_host_args = params.get("args_by_host") if isinstance(params.get("args_by_host"), dict) else {}
    selected = params.get("selected_gpus_by_host") if isinstance(params.get("selected_gpus_by_host"), dict) else {}
    host_args = by_host_args.get(host) if isinstance(by_host_args.get(host), dict) else {}
    return (
        _parse_gpu_indices(selected.get(host))
        or _parse_gpu_indices(host_args.get("MLPERF_CUDA_VISIBLE_DEVICES"))
        or _parse_gpu_indices(args.get("MLPERF_CUDA_VISIBLE_DEVICES"))
        or _first_n_gpu_indices(params.get("gpus_per_node"))
        or _first_n_gpu_indices(args.get("NUM_GPUS"))
        or _first_n_gpu_indices(args.get("MLPERF_NUM_GPUS"))
    )


def _filter_sample_for_run(sample: Dict[str, Any], run, host: str) -> Optional[Dict[str, Any]]:
    allowed = _selected_gpu_indices_for_host(run, host)
    per_gpu = sample.get("per_gpu") if isinstance(sample, dict) else None
    if not allowed or not isinstance(per_gpu, list):
        return sample
    filtered = []
    for g in per_gpu:
        try:
            idx = int(g.get("index"))
        except Exception:  # noqa: BLE001
            continue
        if idx in allowed:
            filtered.append(g)
    if not filtered:
        return None
    utils = []
    powers = []
    mem_used = 0.0
    mem_total = 0.0
    for g in filtered:
        try: utils.append(float(g.get("util") or 0))
        except Exception: pass  # noqa: E701
        try: powers.append(float(g.get("power_w") or 0))
        except Exception: pass  # noqa: E701
        try: mem_used += float(g.get("mem_used_gb") or 0)
        except Exception: pass  # noqa: E701
        try: mem_total += float(g.get("mem_total_gb") or 0)
        except Exception: pass  # noqa: E701
    out = dict(sample)
    out["per_gpu"] = filtered
    out["gpu_count"] = len(filtered)
    if utils:
        out["util_avg"] = sum(utils) / len(utils)
        out["util_max"] = max(utils)
    if powers:
        out["power_total_w"] = sum(powers)
        out["power_avg_w"] = sum(powers) / len(powers)
    out["mem_used_gb"] = mem_used
    out["mem_total_gb"] = mem_total
    return out



def _samples_for_report_host(run, host: str) -> List[Dict[str, Any]]:
    """Return buffered samples for a run, with live-stream fallback.

    Older versions stored live GPU samples only in the host stream.  The report
    should still show the utilization/power table for those runs when possible.
    """
    samples = list(run.gpu_samples.get(host, []))
    if samples:
        return samples
    try:
        stream = STATE.gpu_streams.get(host)
        raw_stream = list(stream.samples) if stream else []
    except Exception:
        raw_stream = []
    if not raw_stream:
        return []
    start = float(run.created_at or 0)
    end = float(run.finished_at or _now())
    out: List[Dict[str, Any]] = []
    from dataclasses import asdict as _asdict
    for sample in raw_stream:
        if isinstance(sample, dict):
            item = sample
        else:
            try:
                item = _asdict(sample)
            except Exception:
                continue
        try:
            ts = float(item.get("ts") or 0)
        except Exception:
            continue
        if (not start or ts >= start) and (not end or ts <= end + 5):
            out.append(item)
    return out

def _series_for_field(run, field_name: str) -> List[Dict[str, Any]]:
    out = []
    for h in run.hosts:
        pts = []
        for raw in _samples_for_report_host(run, h):
            s = _filter_sample_for_run(raw, run, h)
            if not s:
                continue
            v = s.get(field_name)
            t = s.get("ts")
            if v is None or t is None:
                continue
            pts.append((float(t), float(v)))
        out.append({"host": h, "color": _color_for_host(h), "points": pts})
    return out


def _per_gpu_monitor_timeline_html(run, interval_sec: int = 10) -> str:
    """Render used-GPU timeline rows at a fixed interval for the downloadable report."""
    rows: List[str] = []
    started = float(run.created_at or _now())
    for h in run.hosts:
        last_bucket: Optional[int] = None
        for raw in sorted(_samples_for_report_host(run, h), key=lambda x: float(x.get("ts") or 0)):
            sample = _filter_sample_for_run(raw, run, h)
            if not sample:
                continue
            ts = sample.get("ts")
            try:
                ts_f = float(ts)
            except (TypeError, ValueError):
                continue
            bucket = int(max(0.0, ts_f - started) // max(1, interval_sec))
            if bucket == last_bucket:
                continue
            last_bucket = bucket
            elapsed = int(round(ts_f - started))
            per_gpu_rows = sample.get("per_gpu") or []
            if not per_gpu_rows:
                per_gpu_rows = [{
                    "index": "avg",
                    "util": sample.get("util_avg"),
                    "power_w": sample.get("power_avg_w"),
                    "mem_used_gb": sample.get("mem_used_gb"),
                    "mem_total_gb": sample.get("mem_total_gb"),
                }]
            for g in per_gpu_rows:
                raw_idx = g.get("index")
                gpu_label = f"GPU{raw_idx}" if str(raw_idx).isdigit() else "GPU avg"
                util = g.get("util")
                power = g.get("power_w")
                mem_used = g.get("mem_used_gb")
                mem_total = g.get("mem_total_gb")
                rows.append(
                    "<tr>"
                    f"<td>{_esc(_iso(ts_f))}</td>"
                    f"<td>+{elapsed}s</td>"
                    f"<td>{_esc(h)}</td>"
                    f"<td>{_esc(gpu_label)}</td>"
                    f"<td>{'—' if util is None else f'{float(util):.1f}%'}</td>"
                    f"<td>{'—' if power is None else f'{float(power):.1f} W'}</td>"
                    f"<td>{'—' if mem_used is None or mem_total is None else f'{float(mem_used):.1f}/{float(mem_total):.1f} GB'}</td>"
                    "</tr>"
                )
    if not rows:
        return '<div class="chart-empty">no GPU Utilization / Power timeline table samples</div>'
    return (
        f"<details class='gpu-timeline-details' open><summary>show table: GPU Utilization / Power timeline ({len(rows)} rows, {interval_sec}s interval, used GPUs only)</summary>"
        "<div class='table-scroll'><table class='kv gpu-timeline-table'>"
        "<thead><tr><th>time</th><th>elapsed</th><th>host</th><th>gpu</th><th>util</th><th>power</th><th>memory</th></tr></thead>"
        "<tbody>" + "".join(rows) + "</tbody></table></div></details>"
    )


def _format_duration(sec: Optional[float]) -> str:
    if sec is None:
        return "—"
    s = int(sec)
    h, rem = divmod(s, 3600)
    m, ss = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {ss}s"
    if m:
        return f"{m}m {ss}s"
    return f"{ss}s"


@app.get("/api/runs/{run_id}/report", response_class=HTMLResponse)
async def get_run_report(run_id: str):
    """Return a self-contained HTML report for a finished run.
    Includes: metadata header, full-run utilization+power charts (inline SVG),
    per-host result analysis, per-host log dumps.
    """
    run = STATE.get_run(run_id)
    if not run:
        raise HTTPException(404, detail="run not found")

    results = _build_results(run)
    run_snap = runner.run_snapshot(run)
    report_gpu_type = run_snap.get("gpu_type", run.gpu_type)
    report_node_gpu_map = run_snap.get("node_gpu_map", run.node_gpu_map or {})

    util_series = _series_for_field(run, "util_avg")
    power_series = _series_for_field(run, "power_avg_w")

    # Y-axis caps
    util_y = 100.0
    power_y = max(
        [_gpu_tdp(report_node_gpu_map.get(h, report_gpu_type)) for h in run.hosts]
        or [_gpu_tdp(report_gpu_type)]
    )

    started = run.created_at
    finished = run.finished_at or 0
    duration = (finished - started) if finished else None

    # Metadata top row
    meta_rows = [
        ("run_id", run.run_id),
        ("kind", run.kind),
        ("suite", run.suite),
        ("version", run.version),
        ("benchmark", run.benchmark),
        ("gpu_type", report_gpu_type),
        ("hosts", ", ".join(run.hosts)),
        ("status", run.status),
        ("started_at", _esc(_iso(started))),
        ("finished_at", _esc(_iso(finished)) if finished else "—"),
        ("duration", _format_duration(duration)),
    ]
    meta_html = "".join(
        f'<tr><th>{_esc(str(k))}</th><td>{_esc(str(v))}</td></tr>'
        for k, v in meta_rows
    )

    # Per-host rows
    host_blocks = []
    for row in results["rows"]:
        h = row["host"]
        host_color = _color_for_host(h)
        metrics = row.get("metrics") or {}
        md = metrics.get("metric_display") or []
        if md:
            metrics_html = "<table class='kv'>" + "".join(
                f"<tr><th>{_esc(str(m['key']))}</th><td>{_esc(str(m['value']))}</td></tr>"
                for m in md
            ) + "</table>"
        else:
            metrics_html = "<div class='no-metric'>no parsed metrics</div>"

        summary = row.get("summary") or {}
        summary_html = ""
        if summary:
            summary_html = "<details><summary>summary JSON</summary><pre>" + \
                _esc(json.dumps(summary, indent=2)) + "</pre></details>"

        # logs
        host_lines = [ll for ll in run.log_buffer if ll.host == h]
        log_dump = "\n".join(f"{_iso(ll.ts)}  {ll.line}" for ll in host_lines[-2000:])
        if not log_dump:
            log_dump = "(no log lines)"

        errors = row.get("error_messages") or []
        err_html = ""
        if errors:
            err_html = "<div class='errs'><b>errors</b><ul>" + \
                "".join(f"<li><code>{_esc(e)}</code></li>" for e in errors) + "</ul></div>"

        host_blocks.append(f"""
<section class="host-block">
  <h3 class="host-h"><span class="dot" style="background:{host_color}"></span>{_esc(h)}
    <span class="badge st-{_esc(row['status'])}">{_esc(row['status'])}</span>
    <span class="phase">phase: {_esc(row.get('phase') or '—')}</span>
    <span class="dur">duration: {_format_duration(row.get('duration_sec'))}</span>
  </h3>
  <div class="host-meta">
    <div><b>log_dir:</b> {_esc(str(row.get('log_dir') or '—'))}</div>
    <div><b>container:</b> {_esc(str(row.get('container') or '—'))}</div>
    <div><b>exit_code:</b> {_esc(str(row.get('exit_code') if row.get('exit_code') is not None else '—'))}</div>
  </div>
  <h4>result analysis</h4>
  {metrics_html}
  {summary_html}
  {err_html}
  <h4>logs</h4>
  <details><summary>show {len(host_lines)} log lines</summary><pre class="log">{_esc(log_dump)}</pre></details>
</section>""")

    util_svg = _svg_chart("GPU utilization (mean across visible GPUs)", "%, 0–100",
                          util_series, util_y)
    power_svg = _svg_chart("Power draw per GPU", f"W, y-max=max TDP among nodes ({power_y}W)",
                           power_series, float(power_y))
    per_gpu_html = _per_gpu_monitor_timeline_html(run)

    html = f"""<!doctype html>
<html lang="ko"><head>
<meta charset="utf-8"/>
<title>{_esc(run.run_id)} · run report</title>
<style>
  :root {{ --bg:#06070a; --fg:#e8eaef; --mut:#9aa0ad; --line:#1f2530; --panel:#11141b; --volt:#a3e635; }}
  body {{ background:var(--bg); color:var(--fg); font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;
         margin:0; padding:32px; }}
  h1 {{ font-size:22px; margin:0 0 4px 0; letter-spacing:-0.01em; }}
  h2 {{ font-size:14px; text-transform:uppercase; letter-spacing:0.18em;
        color:var(--mut); margin:32px 0 12px 0; font-family:ui-monospace,Consolas,monospace; }}
  h3.host-h {{ font-size:15px; margin:20px 0 8px 0; display:flex; align-items:center; gap:10px; flex-wrap:wrap; }}
  h4 {{ font-size:11px; text-transform:uppercase; letter-spacing:0.16em;
        color:var(--mut); margin:14px 0 6px 0; font-family:ui-monospace,Consolas,monospace; }}
  .panel {{ background:var(--panel); border:1px solid var(--line); border-radius:10px;
            padding:18px; margin-bottom:16px; }}
  table.kv {{ border-collapse:collapse; width:100%; font-size:13px; }}
  table.kv th {{ text-align:left; font-weight:500; color:var(--mut); padding:4px 12px 4px 0;
                 width:160px; font-family:ui-monospace,Consolas,monospace; font-size:11px;
                 text-transform:uppercase; letter-spacing:0.12em; }}
  table.kv td {{ padding:4px 0; font-family:ui-monospace,Consolas,monospace; font-size:12px; }}
  table.gpu-timeline-table th, table.gpu-timeline-table td {{ padding:7px 10px; border-bottom:1px solid var(--line); white-space:nowrap; }}
  table.gpu-timeline-table thead th {{ color:var(--mut); text-transform:uppercase; letter-spacing:.12em; font-size:10px; position:sticky; top:0; background:var(--panel); }}
  .table-scroll {{ max-height:560px; overflow:auto; border:1px solid var(--line); border-radius:8px; margin-top:10px; }}
  .gpu-timeline-details {{ margin-top:14px; }}
  .dot {{ display:inline-block; width:10px; height:10px; border-radius:50%; }}
  .badge {{ font-family:ui-monospace,Consolas,monospace; font-size:10px;
           padding:2px 8px; border-radius:6px; border:1px solid var(--line);
           text-transform:uppercase; letter-spacing:0.12em; }}
  .st-success {{ color:#22c55e; border-color:#22c55e44; background:#22c55e0d; }}
  .st-failed  {{ color:#ef4444; border-color:#ef444444; background:#ef44440d; }}
  .st-stopped {{ color:#f59e0b; border-color:#f59e0b44; background:#f59e0b0d; }}
  .st-error   {{ color:#ef4444; border-color:#ef444444; background:#ef44440d; }}
  .phase, .dur {{ color:var(--mut); font-size:11px; font-family:ui-monospace,Consolas,monospace; }}
  .host-meta {{ color:var(--mut); font-size:12px; font-family:ui-monospace,Consolas,monospace;
                margin-bottom:8px; display:flex; gap:24px; flex-wrap:wrap; }}
  .errs {{ margin-top:8px; padding:8px 12px; border:1px solid #ef444433; background:#ef44440a;
           border-radius:6px; }}
  .errs ul {{ margin:6px 0 0 16px; padding:0; }}
  .errs code {{ font-size:11px; }}
  pre.log {{ background:#0a0c11; border:1px solid var(--line); padding:12px; border-radius:6px;
             font-size:11px; max-height:480px; overflow:auto; line-height:1.4; }}
  pre {{ font-family:ui-monospace,Consolas,monospace; }}
  details {{ margin:8px 0; }}
  summary {{ cursor:pointer; color:var(--mut); font-size:12px;
             font-family:ui-monospace,Consolas,monospace; }}
  .chart-empty {{ color:var(--mut); padding:18px; font-style:italic; font-size:13px; }}
  svg {{ width:100%; height:auto; max-height:280px; display:block; }}
  .no-metric {{ color:var(--mut); font-style:italic; font-size:12px; padding:6px 0; }}
  footer {{ color:var(--mut); font-size:10px; margin-top:32px;
            font-family:ui-monospace,Consolas,monospace;
            text-transform:uppercase; letter-spacing:0.16em; }}
</style></head><body>

<h1>{_esc(run.run_id)} <span class="badge st-{_esc(run.status)}">{_esc(run.status)}</span></h1>
<div style="color:var(--mut); font-family:ui-monospace,Consolas,monospace; font-size:12px; margin-bottom:16px;">
  {_esc(run.kind)} · {_esc(run.suite)} {_esc(run.version)} · {_esc(run.benchmark)} · {_esc(report_gpu_type)}
</div>

<h2>metadata</h2>
<div class="panel"><table class="kv">{meta_html}</table></div>

<h2>gpu utilization</h2>
<div class="panel">{util_svg}</div>

<h2>power draw</h2>
<div class="panel">{power_svg}</div>

<h2>gpu utilization / power timeline table</h2>
<div class="panel">{per_gpu_html}</div>

<h2>per-host result analysis &amp; logs</h2>
{"".join(f'<div class="panel">{b}</div>' for b in host_blocks)}

<footer>generated by gpu bench platform · {_esc(_iso(_now()))}</footer>
</body></html>
"""
    headers = {
        "Content-Disposition": f'attachment; filename="{run.run_id}_report.html"',
    }
    return HTMLResponse(content=html, headers=headers)


def _iso(ts: float) -> str:
    if not ts:
        return "—"
    import datetime as _dt
    return _dt.datetime.fromtimestamp(ts).isoformat(timespec="seconds")


def _now() -> float:
    import time as _t
    return _t.time()


# ---------------------------------------------------------------------------
# GPU streams
# ---------------------------------------------------------------------------


@app.get("/api/hosts/{host}/gpu")
async def get_gpu_recent(host: str, n: int = 60):
    gpu_monitor.ensure_monitor(host)
    s = STATE.get_or_create_gpu_stream(host)
    samples = list(s.samples)[-n:]
    return {
        "host": host,
        "reachable": s.reachable,
        "last_error": s.last_error,
        "samples": [asdict(x) for x in samples],
    }


@app.get("/api/hosts/{host}/gpu/stream")
async def stream_gpu(host: str, replay: bool = True):
    gpu_monitor.ensure_monitor(host)

    async def gen():
        s = STATE.get_or_create_gpu_stream(host)
        if replay:
            for x in list(s.samples)[-30:]:
                yield {"event": "sample", "data": json.dumps(asdict(x))}
        q = STATE.subscribe_gpu(host)
        try:
            while True:
                try:
                    sample = await asyncio.wait_for(q.get(), timeout=15.0)
                    yield {"event": "sample", "data": json.dumps(asdict(sample))}
                except asyncio.TimeoutError:
                    yield {"event": "ping", "data": "1"}
        finally:
            STATE.unsubscribe_gpu(host, q)

    return EventSourceResponse(gen())


# ---------------------------------------------------------------------------
# Cluster management: OS provisioning (Warewulf proxy) + Kubernetes
# ---------------------------------------------------------------------------


class WwPowerBody(BaseModel):
    action: str = Field(..., description="on | off | cycle | reset")


class WwAddBody(BaseModel):
    hostname: str = Field(..., description="Warewulf node hostname to add")
    profile: Optional[str] = None
    netname: Optional[str] = None
    netdev: Optional[str] = None
    type: Optional[str] = None
    hwaddr: Optional[str] = None
    ipaddr: Optional[str] = None
    netmask: Optional[str] = None
    gateway: Optional[str] = None
    mtu: Optional[str] = None
    primarynet: Optional[str] = None
    ipmiaddr: Optional[str] = None


class WwProvisionBody(BaseModel):
    image: Optional[str] = None
    profile: Optional[str] = None
    overlay: Optional[str] = None
    rebuild: bool = True


class K8sJoinBody(BaseModel):
    target: str = Field(..., description="worker hostname or IP reachable via SSH from the master")
    ssh_user: Optional[str] = None


def _ww_response(status: int, payload: Any) -> Response:
    return Response(
        content=json.dumps(payload),
        media_type="application/json",
        status_code=200 if 200 <= status < 300 else status,
    )


@app.get("/api/cluster/warewulf/meta")
async def ww_meta_route():
    return cluster.ww_meta()


@app.get("/api/cluster/warewulf/nodes")
async def ww_nodes_route():
    status, payload = await cluster.ww_list_nodes()
    return _ww_response(status, payload)


@app.post("/api/cluster/warewulf/nodes")
async def ww_add_node_route(body: WwAddBody):
    payload = body.model_dump(exclude_none=True)
    full_keys = {"profile", "netname", "netdev", "type", "hwaddr", "ipaddr", "netmask", "gateway", "mtu", "primarynet", "ipmiaddr"}
    if any(k in payload for k in full_keys):
        status, res = await cluster.ww_add_node_cli(payload)
    else:
        status, res = await cluster.ww_add_node(body.hostname)
    return _ww_response(status, res)


@app.get("/api/cluster/ssh_status")
async def ssh_status_route(target: str, ssh_user: Optional[str] = None):
    return await cluster.ssh_status(target, ssh_user)


@app.get("/api/cluster/warewulf/nodes/{node_id}")
async def ww_node_route(node_id: str):
    status, payload = await cluster.ww_node_detail(node_id)
    return _ww_response(status, payload)


@app.post("/api/cluster/warewulf/nodes/{node_id}/power")
async def ww_power_route(node_id: str, body: WwPowerBody):
    status, payload = await cluster.ww_node_power(node_id, body.action)
    return _ww_response(status, payload)


@app.get("/api/cluster/warewulf/nodes/{node_id}/boot")
async def ww_boot_route(node_id: str, ssh_user: Optional[str] = None):
    return await cluster.ww_node_boot_status(node_id, ssh_user)


@app.post("/api/cluster/warewulf/nodes/{node_id}/provision")
async def ww_provision_route(node_id: str, body: WwProvisionBody):
    status, payload = await cluster.ww_node_provision(node_id, body.model_dump(exclude_none=True))
    return _ww_response(status, payload)


@app.get("/api/cluster/k8s/status")
async def k8s_status_route():
    return await cluster.k8s_status()


@app.get("/api/cluster/k8s/nodes")
async def k8s_nodes_route():
    return await cluster.k8s_nodes()


@app.get("/api/cluster/k8s/pods")
async def k8s_pods_route(namespace: Optional[str] = None):
    return await cluster.k8s_pods(namespace)


@app.get("/api/cluster/k8s/services")
async def k8s_services_route(namespace: Optional[str] = None):
    return await cluster.k8s_services(namespace)


@app.get("/api/cluster/k8s/workloads")
async def k8s_workloads_route(namespace: Optional[str] = None):
    return await cluster.k8s_workloads(namespace)


@app.get("/api/cluster/k8s/llmd_endpoints")
async def k8s_llmd_endpoints_route(namespace: Optional[str] = None):
    return await cluster.k8s_llmd_endpoints(namespace)


@app.post("/api/cluster/k8s/join")
async def k8s_join_route(body: K8sJoinBody):
    return await cluster.k8s_join_worker(body.target, body.ssh_user)


@app.get("/api/cluster/topology")
async def topology_route(node: str):
    """GPU<->NIC binding for a node (parsed from `nvidia-smi topo -m`)."""
    from . import topology
    b = await topology.fetch_binding(node, use_cache=False)
    # don't ship the giant raw matrix unless asked
    b.pop("raw", None)
    return b


@app.get("/api/cluster/free_gpus")
async def free_gpus_route(node: str, count: int = 4):
    """Auto-select ``count`` free GPUs on a node + derive their bound NICs."""
    from . import topology
    return await topology.find_free_gpus(node, count=max(1, min(int(count), 32)))
