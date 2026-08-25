"""
runner.py
---------
Subprocess lifecycle for all run kinds (mlperf, vllm_bench, pd_bench).

For mlperf kind, behavior is unchanged from v1: one mlperf_run.sh per GPU
group, output prefixed with [hostname], merged into one logical RunState.

For vllm_bench, we invoke scripts/vllm/vllm_run.sh which itself groups by
GPU type (one Ray-cluster + bench per group, in parallel).

For pd_bench, we invoke scripts/pd/pd_run.sh once per request (PD has a
single topology consisting of prefill + decode hosts).
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shlex
import time
import uuid
from dataclasses import asdict
from typing import Any, Dict, List, Optional, Tuple

from . import gpu_monitor
from .parser import parse_summary_line, parse_result_dir
from .state import HostState, LogLine, RunState, STATE, now

log = logging.getLogger("runner")

# In-process launcher registry.  These are the local subprocesses that the
# backend started for active runs.  They are intentionally not persisted because
# they cannot be reattached after a platform restart.
_ACTIVE_RUN_PROCS: Dict[str, List[asyncio.subprocess.Process]] = {}


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPTS_DIR = os.environ.get(
    "MLPERF_SCRIPTS_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")),
)
_DEFAULT_PLATFORM_ROOT = os.environ.get(
    "POC_PLATFORM_ROOT",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
)
MLPERF_ROOT = os.environ.get("MLPERF_ROOT", _DEFAULT_PLATFORM_ROOT)
DATA_ROOT = os.environ.get("MLPERF_DATA_ROOT", os.path.join(MLPERF_ROOT, "data"))

LOG_ROOTS = {
    ("training", "v4.1"): os.environ.get(
        "MLPERF_LOG_ROOT_TRAIN_V41",
        f"{MLPERF_ROOT}/mlperf_logs_train_v41"),
    ("training", "v5.1"): os.environ.get(
        "MLPERF_LOG_ROOT_TRAIN_V51",
        f"{MLPERF_ROOT}/mlperf_logs_train_v51"),
    ("inference", "v5.1"): os.environ.get(
        "MLPERF_LOG_ROOT_INFER_V51",
        f"{MLPERF_ROOT}/mlperf_logs_infer_v51"),
    ("inference", "v6.0"): os.environ.get(
        "MLPERF_LOG_ROOT_INFER_V60",
        f"{MLPERF_ROOT}/mlperf_logs_infer_v60"),
    ("vllm_bench", ""): os.environ.get(
        "VLLM_LOG_ROOT_BENCH",
        f"{MLPERF_ROOT}/vllm_logs_bench"),
    ("pd_bench", ""): os.environ.get(
        "PD_LOG_ROOT_BENCH",
        f"{MLPERF_ROOT}/vllm_logs_pd_bench"),
    ("llmd_bench", ""): os.environ.get(
        "LLMD_LOG_ROOT_BENCH",
        f"{MLPERF_ROOT}/llmd_logs_bench"),
}

def normalize_trainer_precision(value: Any) -> Any:
    """Map UI-friendly/legacy precision labels to Lightning-allowed values."""
    if value is None:
        return value
    raw = str(value).strip()
    if raw == "":
        return value
    mapping = {
        "FP64": "bf16-mixed",
        "64-true": "bf16-mixed",
        "64": "bf16-mixed",
        "FP32": "bf16-mixed",
        "32-true": "bf16-mixed",
        "32": "bf16-mixed",
        "FP16": "16-mixed",
        "16-true": "16-mixed",
        "FP16-mixed": "16-mixed",
        "fp16-mixed": "16-mixed",
        "16-mixed": "16-mixed",
        "16": "16-mixed",
        "BF16": "bf16",
        "bf16-true": "bf16",
        "BF16-mixed": "bf16-mixed",
        "bf16-mixed": "bf16-mixed",
        "bf16": "bf16",
        "FP8": "transformer-engine",
        "FP8_HYBRID": "transformer-engine",
        "transformer-engine": "transformer-engine",
        "transformer-engine-float16": "transformer-engine-float16",
    }
    return mapping.get(raw, raw)


def normalize_precision_args(args: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(args or {})
    raw_precision = str(out.get("TRAINER_PRECISION") or out.get("MLPERF_TRAINER_PRECISION") or "").strip()
    if raw_precision == "FP8":
        out["TRAINER_PRECISION"] = "transformer-engine"
        out["FP8"] = "True"
        out["FP8_HYBRID"] = "False"
    elif raw_precision == "FP8_HYBRID":
        out["TRAINER_PRECISION"] = "transformer-engine"
        out["FP8"] = "True"
        out["FP8_HYBRID"] = "True"
    else:
        for key in ("TRAINER_PRECISION", "MLPERF_TRAINER_PRECISION"):
            if key in out:
                out[key] = normalize_trainer_precision(out[key])
    if "MLPERF_TRAINER_PRECISION" not in out and "TRAINER_PRECISION" in out:
        out["MLPERF_TRAINER_PRECISION"] = out["TRAINER_PRECISION"]
    return out


# ---------------------------------------------------------------------------
# Line classification
# ---------------------------------------------------------------------------

_HOST_PREFIX = re.compile(r"^\[([A-Za-z0-9._\-]+)\]\s?(.*)$")
_PHASE_MARK = re.compile(r"^\[PHASE\]\s+(\S+)")
_LOG_DIR_MARK = re.compile(r"^(?:\[INFO\]\s+|\[platform\]\s+)log_dir=(\S+)")
_ERROR_MARK = re.compile(r"^\[ERROR\]\s+(.*)$")
_FATAL_MARK = re.compile(r"^\[FATAL\]\s+(.*)$")
_ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_FATAL_PAYLOAD_PATTERNS = [
    re.compile(r"torch\.OutOfMemoryError", re.IGNORECASE),
    re.compile(r"CUDA out of memory", re.IGNORECASE),
    re.compile(r"RuntimeError:\s*CUDA error", re.IGNORECASE),
]


def _looks_like_echoed_command(line: str) -> bool:
    """Return True for launcher command text, not runtime error output.

    We print the full docker/ssh command for debugging. That command can contain
    shell snippets such as `trap ... [CONTAINER][FATAL] command failed ...` and
    environment variable names such as `NCCL_DEBUG`. Those are not failures yet.
    Fatal detection must only react to actual runtime log lines.
    """
    s = (line or "").strip()
    if not s:
        return False
    command_prefixes = (
        "docker run ",
        "docker exec ",
        "ssh ",
        "bash -lc ",
        "+ docker run ",
        "+ ssh ",
    )
    if s.startswith(command_prefixes):
        return True
    command_markers = (
        " trap ",
        "trap '",
        "trap \"",
        "[CONTAINER][FATAL] command failed at line",
    )
    if any(m in s for m in command_markers):
        return True
    return False


def _is_fatal_payload(line: str) -> bool:
    s = line or ""
    stripped = s.strip()
    if _looks_like_echoed_command(stripped):
        return False

    if stripped.startswith(("[FATAL]", "[CONTAINER][FATAL]", "[platform][FATAL]")):
        return True

    if any(p.search(stripped) for p in _FATAL_PAYLOAD_PATTERNS):
        return True

    # NCCL WARN lines are often transient and MLPerf/NCCL may still finish
    # successfully. Do not turn warnings such as:
    #   NCCL WARN [Service thread] Accept failed Resource temporarily unavailable
    # into platform-level fatal failures. Only clear runtime error-level NCCL
    # messages should be fatal-detected here; final script exit code and
    # MLPerf_RESULT_JSON remain the source of truth for completion status.
    lower = stripped.lower()
    if "nccl" in lower and "nccl_" not in lower:
        if "warn" in lower and "error" not in lower and "unhandled" not in lower:
            return False
        if any(token in lower for token in (
            "nccl error",
            "nccl unhandled",
            "unhandled system error",
            "unhandled cuda error",
            "nccl failure",
            "nccl failed",
            "connection refused",
        )):
            return True

    return False


def _classify(line: str) -> str:
    if _ERROR_MARK.match(line) or _FATAL_MARK.match(line) or _is_fatal_payload(line):
        return "error"
    if line.startswith("[PHASE]"):
        return "phase"
    if line.startswith("[WARN]"):
        return "warn"
    return "info"


def _resolve_log_dir_from_marker(line: str) -> Optional[str]:
    m = _LOG_DIR_MARK.match(line)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# RunRequest
# ---------------------------------------------------------------------------


class RunRequest:
    """Validated launch parameters for any kind."""

    def __init__(self, *, kind: str, suite: str, version: str, gpu_type: str,
                 hosts: List[str], benchmark: Optional[str] = None,
                 dry_run: bool = False, docker_image: Optional[str] = None,
                 mlperf_root: Optional[str] = None,
                 data_root: Optional[str] = None,
                 log_root: Optional[str] = None,
                 config_path: Optional[str] = None,
                 node_gpu_map: Optional[Dict[str, str]] = None,
                 params: Optional[Dict[str, Any]] = None) -> None:
        self.kind = kind
        self.suite = suite
        self.version = version
        self.gpu_type = gpu_type
        self.hosts = hosts
        self.benchmark = benchmark
        self.dry_run = dry_run
        self.docker_image = docker_image
        self.mlperf_root = mlperf_root or MLPERF_ROOT
        self.data_root = data_root or DATA_ROOT
        self.log_root = log_root
        self.config_path = config_path
        self.node_gpu_map = node_gpu_map or {h: gpu_type for h in hosts}
        self.params = params or {}

    # ---- mlperf grouping ----

    def gpu_groups(self) -> Dict[str, List[str]]:
        groups: Dict[str, List[str]] = {}
        for h in self.hosts:
            host = str(h or "").strip()
            if not host or re.fullmatch(r"\d+", host):
                continue
            gt = str(self.node_gpu_map.get(host) or self.gpu_type or "H100").strip().upper()
            if gt not in {"V100", "A100", "H100", "GH200", "B300", "RTX6000", "RTX_PRO_6000"}:
                gt = "H100"
            groups.setdefault(gt, []).append(host)
        return groups

    def mlperf_args_for_host(self, host: str) -> Dict[str, Any]:
        """Return MLPerf advanced args for a single host.

        params.args remains the global/default argument set. params.args_by_host
        carries per-node overrides from the ADDED NODES table.  We merge them
        here because heterogeneous POC runs often need A100 8-GPU and GH200
        1-GPU nodes in the same logical run.
        """
        base = self.params.get("args") or {}
        by_host = self.params.get("args_by_host") or {}
        host_args = by_host.get(host) if isinstance(by_host, dict) else {}
        merged: Dict[str, Any] = dict(base) if isinstance(base, dict) else {}
        if isinstance(host_args, dict):
            merged.update(host_args)
        if self.suite == "training":
            merged = normalize_precision_args(merged)
            # Do not force MBS to 1. The UI can now set MBS explicitly;
            # scripts fall back to 1 when it is omitted.
            if not merged.get("MBS") and merged.get("MICRO_BATCH_SIZE"):
                merged["MBS"] = merged["MICRO_BATCH_SIZE"]
            if not merged.get("MICRO_BATCH_SIZE") and merged.get("MBS"):
                merged["MICRO_BATCH_SIZE"] = merged["MBS"]
            if merged.get("NUM_GPUS") and not merged.get("MLPERF_NUM_GPUS"):
                merged["MLPERF_NUM_GPUS"] = merged["NUM_GPUS"]
            # FP8 and FP8_HYBRID are distinct NeMo flags. Do not implicitly turn
            # on FP8_HYBRID just because FP8=True; leave it false unless selected.
            if merged.get("FP8") is not None and str(merged.get("FP8")).strip() != "" and not merged.get("FP8_HYBRID"):
                merged["FP8_HYBRID"] = "False"
        return merged

    # ---- command builders by kind ----

    def build_mlperf_cmd(self, run_id: str, hosts: List[str], gpu_type: str,
                         stop: bool = False) -> List[str]:
        script = os.path.join(SCRIPTS_DIR, "mlperf_run.sh")
        cmd = [script,
               "--run-id", run_id,
               "--suite", self.suite,
               "--version", self.version,
               "--gpu-type", gpu_type,
               "--hosts", ",".join(hosts),
               "--mlperf-root", self.mlperf_root,
               "--data-root", self.data_root]
        if self.benchmark:
            cmd += ["--benchmark", self.benchmark]
        if self.docker_image:
            cmd += ["--docker-image", self.docker_image]
        if self.log_root:
            cmd += ["--log-root", self.log_root]
        if self.config_path:
            cmd += ["--config", self.config_path]
        if self.dry_run:
            cmd += ["--dry-run"]
        if stop:
            cmd = [script, "--stop", "--run-id", run_id, "--suite", self.suite,
                   "--version", self.version, "--hosts", ",".join(hosts),
                   "--mlperf-root", self.mlperf_root, "--data-root", self.data_root]
            if self.benchmark:
                cmd += ["--benchmark", self.benchmark]
            if self.log_root:
                cmd += ["--log-root", self.log_root]
        return cmd

    def build_vllm_cmd(self, run_id: str, stop: bool = False) -> List[str]:
        script = os.path.join(SCRIPTS_DIR, "vllm", "vllm_run.sh")
        p = self.params
        cmd = [script,
               "--run-id", run_id,
               "--engine", p.get("engine", "vllm"),
               "--mlperf-root", self.mlperf_root,
               "--data-root", self.data_root]
        if p.get("model"):
            cmd += ["--model", str(p["model"])]
        if p.get("model_path"):
            cmd += ["--model-path", str(p["model_path"])]
        if p.get("bench_data"):
            cmd += ["--bench-data", str(p["bench_data"])]
        if p.get("bmt_host"):
            cmd += ["--bmt-host", str(p["bmt_host"])]
        # ---- topology / serve ----
        if p.get("mode"):
            cmd += ["--mode", str(p["mode"])]
        if p.get("vllm_port") is not None:
            cmd += ["--port", str(p["vllm_port"])]
        if p.get("ray_head_port") is not None:
            cmd += ["--ray-head-port", str(p["ray_head_port"])]
        if p.get("ray_worker_port") is not None:
            cmd += ["--ray-worker-port", str(p["ray_worker_port"])]
        if p.get("tp"):
            cmd += ["--tp", str(p["tp"])]
        if p.get("pp"):
            cmd += ["--pp", str(p["pp"])]
        if p.get("max_model_len") is not None:
            cmd += ["--max-model-len", str(p["max_model_len"])]
        if p.get("gpu_memory_utilization") is not None:
            cmd += ["--gpu-memory-utilization", str(p["gpu_memory_utilization"])]
        # ---- bench ----
        if p.get("num_prompts") is not None:
            cmd += ["--num-prompts", str(p["num_prompts"])]
        if p.get("request_rate") is not None:
            cmd += ["--request-rate", str(p["request_rate"])]
        if p.get("max_concurrency") is not None:
            cmd += ["--max-concurrency", str(p["max_concurrency"])]
        if p.get("dataset_path"):
            cmd += ["--dataset-path", str(p["dataset_path"])]
        if p.get("input_len") is not None:
            cmd += ["--input-len", str(p["input_len"])]
        if p.get("output_len") is not None:
            cmd += ["--output-len", str(p["output_len"])]
        # ---- misc ----
        if self.docker_image:
            cmd += ["--docker-image", self.docker_image]
        if self.log_root:
            cmd += ["--log-root", self.log_root]
        if p.get("extra_args"):
            cmd += ["--extra-args", str(p["extra_args"])]
        if p.get("extra_docker_args"):
            cmd += ["--extra-docker-args", str(p["extra_docker_args"])]
        if p.get("common_extra_args"):
            cmd += ["--common-extra-args", str(p["common_extra_args"])]
        if p.get("prefill_extra_args"):
            cmd += ["--prefill-extra-args", str(p["prefill_extra_args"])]
        if p.get("decode_extra_args"):
            cmd += ["--decode-extra-args", str(p["decode_extra_args"])]
        selected = p.get("selected_gpus_by_host") if isinstance(p, dict) else {}
        if isinstance(selected, dict):
            for host, visible in selected.items():
                if visible not in (None, ""):
                    cmd += ["--gpu-map", f"{host}={visible}"]
        if self.dry_run:
            cmd += ["--dry-run"]
        vllm_node_mode = str(p.get("node_mode") or p.get("mode") or "multi").lower()
        emitted_groups = 0
        if vllm_node_mode == "single":
            for h in self.hosts:
                host = str(h or "").strip()
                if not host or re.fullmatch(r"\d+", host):
                    continue
                gt = str(self.node_gpu_map.get(host) or self.gpu_type or "H100").strip().upper()
                if gt not in {"V100", "A100", "H100", "GH200", "B300", "RTX6000", "RTX_PRO_6000"}:
                    gt = "H100"
                cmd += ["--group", f"{gt}:{host}"]
                emitted_groups += 1
        else:
            for gt, hosts in self.gpu_groups().items():
                if not hosts:
                    continue
                cmd += ["--group", f"{gt}:{','.join(hosts)}"]
                emitted_groups += 1
        if emitted_groups == 0:
            raise ValueError("vllm_bench: no valid hostname available for --group")
        if stop:
            cmd = [script, "--stop", "--run-id", run_id,
                   "--engine", p.get("engine", "vllm"),
                   "--mlperf-root", self.mlperf_root,
                   "--data-root", self.data_root]
            if p.get("bmt_host"):
                cmd += ["--bmt-host", str(p["bmt_host"])]
            if p.get("mode"):
                cmd += ["--mode", str(p["mode"])]
            if self.log_root:
                cmd += ["--log-root", self.log_root]
            for gt, hosts in self.gpu_groups().items():
                cmd += ["--group", f"{gt}:{','.join(hosts)}"]
        return cmd

    def build_pd_cmd(self, run_id: str, stop: bool = False) -> List[str]:
        script = os.path.join(SCRIPTS_DIR, "pd", "pd_run.sh")
        p = self.params
        prefill = p.get("prefill_hosts") or []
        decode = p.get("decode_hosts") or []
        cmd = [script,
               "--run-id", run_id,
               "--engine", p.get("engine", "vllm"),
               "--gpu-type", self.gpu_type,
               "--prefill-hosts", ",".join(prefill),
               "--decode-hosts", ",".join(decode),
               "--mlperf-root", self.mlperf_root,
               "--data-root", self.data_root]
        if p.get("model"):
            cmd += ["--model", str(p["model"])]
        if p.get("model_path"):
            cmd += ["--model-path", str(p["model_path"])]
        if p.get("bench_data"):
            cmd += ["--bench-data", str(p["bench_data"])]
        if p.get("prefill_tp"):
            cmd += ["--prefill-tp", str(p["prefill_tp"])]
        if p.get("decode_tp"):
            cmd += ["--decode-tp", str(p["decode_tp"])]
        if p.get("prefill_instances"):
            cmd += ["--prefill-instances", str(p["prefill_instances"])]
        if p.get("decode_instances"):
            cmd += ["--decode-instances", str(p["decode_instances"])]
        if p.get("prefill_instance_specs"):
            cmd += ["--prefill-specs", str(p["prefill_instance_specs"])]
        if p.get("decode_instance_specs"):
            cmd += ["--decode-specs", str(p["decode_instance_specs"])]
        if p.get("proxy_port"):
            cmd += ["--proxy-port", str(p["proxy_port"])]
        if p.get("extra_docker_args"):
            cmd += ["--extra-docker-args", str(p["extra_docker_args"])]
        if p.get("prefill_extra_docker_args"):
            cmd += ["--prefill-extra-docker-args", str(p["prefill_extra_docker_args"])]
        if p.get("decode_extra_docker_args"):
            cmd += ["--decode-extra-docker-args", str(p["decode_extra_docker_args"])]
        if p.get("num_prompts") is not None:
            cmd += ["--num-prompts", str(p["num_prompts"])]
        if p.get("request_rate") is not None:
            cmd += ["--request-rate", str(p["request_rate"])]
        if p.get("max_model_len") is not None:
            cmd += ["--max-model-len", str(p["max_model_len"])]
        if self.docker_image:
            cmd += ["--docker-image", self.docker_image]
        if self.log_root:
            cmd += ["--log-root", self.log_root]
        if p.get("extra_args"):
            cmd += ["--extra-args", str(p["extra_args"])]
        if p.get("common_extra_args"):
            cmd += ["--common-extra-args", str(p["common_extra_args"])]
        if p.get("prefill_extra_args"):
            cmd += ["--prefill-extra-args", str(p["prefill_extra_args"])]
        if p.get("decode_extra_args"):
            cmd += ["--decode-extra-args", str(p["decode_extra_args"])]
        if self.dry_run:
            cmd += ["--dry-run"]
        if stop:
            cmd = [script, "--stop", "--run-id", run_id,
                   "--engine", p.get("engine", "vllm"),
                   "--gpu-type", self.gpu_type,
                   "--prefill-hosts", ",".join(prefill),
                   "--decode-hosts", ",".join(decode),
                   "--mlperf-root", self.mlperf_root,
                   "--data-root", self.data_root]
            if self.log_root:
                cmd += ["--log-root", self.log_root]
            if p.get("model"):
                cmd += ["--model", str(p["model"])]
            if p.get("model_path"):
                cmd += ["--model-path", str(p["model_path"])]
        return cmd

    def build_llmd_cmd(self, run_id: str, stop: bool = False) -> List[str]:
        """llm-d benchmark via guidellm against an already-deployed endpoint.

        The platform does NOT deploy llm-d (quickstart/Helm does that out of
        band). It resolves a target endpoint (decode pod IP, EPP service, or the
        update101 proxy), runs `guidellm benchmark` from the BMT host with the
        offline env + local --processor, and monitors GPU on the worker nodes.
        """
        script = os.path.join(SCRIPTS_DIR, "llmd", "llmd_run.sh")
        p = self.params
        mode = p.get("mode", "serve")
        cmd = [script,
               "--run-id", run_id,
               "--mode", mode,
               "--version", self.version,
               "--gpu-type", self.gpu_type,
               "--hosts", ",".join(self.hosts),
               "--mlperf-root", self.mlperf_root,
               "--data-root", self.data_root]
        if p.get("namespace"):
            cmd += ["--namespace", str(p["namespace"])]
        # endpoint resolution: pod | service | proxy | manual
        if p.get("endpoint_mode"):
            cmd += ["--endpoint-mode", str(p["endpoint_mode"])]
        if p.get("target"):
            cmd += ["--target", str(p["target"])]
        if p.get("proxy_url"):
            cmd += ["--proxy-url", str(p["proxy_url"])]
        # model + tokenizer
        if p.get("model"):
            cmd += ["--model", str(p["model"])]
        if p.get("processor"):
            cmd += ["--processor", str(p["processor"])]
        # guidellm knobs
        if p.get("profile"):
            cmd += ["--profile", str(p["profile"])]
        if p.get("max_seconds") is not None:
            cmd += ["--max-seconds", str(p["max_seconds"])]
        if p.get("prompt_tokens") is not None:
            cmd += ["--prompt-tokens", str(p["prompt_tokens"])]
        if p.get("output_tokens") is not None:
            cmd += ["--output-tokens", str(p["output_tokens"])]
        if p.get("rate") not in (None, ""):
            cmd += ["--rate", str(p["rate"])]
        if p.get("bmt_host"):
            cmd += ["--bmt-host", str(p["bmt_host"])]
        # endpoint-mode = deploy: topology-aware vLLM pod (auto/explicit GPU+NIC)
        if p.get("deploy_image"):
            cmd += ["--deploy-image", str(p["deploy_image"])]
        if p.get("deploy_node"):
            cmd += ["--deploy-node", str(p["deploy_node"])]
        if p.get("gpus"):
            cmd += ["--gpus", str(p["gpus"])]
        if p.get("gpu_count"):
            cmd += ["--gpu-count", str(p["gpu_count"])]
        if p.get("nics"):
            cmd += ["--nics", str(p["nics"])]
        if p.get("model_path"):
            cmd += ["--model-path", str(p["model_path"])]
        if p.get("max_model_len") is not None:
            cmd += ["--max-model-len", str(p["max_model_len"])]
        if p.get("tp"):
            cmd += ["--tp", str(p["tp"])]
        # CompileIQ is currently UI-only/reserved. Do not pass it to runtime scripts
        # until a rebuild-with-ACF workflow is implemented.
        if self.log_root:
            cmd += ["--log-root", self.log_root]
        if p.get("extra_args"):
            cmd += ["--extra-args", str(p["extra_args"])]
        if p.get("common_extra_args"):
            cmd += ["--common-extra-args", str(p["common_extra_args"])]
        if p.get("prefill_extra_args"):
            cmd += ["--prefill-extra-args", str(p["prefill_extra_args"])]
        if p.get("decode_extra_args"):
            cmd += ["--decode-extra-args", str(p["decode_extra_args"])]
        if self.dry_run:
            cmd += ["--dry-run"]
        if stop:
            cmd = [script, "--stop", "--run-id", run_id, "--mode", mode,
                   "--version", self.version, "--gpu-type", self.gpu_type,
                   "--hosts", ",".join(self.hosts),
                   "--mlperf-root", self.mlperf_root, "--data-root", self.data_root]
            if p.get("namespace"):
                cmd += ["--namespace", str(p["namespace"])]
            if self.log_root:
                cmd += ["--log-root", self.log_root]
        return cmd

    def build_mlperf_k8s_cmd(self, run_id: str, stop: bool = False) -> List[str]:
        """MLPerf training as a Kubernetes Job (topology-aware NIC binding)."""
        script = os.path.join(SCRIPTS_DIR, "training", "train_k8s.sh")
        p = self.params
        bench = self.benchmark or _default_benchmark("mlperf", "training", self.version)
        cmd = [script,
               "--run-id", run_id,
               "--version", self.version,
               "--benchmark", bench,
               "--gpu-type", self.gpu_type,
               "--nodes", ",".join(self.hosts),
               "--gpus-per-node", str(p.get("gpus_per_node", 8)),
               "--mlperf-root", self.mlperf_root,
               "--data-root", self.data_root]
        if p.get("namespace"):
            cmd += ["--namespace", str(p["namespace"])]
        if p.get("model_path"):
            cmd += ["--model-path", str(p["model_path"])]
        # MLPerf training contract: DATADIR (dataset), LOGDIR (output), CONT (image),
        # CONFIG (config_<sys>.sh sourced inside the container), ENTRY (default
        # ./run_and_time.sh), WORKDIR (e.g. /workspace/ft-llm).
        if p.get("datadir"):
            cmd += ["--datadir", str(p["datadir"])]
        if p.get("logdir"):
            cmd += ["--logdir", str(p["logdir"])]
        if p.get("config"):
            cmd += ["--config", str(p["config"])]
        if p.get("entry"):
            cmd += ["--entry", str(p["entry"])]
        if p.get("workdir"):
            cmd += ["--workdir", str(p["workdir"])]
        # CompileIQ is currently UI-only/reserved. Do not pass it to runtime scripts
        # until a rebuild-with-ACF workflow is implemented.
        if self.docker_image:
            cmd += ["--image", self.docker_image]
        # topology-aware NIC binding: 'auto' (derive from nvidia-smi topo on the
        # leader node) or an explicit comma list e.g. mlx5_0,mlx5_1
        cmd += ["--nic-bind", str(p.get("nic_bind", "auto"))]
        # training hyperparams forwarded verbatim as KEY=VAL env
        for k, v in (p.get("args") or {}).items():
            cmd += ["--env", f"{k}={v}"]
        if self.log_root:
            cmd += ["--log-root", self.log_root]
        if self.dry_run:
            cmd += ["--dry-run"]
        if stop:
            cmd = [script, "--stop", "--run-id", run_id, "--version", self.version,
                   "--nodes", ",".join(self.hosts)]
            if p.get("namespace"):
                cmd += ["--namespace", str(p["namespace"])]
        return cmd


def _default_benchmark(kind: str, suite: str, version: str) -> str:
    if kind == "mlperf":
        if suite == "training":
            return "llama2_70b_lora"
        return "llama2_70b"
    if kind == "vllm_bench":
        return "vllm_serve"
    if kind == "pd_bench":
        return "pd_serve"
    if kind == "llmd_bench":
        return "llmd_serve"
    return "unknown"


# ---------------------------------------------------------------------------
# Run launch
# ---------------------------------------------------------------------------


async def start_run(req: RunRequest) -> RunState:
    run_id = f"run_{int(time.time())}_{uuid.uuid4().hex[:6]}"
    benchmark = req.benchmark or _default_benchmark(req.kind, req.suite, req.version)
    display_gpu_type = req.gpu_type
    groups = req.gpu_groups()
    if len(set(groups.keys())) > 1:
        display_gpu_type = "MIXED"

    # Build the actual command list.
    # MLPerf uses one launcher per host so each node can receive its own
    # advanced args (NUM_GPUS/TP/PP/CP/GBS/FP8/etc.).  This is required for
    # heterogeneous runs such as A100 8-GPU + GH200 1-GPU in one logical run.
    cmd_entries: List[Tuple[List[str], Dict[str, Any], List[str]]] = []
    if req.kind == "mlperf":
        selected_gpus = req.params.get("selected_gpus_by_host") if isinstance(req.params, dict) else {}
        node_mode = str((req.params or {}).get("node_mode") or "single").lower()
        if req.suite == "training" and node_mode == "multi":
            extra = normalize_precision_args((req.params or {}).get("args") or {})
            extra["MLPERF_NODE_MODE"] = "multi"
            if isinstance(selected_gpus, dict) and selected_gpus:
                extra["MLPERF_CUDA_VISIBLE_DEVICES_BY_HOST"] = ";".join(
                    f"{h}={selected_gpus[h]}" for h in req.hosts if selected_gpus.get(h)
                )
            cmd_entries.append((
                req.build_mlperf_cmd(run_id, hosts=list(req.hosts), gpu_type=req.gpu_type),
                extra,
                list(req.hosts),
            ))
        else:
            for h in req.hosts:
                gt = req.node_gpu_map.get(h) or req.gpu_type
                extra = req.mlperf_args_for_host(h)
                if isinstance(selected_gpus, dict) and selected_gpus.get(h):
                    # Host-local comma-separated GPU indices selected by the UI after
                    # checking nvidia-smi memory/utilization.  The MLPerf wrapper
                    # forwards this to the remote host and target script.
                    extra = dict(extra)
                    extra["MLPERF_CUDA_VISIBLE_DEVICES"] = str(selected_gpus[h])
                cmd_entries.append((
                    req.build_mlperf_cmd(run_id, hosts=[h], gpu_type=gt),
                    extra,
                    [h],
                ))
    elif req.kind == "mlperf_k8s":
        # One launcher drives an in-cluster indexed Job across all GPU nodes.
        cmd_entries = [(req.build_mlperf_k8s_cmd(run_id), (req.params or {}).get("args") or {}, list(req.hosts))]
    elif req.kind == "vllm_bench":
        cmd_entries = [(req.build_vllm_cmd(run_id), (req.params or {}).get("args") or {}, list(req.hosts))]
    elif req.kind == "pd_bench":
        cmd_entries = [(req.build_pd_cmd(run_id), (req.params or {}).get("args") or {}, list(req.hosts))]
    elif req.kind == "llmd_bench":
        cmd_entries = [(req.build_llmd_cmd(run_id), (req.params or {}).get("args") or {}, list(req.hosts))]
    else:
        raise ValueError(f"unknown kind: {req.kind}")

    cmds = [entry[0] for entry in cmd_entries]
    cmd_for_state: List[str]
    if len(cmds) == 1:
        cmd_for_state = cmds[0]
    else:
        cmd_for_state = ["<multi-cmd>"] + [" ".join(shlex.quote(c) for c in cmd) for cmd in cmds]

    state = RunState(
        run_id=run_id,
        suite=req.suite,
        version=req.version,
        gpu_type=display_gpu_type,
        benchmark=benchmark,
        hosts=list(req.hosts),
        kind=req.kind,
        params=dict(req.params),
        node_gpu_map=dict(req.node_gpu_map),
        dry_run=req.dry_run,
        created_at=now(),
        cmd=cmd_for_state,
        status="running",
    )
    STATE.add_run(state)

    for h in req.hosts:
        gpu_monitor.acquire_host(h)
        state.host_states[h].status = "pending"
        state.host_states[h].started_at = now()

    STATE.push_log(state, LogLine(
        ts=now(), host="", level="phase",
        line=f"[platform] starting kind={req.kind} run_id={run_id} hosts={req.hosts}",
    ))

    procs: List[asyncio.subprocess.Process] = []
    for cmd, extra, entry_hosts in cmd_entries:
        log.info("launching %s: %s", req.kind, " ".join(shlex.quote(c) for c in cmd))
        STATE.push_log(state, LogLine(
            ts=now(), host="", level="phase",
            line=f"[platform] cmd={' '.join(shlex.quote(c) for c in cmd)}",
        ))

        # extra carries env-style advanced arguments. For MLPerf this is host
        # specific; for vLLM/PD it is the tab-level params.args.
        sub_env = {**os.environ, "PYTHONUNBUFFERED": "1"}
        if isinstance(extra, dict):
            for k, v in extra.items():
                if v is None or v == "":
                    continue
                sub_env[str(k)] = str(v)
            if extra:
                kvs = ", ".join(f"{k}={v}" for k, v in extra.items() if v not in (None, ""))
                if kvs:
                    host_label = ",".join(entry_hosts or [])
                    STATE.push_log(state, LogLine(
                        ts=now(), host="", level="info",
                        line=f"[platform] advanced args{f' for {host_label}' if host_label else ''}: {kvs}",
                    ))

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=sub_env,
            )
        except FileNotFoundError as e:
            msg = f"failed to spawn {req.kind} cmd: {e}"
            log.error(msg)
            STATE.push_log(state, LogLine(ts=now(), host="", level="error", line=msg))
            state.status = "failed"
            state.finished_at = now()
            for h in req.hosts:
                gpu_monitor.release_host(h)
            STATE.persist_runs()
            return state
        procs.append(proc)

    if procs:
        state.pid = procs[0].pid
        _ACTIVE_RUN_PROCS[run_id] = procs

    asyncio.create_task(_consume_all_streams(state, procs))
    return state


async def _consume_all_streams(run: RunState, procs: List[asyncio.subprocess.Process]) -> None:
    try:
        rcs = await asyncio.gather(*[_consume_one_stream(run, p, procs) for p in procs])
        rc = 0 if all(r == 0 for r in rcs) else next((r for r in rcs if r != 0), -1)
        await _finalize(run, rc)
    except asyncio.CancelledError:
        setattr(run, "_force_stopped", True)
        for p in procs:
            try:
                p.terminate()
            except ProcessLookupError:
                pass
        await _finalize(run, 130)
        raise
    except Exception as e:  # noqa: BLE001
        log.exception("multi-stream consumer crashed: %s", e)
        await _finalize(run, -1)
    finally:
        _ACTIVE_RUN_PROCS.pop(run.run_id, None)


def _clean_stream_segment(segment: str) -> str:
    """Normalize one subprocess output segment before storing it in the UI log.

    MLPerf/NeMo v4.1 progress bars are emitted via carriage returns (\r), not
    newline-terminated records.  The old reader used readline(), so those updates
    only appeared after a later newline or after the process finished.  We now
    split the byte stream on both \n and \r, then remove terminal control
    sequences so the web UI receives readable, near-real-time progress entries.
    """
    if not segment:
        return ""
    cleaned = segment.replace("\x00", "")
    cleaned = _ANSI_ESCAPE.sub("", cleaned)
    return cleaned.strip()


def _terminate_on_fatal(run: RunState, procs: Optional[List[asyncio.subprocess.Process]]) -> None:
    # Only a run-scoped fatal should terminate all local launcher processes.
    # Host-scoped fatals are isolated so that bare-metal single-node fan-out
    # runs keep the healthy hosts running even when one host fails.
    if not getattr(run, "_global_fatal_detected", False):
        return
    for p in (procs or []):
        if p.returncode is None:
            try:
                p.terminate()
            except ProcessLookupError:
                pass


async def _consume_one_stream(run: RunState, proc: asyncio.subprocess.Process,
                              all_procs: Optional[List[asyncio.subprocess.Process]] = None) -> int:
    assert proc.stdout is not None
    buffer = ""
    while True:
        raw = await proc.stdout.read(4096)
        if not raw:
            break

        text = buffer + raw.decode("utf-8", errors="replace")
        text = text.replace("\r\n", "\n")
        has_trailing_delim = text.endswith(("\n", "\r"))
        parts = re.split(r"[\r\n]", text)
        complete = parts if has_trailing_delim else parts[:-1]
        buffer = "" if has_trailing_delim else (parts[-1] if parts else "")

        for part in complete:
            line = _clean_stream_segment(part)
            if not line:
                continue
            _process_line(run, line)
            _terminate_on_fatal(run, all_procs or [proc])

    tail = _clean_stream_segment(buffer)
    if tail:
        _process_line(run, tail)
        _terminate_on_fatal(run, all_procs or [proc])
    return await proc.wait()


def _process_line(run: RunState, line: str) -> None:
    host = ""
    payload = line

    m = _HOST_PREFIX.match(line)
    if m:
        host = m.group(1)
        payload = m.group(2)

    level = _classify(payload)

    summary = parse_summary_line(payload)
    if summary is not None:
        h = summary.get("host", host) or host
        if h and h in run.host_states:
            hs = run.host_states[h]
            hs.result_summary = summary
            status = summary.get("status", "")
            if status == "success":
                hs.status = "success"
                # A valid success summary from the launcher is authoritative for
                # this host. This prevents earlier warning-level log noise from
                # leaving stale failure state behind.
                if getattr(run, "_fatal_detected", False) and hs.result_error == payload:
                    hs.result_error = ""
            elif status == "failed":
                hs.status = "failed"
            elif status == "stopped":
                hs.status = "stopped"
            else:
                hs.status = status or hs.status
            try:
                hs.exit_code = int(summary.get("exit_code", hs.exit_code or 0))
            except (TypeError, ValueError):
                hs.exit_code = hs.exit_code or 0
            hs.ended_at = now()
            if "log_dir" in summary:
                hs.log_dir = summary["log_dir"]
            if "docker_container" in summary:
                hs.container_name = summary["docker_container"]
    else:
        pm = _PHASE_MARK.match(payload)
        if pm and host and host in run.host_states:
            run.host_states[host].phase = pm.group(1)
            if pm.group(1) == "validate":
                run.host_states[host].status = "running"

        ld = _resolve_log_dir_from_marker(payload)
        if ld:
            if host and host in run.host_states:
                run.host_states[host].log_dir = ld
            elif len(run.host_states) == 1:
                next(iter(run.host_states.values())).log_dir = ld
            else:
                for _hs in run.host_states.values():
                    if not _hs.log_dir:
                        _hs.log_dir = ld

        if _ERROR_MARK.match(payload) and host and host in run.host_states:
            hs = run.host_states[host]
            if hs.status not in ("failed", "success", "stopped"):
                hs.status = "error"

        if _is_fatal_payload(payload):
            if host and host in run.host_states:
                hs = run.host_states[host]
                if hs.status not in ("success", "stopped"):
                    hs.status = "failed"
                    hs.result_error = payload
                    hs.ended_at = now()
                fatal_hosts = getattr(run, "_fatal_hosts", set())
                try:
                    fatal_hosts.add(host)
                    setattr(run, "_fatal_hosts", fatal_hosts)
                except Exception:
                    pass
                run.status = "partial" if any(
                    h != host and other_hs.status in ("pending", "running", "success", "error")
                    for h, other_hs in run.host_states.items()
                ) else "failed"
                if not getattr(run, f"_fatal_log_emitted_{host}", False):
                    setattr(run, f"_fatal_log_emitted_{host}", True)
                    STATE.push_log(run, LogLine(
                        ts=now(), host=host, level="error",
                        line=f"[platform][ERROR] fatal log pattern detected on {host}; keeping other host launcher processes running: {payload[:240]}",
                    ))
            else:
                for other_hs in run.host_states.values():
                    if other_hs.status in ("pending", "running", "error"):
                        other_hs.status = "failed"
                        other_hs.result_error = payload
                        other_hs.ended_at = now()
                run.status = "failed"
                setattr(run, "_global_fatal_detected", True)
                if not getattr(run, "_fatal_log_emitted", False):
                    setattr(run, "_fatal_log_emitted", True)
                    STATE.push_log(run, LogLine(
                        ts=now(), host="", level="error",
                        line=f"[platform][ERROR] run-scoped fatal log pattern detected; terminating local launcher processes and marking run failed: {payload[:240]}",
                    ))

    STATE.push_log(run, LogLine(ts=now(), host=host, level=level, line=payload))


def _result_suite_for_parser(run: RunState) -> str:
    """Return the suite tag the parser should use given the run kind."""
    if run.kind in ("vllm_bench", "pd_bench", "llmd_bench"):
        return run.kind
    return run.suite


async def _finalize(run: RunState, rc: int) -> None:
    run.finished_at = now()

    forced_stop = bool(getattr(run, "_force_stopped", False))
    statuses = []
    for h, hs in run.host_states.items():
        if hs.status in ("pending", "running"):
            hs.status = "stopped" if forced_stop else ("success" if rc == 0 else "failed")
            hs.exit_code = rc
            hs.ended_at = now()

        try:
            metrics, perr = parse_result_dir(hs.log_dir, run.suite, run.kind)
            hs.result_metrics = metrics
            if perr and not hs.result_error:
                hs.result_error = perr
        except Exception as e:  # noqa: BLE001
            if not hs.result_error:
                hs.result_error = f"{type(e).__name__}: {e}"

        if hs.status in ("failed", "error") and not hs.result_error:
            hs.result_error = f"launcher exited with code {rc}"

        statuses.append(hs.status)
        gpu_monitor.release_host(h)

    if forced_stop:
        run.status = "stopped"
    elif any(s in ("failed", "error") for s in statuses):
        run.status = "partial" if any(s == "success" for s in statuses) else "failed"
    elif all(s == "success" for s in statuses):
        run.status = "success"
    elif all(s == "stopped" for s in statuses):
        run.status = "stopped"
    elif any(s == "success" for s in statuses):
        run.status = "partial"
    elif any(s == "stopped" for s in statuses):
        run.status = "stopped"
    else:
        run.status = "failed"

    STATE.push_log(run, LogLine(
        ts=now(), host="", level="phase",
        line=f"[platform] run finished: status={run.status} exit_code={rc}",
    ))
    STATE.persist_runs()


async def stop_active_runs_for_shutdown() -> None:
    """Terminate backend-owned launchers and persist all active runs as stopped.

    This is used by FastAPI shutdown so replacing/stopping the platform does not
    leave UI state that still says running.  The platform can only manage the
    subprocesses it owns in the current backend process; persisted active runs
    from older processes are handled as stopped during state restore.
    """
    active = [r for r in STATE.runs.values() if str(r.status or "").lower() in {"pending", "running", "partial"}]
    for run in active:
        setattr(run, "_force_stopped", True)
        STATE.push_log(run, LogLine(
            ts=now(), host="", level="phase",
            line="[platform] shutdown requested; terminating launcher processes and marking run stopped",
        ))
        for p in list(_ACTIVE_RUN_PROCS.get(run.run_id, []) or []):
            if p.returncode is None:
                try:
                    p.terminate()
                except ProcessLookupError:
                    pass
        await asyncio.sleep(0.2)
        for p in list(_ACTIVE_RUN_PROCS.get(run.run_id, []) or []):
            if p.returncode is None:
                try:
                    p.kill()
                except ProcessLookupError:
                    pass
        ended = now()
        run.status = "stopped"
        run.finished_at = run.finished_at or ended
        for hs in run.host_states.values():
            if hs.status not in ("success", "failed", "stopped", "error"):
                hs.status = "stopped"
                hs.exit_code = hs.exit_code if hs.exit_code is not None else 130
                hs.ended_at = hs.ended_at or ended
            gpu_monitor.release_host(hs.host)
    if active:
        STATE.persist_runs()


# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------


async def stop_hosts(run: RunState, hosts: List[str]) -> Tuple[int, str]:
    bad = [h for h in hosts if h not in run.host_states]
    if bad:
        return 2, f"unknown host(s): {bad}"

    if run.finished_at or run.status in ("success", "failed", "partial", "stopped"):
        return 0, "run already finished"

    # Build kind-specific stop command.
    req = RunRequest(
        kind=run.kind,
        suite=run.suite, version=run.version, gpu_type=run.gpu_type,
        hosts=hosts, benchmark=run.benchmark,
        node_gpu_map={h: run.node_gpu_map.get(h, run.gpu_type) for h in hosts},
        params=dict(run.params),
        log_root=LOG_ROOTS.get((run.suite, run.version)) or LOG_ROOTS.get((run.kind, "")),
    )
    if run.kind == "mlperf":
        groups = req.gpu_groups()
        # one stop subprocess per group is fine; we'll merge their stdout
        cmds = [req.build_mlperf_cmd(run.run_id, hosts=hs, gpu_type=gt, stop=True)
                for gt, hs in groups.items()]
    elif run.kind == "vllm_bench":
        cmds = [req.build_vllm_cmd(run.run_id, stop=True)]
    elif run.kind == "pd_bench":
        cmds = [req.build_pd_cmd(run.run_id, stop=True)]
    elif run.kind == "llmd_bench":
        cmds = [req.build_llmd_cmd(run.run_id, stop=True)]
    elif run.kind == "mlperf_k8s":
        cmds = [req.build_mlperf_k8s_cmd(run.run_id, stop=True)]
    else:
        return 2, f"unknown kind: {run.kind}"

    STATE.push_log(run, LogLine(
        ts=now(), host="", level="phase",
        line=f"[platform] stopping hosts={hosts} ({run.kind})",
    ))

    rcs: List[int] = []
    out_lines: List[str] = []
    for cmd in cmds:
        log.info("stop: %s", " ".join(shlex.quote(c) for c in cmd))
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except FileNotFoundError as e:
            return 127, str(e)

        assert proc.stdout is not None
        while True:
            raw = await proc.stdout.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").rstrip("\n")
            out_lines.append(line)
            m = _HOST_PREFIX.match(line)
            host = m.group(1) if m else ""
            payload = m.group(2) if m else line
            STATE.push_log(run, LogLine(ts=now(), host=host, level="info",
                                        line=f"[stop] {payload}"))
        rcs.append(await proc.wait())

    rc = 0 if all(r == 0 for r in rcs) else next((r for r in rcs if r != 0), -1)

    for h in hosts:
        hs = run.host_states[h]
        if hs.status in ("pending", "running", "error"):
            hs.status = "stopped"
            hs.ended_at = now()

    STATE.persist_runs()
    return rc, "\n".join(out_lines[-20:])




def _node_gpu_map_with_sample_fallback(run: RunState) -> Dict[str, str]:
    """Return node_gpu_map corrected from recorded GPU sample names when possible."""
    out = dict(getattr(run, "node_gpu_map", {}) or {})
    for host in getattr(run, "hosts", []) or []:
        detected = None
        samples = list((getattr(run, "gpu_samples", {}) or {}).get(host) or [])
        for sample in reversed(samples):
            per_gpu = (sample or {}).get("per_gpu") or []
            names = [str(g.get("name") or "") for g in per_gpu if isinstance(g, dict) and g.get("name")]
            types = sorted({gpu_monitor.canonical_gpu_type(n) for n in names if gpu_monitor.canonical_gpu_type(n) != "UNKNOWN"})
            if len(types) == 1:
                detected = types[0]
                break
        if detected:
            out[host] = detected
        elif host not in out and getattr(run, "gpu_type", None):
            out[host] = run.gpu_type
    return out


def _display_gpu_type_for_snapshot(run: RunState, node_map: Dict[str, str]) -> str:
    values = sorted({str(v) for v in (node_map or {}).values() if v and str(v) != "UNKNOWN"})
    if len(values) == 1:
        return values[0]
    if len(values) > 1:
        return "MIXED"
    return getattr(run, "gpu_type", "") or "UNKNOWN"

# ---------------------------------------------------------------------------
# Snapshot helpers
# ---------------------------------------------------------------------------


def run_snapshot(run: RunState) -> Dict:
    node_gpu_map = _node_gpu_map_with_sample_fallback(run)
    gpu_type = _display_gpu_type_for_snapshot(run, node_gpu_map)
    return {
        "run_id": run.run_id,
        "kind": run.kind,
        "suite": run.suite,
        "version": run.version,
        "gpu_type": gpu_type,
        "benchmark": run.benchmark,
        "hosts": run.hosts,
        "node_gpu_map": node_gpu_map,
        "params": getattr(run, "params", {}),
        "status": run.status,
        "dry_run": run.dry_run,
        "created_at": run.created_at,
        "finished_at": run.finished_at,
        "pid": run.pid,
        "host_states": {h: host_snapshot(hs) for h, hs in run.host_states.items()},
    }


def host_snapshot(hs: HostState) -> Dict:
    return asdict(hs)
