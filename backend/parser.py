"""
parser.py
---------
Result parsing for all run kinds.

Three line prefixes are recognized:
  MLPerf_RESULT_JSON={...}        - mlperf_train_*.sh / mlperf_infer_*.sh
  VLLM_BENCH_RESULT_JSON={...}    - vllm/vllm_bench.sh / vllm/sglang_bench.sh
  PD_BENCH_RESULT_JSON={...}      - pd/pd_serve_*.sh

After a run completes the platform also tries to load a per-kind result file
from ${log_dir}/results/.  Mapping:
  mlperf inference  -> mlperf_log_summary.txt (LoadGen)
  mlperf training   -> result*.txt / training.log / run.log (best-effort)
  vllm_bench        -> bench_serving.json
  pd_bench          -> pd_bench_serving.json
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Callable, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# 1) Summary line parser
# ---------------------------------------------------------------------------

_PREFIXES = {
    "MLPerf_RESULT_JSON=":      "mlperf",
    "VLLM_BENCH_RESULT_JSON=":  "vllm_bench",
    "PD_BENCH_RESULT_JSON=":    "pd_bench",
    "LLMD_BENCH_RESULT_JSON=":  "llmd_bench",
}


def parse_summary_line(line: str) -> Optional[Dict[str, Any]]:
    """Return parsed dict if line carries one of the supported result prefixes."""
    for pfx, kind in _PREFIXES.items():
        idx = line.find(pfx)
        if idx < 0:
            continue
        payload = line[idx + len(pfx):].strip()
        if not payload.startswith("{"):
            return None
        end = payload.rfind("}")
        if end < 0:
            return None
        try:
            d = json.loads(payload[: end + 1])
        except json.JSONDecodeError:
            return None
        # Stamp the kind so downstream code knows the schema.
        d.setdefault("_kind", kind)
        return d
    return None


# ---------------------------------------------------------------------------
# 2) MLPerf result_dir parsers (LoadGen + training stdout)
# ---------------------------------------------------------------------------

_LG_KEYS = [
    ("samples_per_second", r"Samples per second\s*:\s*([0-9.eE+\-]+)"),
    ("tokens_per_second", r"Tokens per second\s*:\s*([0-9.eE+\-]+)"),
    ("completed_samples_per_second",
     r"Completed samples per second\s*:\s*([0-9.eE+\-]+)"),
    ("completed_tokens_per_second",
     r"Completed tokens per second\s*:\s*([0-9.eE+\-]+)"),
    ("ttft_mean_ns", r"Mean First Token latency \(ns\)\s*:\s*([0-9.eE+\-]+)"),
    ("ttft_p99_ns", r"99\.00 percentile first token latency \(ns\)\s*:\s*([0-9.eE+\-]+)"),
    ("tpot_mean_ns", r"Mean Time to Output Token \(ns\)\s*:\s*([0-9.eE+\-]+)"),
    ("tpot_p99_ns", r"99\.00 percentile time to output token \(ns\)\s*:\s*([0-9.eE+\-]+)"),
    ("e2e_mean_ns", r"Mean latency \(ns\)\s*:\s*([0-9.eE+\-]+)"),
    ("e2e_p99_ns", r"99\.00 percentile latency \(ns\)\s*:\s*([0-9.eE+\-]+)"),
    ("min_duration_ms", r"min_duration_ms\s*:\s*([0-9.eE+\-]+)"),
]

_LG_VALIDITY = re.compile(r"Result is\s*:\s*(VALID|INVALID)", re.IGNORECASE)
_LG_SCENARIO = re.compile(r"Scenario\s*:\s*([A-Za-z]+)")
_LG_MODE = re.compile(r"Mode\s*:\s*([A-Za-z ]+)")


def _parse_loadgen_summary(path: str) -> Dict[str, Any]:
    with open(path, "r", errors="replace") as f:
        text = f.read()

    out: Dict[str, Any] = {"_source": os.path.basename(path), "kind": "inference"}
    for key, pattern in _LG_KEYS:
        m = re.search(pattern, text)
        if m:
            try:
                out[key] = float(m.group(1))
            except ValueError:
                out[key] = m.group(1)

    m = _LG_VALIDITY.search(text)
    if m:
        out["validity"] = m.group(1).upper()
    m = _LG_SCENARIO.search(text)
    if m:
        out["scenario"] = m.group(1)
    m = _LG_MODE.search(text)
    if m:
        out["mode"] = m.group(1).strip()

    out["metric_display"] = _metric_display({k: v for k, v in out.items()
                                            if isinstance(v, (int, float))})
    return out


MLPERF_PARSED_METRIC_KEYS = {
    "train_loss", "train_step_time", "eval_accuracy", "validation_time",
    "step", "samples_count", "eval_samples", "global_batch_size", "duration_sec",
}

_TPS_PATTERNS = [
    re.compile(r"samples?[_/]?sec(?:ond)?[^=:\d]*[=:]?\s*([0-9.eE+\-]+)", re.IGNORECASE),
    re.compile(r"tokens?[_/]?sec(?:ond)?[^=:\d]*[=:]?\s*([0-9.eE+\-]+)", re.IGNORECASE),
    re.compile(r"throughput[^=:\d]*[=:]?\s*([0-9.eE+\-]+)", re.IGNORECASE),
]
_LOSS_PATTERN = re.compile(r"\bloss\s*[:=]\s*([0-9.eE+\-]+)", re.IGNORECASE)
# PyTorch Lightning / tqdm progress bars in MLPerf Training v4.1 commonly emit
# compact key-value text instead of JSON/MLLOG, for example:
#   Epoch 0: ... reduced_train_loss=3.720, global_step=1.000, consumed_samples=256.0
# Parse those lines so result analysis and dashboards still receive the last
# training loss after the run completes, and during live-log fallback.
_TRAIN_PROGRESS_KV_PATTERN = re.compile(
    r"\b(reduced_train_loss|train_loss|training_loss|lm_loss|loss|global_step|step|consumed_samples|samples_count)\s*[=:]\s*([0-9.eE+\-]+)",
    re.IGNORECASE,
)
_TRAIN_PROGRESS_COUNTER_PATTERN = re.compile(r"\|\s*(\d+)\s*/\s*(\d+)\s*\[")
_ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_TRAIN_LOSS_KEYS = {"loss", "train_loss", "training_loss", "lm_loss", "reduced_train_loss"}

def _normalize_training_metric_key(key: Any) -> str:
    k = str(key or "").strip()
    lk = k.lower()
    if lk in _TRAIN_LOSS_KEYS:
        return "train_loss"
    if lk == "global_step":
        return "step"
    if lk == "consumed_samples":
        return "samples_count"
    return k


def _store_training_metric(metric_values: Dict[str, Any], key: Any, value: Any) -> None:
    nk = _normalize_training_metric_key(key)
    num = _as_number(value)
    if num is not None:
        metric_values[nk] = int(num) if float(num).is_integer() else num
    else:
        metric_values[nk] = value


def _parse_training_progress_text(line: str, metric_values: Dict[str, Any]) -> None:
    clean = _ANSI_ESCAPE_PATTERN.sub("", str(line or ""))
    saw_step = False
    for m in _TRAIN_PROGRESS_KV_PATTERN.finditer(clean):
        key = m.group(1)
        if key.lower() == "reduced_train_loss" and metric_values.get("_official_train_loss_seen"):
            # tqdm can repaint a rounded reduced_train_loss after MLLOG emits
            # the final official train_loss. Keep the official value.
            continue
        _store_training_metric(metric_values, key, m.group(2))
        if key.lower() in {"global_step", "step"}:
            saw_step = True

    # If tqdm did not expose global_step, use the visible progress counter
    # (e.g. "| 2/10 [") as a best-effort current step.
    if not saw_step and "step" not in metric_values:
        m = _TRAIN_PROGRESS_COUNTER_PATTERN.search(clean)
        if m:
            try:
                metric_values["step"] = int(m.group(1))
            except ValueError:
                pass

_PPL_PATTERN = re.compile(r"\b(?:ppl|perplexity)\s*[:=]\s*([0-9.eE+\-]+)", re.IGNORECASE)
_MLLOG_LINE = re.compile(r":::MLLOG\s+(\{.*\})\s*$")


def _iter_mllog_events(text: str):
    """Yield every MLPerf :::MLLOG JSON event from raw stdout text.

    NeMo/Lightning progress bars often use carriage returns (\r), so run.log can
    contain progress-bar text and one or more :::MLLOG JSON payloads in the same
    physical line.  A line-end regex misses those embedded events.  Use
    JSONDecoder.raw_decode from each :::MLLOG marker instead.
    """
    dec = json.JSONDecoder()
    pos = 0
    while True:
        marker = text.find(":::MLLOG", pos)
        if marker < 0:
            break
        start = text.find("{", marker)
        if start < 0:
            break
        try:
            ev, end = dec.raw_decode(text[start:])
        except json.JSONDecodeError:
            pos = marker + len(":::MLLOG")
            continue
        if isinstance(ev, dict):
            yield ev
        pos = start + max(end, 1)


def _apply_training_mllog_event(ev: Dict[str, Any], metric_values: Dict[str, Any]) -> Tuple[bool, bool]:
    """Apply one MLLOG event. Returns (run_stop_seen, target_quality_seen)."""
    key = ev.get("key") or ev.get("event")
    value = ev.get("value")
    meta = ev.get("metadata") or {}
    run_stop_seen = False
    target_quality_seen = False

    if isinstance(value, dict):
        for k, v in value.items():
            if isinstance(v, (dict, list)):
                continue
            _store_training_metric(metric_values, k, v)
    elif key:
        num = _as_number(value)
        if num is not None:
            _store_training_metric(metric_values, key, value)
        elif isinstance(value, str):
            _store_training_metric(metric_values, key, value)
        if str(key).strip().lower() == "train_loss":
            # Prefer the official MLLOG train_loss over later rounded tqdm
            # reduced_train_loss repaint entries.
            metric_values["_official_train_loss_seen"] = True

    if isinstance(meta, dict):
        for mk in ("step", "step_num", "samples_count", "eval_samples", "global_batch_size"):
            if mk in meta:
                num = _as_number(meta.get(mk))
                metric_values[mk] = (
                    int(num) if num is not None and float(num).is_integer()
                    else (num if num is not None else meta.get(mk))
                )

    if key == "eval_accuracy" and isinstance(meta, dict) and "samples_count" in meta:
        # For MLPerf logs, eval_samples is observed from evaluation metadata,
        # not a user-provided hyperparameter.
        num = _as_number(meta.get("samples_count"))
        metric_values["eval_samples"] = int(num) if num is not None and float(num).is_integer() else (num if num is not None else meta.get("samples_count"))

    if key == "run_stop":
        run_stop_seen = True
        if isinstance(meta, dict) and "status" in meta:
            metric_values["run_stop_status"] = meta.get("status")
    if key == "target_log_perplexity_reached":
        target_quality_seen = True
        metric_values["target_quality_seen"] = True
    return run_stop_seen, target_quality_seen


def _parse_training_text(text: str) -> Tuple[Dict[str, Any], bool, bool]:
    metric_values: Dict[str, Any] = {}
    run_stop_seen = False
    target_quality_seen = False

    # Preserve chronological order across both newline and carriage-return progress
    # updates.  Each segment can still contain an embedded MLLOG payload.
    for segment in re.split(r"[\r\n]+", str(text or "")):
        if not segment:
            continue
        for ev in _iter_mllog_events(segment):
            rs, tq = _apply_training_mllog_event(ev, metric_values)
            run_stop_seen = run_stop_seen or rs
            target_quality_seen = target_quality_seen or tq

        # Also parse tqdm/Lightning text, e.g. reduced_train_loss/global_step.
        _parse_training_progress_text(segment, metric_values)

        for pat in _TPS_PATTERNS:
            m = pat.search(segment)
            if m:
                try:
                    metric_values["samples_per_second"] = float(m.group(1))
                except ValueError:
                    pass
                break

        m = _LOSS_PATTERN.search(segment)
        if m:
            try:
                metric_values["train_loss"] = float(m.group(1))
            except ValueError:
                pass

        m = _PPL_PATTERN.search(segment)
        if m:
            try:
                metric_values["perplexity"] = float(m.group(1))
            except ValueError:
                pass

    return metric_values, run_stop_seen, target_quality_seen


def _parse_training_log(path: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {"_source": os.path.basename(path), "kind": "training"}
    with open(path, "r", errors="replace") as f:
        text = f.read()

    metric_values, run_stop_seen, target_quality_seen = _parse_training_text(text)

    # MLPerf result-analysis intentionally exposes only the metrics used by the dashboard.
    metric_values = {k: v for k, v in metric_values.items() if k in MLPERF_PARSED_METRIC_KEYS}
    out["metric_values"] = metric_values
    out["metric_display"] = _metric_display(metric_values, priority=[
        "train_loss", "train_step_time", "eval_accuracy", "validation_time",
        "step", "samples_count", "eval_samples", "global_batch_size", "duration_sec",
    ])
    out["run_stop_seen"] = run_stop_seen
    out["target_quality_seen"] = target_quality_seen
    # Backward-compatible aliases for older result-table code, but dashboard pinning
    # removes convergence_step and prefers train_loss.
    if "train_loss" in metric_values:
        out["train_loss"] = metric_values["train_loss"]
    if "train_step_time" in metric_values:
        out["train_step_time"] = metric_values["train_step_time"]
    if "eval_accuracy" in metric_values:
        out["eval_accuracy"] = metric_values["eval_accuracy"]
    if "validation_time" in metric_values:
        out["validation_time"] = metric_values["validation_time"]
    if "samples_per_second" in metric_values:
        out["samples_per_second"] = metric_values["samples_per_second"]
    return out

# ---------------------------------------------------------------------------
# 3) vLLM bench / PD bench result_dir parser
# ---------------------------------------------------------------------------

# vLLM's `vllm bench serve --save-result` writes a JSON like:
# {
#   "model_id": "...", "num_prompts": 200,
#   "request_throughput": 23.45, "output_throughput": 1234.5,
#   "mean_ttft_ms": 30, "median_ttft_ms": 27, "p99_ttft_ms": 80,
#   "mean_tpot_ms": 12, "median_tpot_ms": 11, "p99_tpot_ms": 30,
#   "mean_e2e_ms": ..., "p99_e2e_ms": ..., ...
# }
# We surface the most useful subset.

_VLLM_BENCH_KEYS = [
    "request_throughput",
    "output_throughput",
    "output_token_throughput",
    "mean_ttft_ms",
    "median_ttft_ms",
    "p99_ttft_ms",
    "mean_tpot_ms",
    "median_tpot_ms",
    "p99_tpot_ms",
    "mean_e2e_ms",
    "p99_e2e_ms",
    "completed",
    "successful_requests",
    "total_input_tokens",
    "total_output_tokens",
    "duration",
]


def _parse_guidellm_json(path: str) -> Dict[str, Any]:
    """Defensively parse a guidellm `--output-path` JSON report.

    guidellm's schema varies by version and nests stats deeply (often
    benchmark.metrics.<metric>.successful.mean), and `sweep` emits many
    benchmarks. We walk defensively: for each benchmark pick headline metrics
    by token match, then keep the benchmark with the highest output throughput.
    """
    with open(path, "r", errors="replace") as f:
        data = json.load(f)

    # locate the list of benchmark objects
    benches = None
    if isinstance(data, list):
        benches = data
    elif isinstance(data, dict):
        for key in ("benchmarks", "results", "runs"):
            if isinstance(data.get(key), list):
                benches = data[key]; break
        if benches is None:
            benches = [data]
    if not benches:
        return {}

    # metric token -> output key; we prefer the mean of "successful" requests.
    # Aligned with guidellm's GenerativeBenchmark.metrics fields:
    #   output_tokens_per_second, tokens_per_second, requests_per_second,
    #   time_to_first_token_ms, inter_token_latency_ms,
    #   time_per_output_token_ms, request_latency,
    #   prompt_token_count, output_token_count
    # (see github.com/vllm-project/guidellm src/guidellm/benchmark/schemas/)
    METRIC_TOKENS = {
        "output_tokens_per_second": "output_tokens_per_second",
        "output_token_throughput": "output_tokens_per_second",
        "tokens_per_second": "tokens_per_second",
        "requests_per_second": "requests_per_second",
        "request_throughput": "requests_per_second",
        "time_to_first_token": "ttft_ms",
        "ttft": "ttft_ms",
        "inter_token_latency": "itl_ms",
        "time_per_output_token": "tpot_ms",
        "tpot": "tpot_ms",
        "request_latency": "request_latency_ms",
        "prompt_token_count": "prompt_tokens",
        "input_token_count": "prompt_tokens",
        "output_token_count": "output_tokens",
    }

    def find_mean(node: Any) -> Optional[float]:
        """Pull a representative number out of a stats node."""
        if isinstance(node, (int, float)) and not isinstance(node, bool):
            return float(node)
        if isinstance(node, dict):
            for pref in ("successful", "total", "complete"):
                if isinstance(node.get(pref), dict) and "mean" in node[pref]:
                    v = node[pref]["mean"]
                    if isinstance(v, (int, float)): return float(v)
            if "mean" in node and isinstance(node["mean"], (int, float)):
                return float(node["mean"])
            if "value" in node and isinstance(node["value"], (int, float)):
                return float(node["value"])
        return None

    def extract(bench: Dict[str, Any]) -> Dict[str, float]:
        flat: Dict[str, float] = {}
        metrics = bench.get("metrics") if isinstance(bench, dict) else None
        scope = metrics if isinstance(metrics, dict) else bench
        if not isinstance(scope, dict):
            return flat
        for mkey, mval in scope.items():
            lk = str(mkey).lower()
            for tok, out_key in METRIC_TOKENS.items():
                if tok in lk:
                    v = find_mean(mval)
                    if v is not None and out_key not in flat:
                        flat[out_key] = v
                    break
        return flat

    best: Dict[str, float] = {}
    best_score = -1.0
    sweep_points: List[Dict[str, Any]] = []
    for b in benches:
        if not isinstance(b, dict):
            continue
        flat = extract(b)
        if not flat:
            continue
        # capture concurrency / rate label for sweep tables
        args = (b.get("args") or {}) if isinstance(b.get("args"), dict) else {}
        rate = (b.get("rate") or args.get("rate") or args.get("rate_per_second")
                or args.get("concurrency") or args.get("strategy"))
        sweep_points.append({**flat, "rate": rate, "id": b.get("id_") or b.get("id")})
        score = flat.get("output_tokens_per_second") or flat.get("requests_per_second") or 0.0
        if score >= best_score:
            best_score = score
            best = flat

    if not best:
        return {}

    out: Dict[str, Any] = {"_source": os.path.basename(path), "kind": "llmd_bench"}
    out.update(best)
    out["metric_values"] = {k: v for k, v in best.items()}
    out["metric_display"] = _metric_display(out["metric_values"], priority=[
        "output_tokens_per_second", "requests_per_second", "tokens_per_second",
        "ttft_ms", "tpot_ms", "itl_ms", "request_latency_ms",
        "prompt_tokens", "output_tokens",
    ])
    if len(sweep_points) > 1:
        out["sweep_points"] = sweep_points
    return out


def _parse_vllm_bench_json(path: str) -> Dict[str, Any]:
    with open(path, "r", errors="replace") as f:
        data = json.load(f)
    out: Dict[str, Any] = {"_source": os.path.basename(path), "kind": "vllm_bench"}
    for k in _VLLM_BENCH_KEYS:
        if k in data:
            out[k] = data[k]
    if "model_id" in data and "model" not in out:
        out["model"] = data["model_id"]
    out["metric_values"] = {k: out[k] for k in out
                            if isinstance(out.get(k), (int, float))}
    out["metric_display"] = _metric_display(out["metric_values"], priority=[
        "request_throughput", "output_throughput", "output_token_throughput",
        "mean_ttft_ms", "p99_ttft_ms",
        "mean_tpot_ms", "p99_tpot_ms",
        "mean_e2e_ms", "p99_e2e_ms",
        "completed", "successful_requests",
    ])
    return out


# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------


def _find_files(root: str, names: List[str], max_depth: int = 4) -> List[str]:
    if not root or not os.path.isdir(root):
        return []
    matches: List[str] = []
    root_depth = root.rstrip("/").count("/")
    for dirpath, _dirnames, filenames in os.walk(root):
        depth = dirpath.rstrip("/").count("/") - root_depth
        if depth > max_depth:
            continue
        for fn in filenames:
            if fn in names:
                matches.append(os.path.join(dirpath, fn))
    return matches



def _find_files_by_suffix(root: str, suffixes: List[str], max_depth: int = 4) -> List[str]:
    if not root or not os.path.isdir(root):
        return []
    matches: List[str] = []
    root_depth = root.rstrip("/").count("/")
    for dirpath, _dirnames, filenames in os.walk(root):
        depth = dirpath.rstrip("/").count("/") - root_depth
        if depth > max_depth:
            continue
        for fn in filenames:
            if any(fn.endswith(suf) for suf in suffixes):
                matches.append(os.path.join(dirpath, fn))
    return matches

def parse_result_dir(log_dir: Optional[str], suite: str,
                     kind: str = "mlperf") -> Tuple[Optional[Dict[str, Any]],
                                                    Optional[str]]:
    """Pick the right result file based on (kind, suite) and parse it."""
    if not log_dir:
        return None, None

    result_dir = os.path.join(log_dir, "results")
    candidates: List[Tuple[str, Callable[[str], Dict[str, Any]]]] = []

    if kind == "vllm_bench":
        seen = set()
        for p in _find_files(result_dir, ["bench_serving.json"]):
            candidates.append((p, _parse_vllm_bench_json)); seen.add(p)
        # Backward-compatible fallback for older script versions that wrote
        # <host>_<model>_vllm.json instead of bench_serving.json.
        for p in _find_files_by_suffix(result_dir, ["_vllm.json"]):
            if p not in seen:
                candidates.append((p, _parse_vllm_bench_json)); seen.add(p)
    elif kind == "pd_bench":
        seen = set()
        for p in _find_files(result_dir, ["pd_bench_serving.json", "bench_serving.json"]):
            candidates.append((p, _parse_vllm_bench_json)); seen.add(p)
        for p in _find_files_by_suffix(result_dir, ["_pd.json", "_pd_bench.json"]):
            if p not in seen:
                candidates.append((p, _parse_vllm_bench_json)); seen.add(p)
    elif kind == "llmd_bench":
        seen = set()
        for p in _find_files(result_dir, ["guidellm.json", "benchmarks.json"]):
            candidates.append((p, _parse_guidellm_json)); seen.add(p)
        for p in _find_files_by_suffix(result_dir, ["_guidellm.json"]):
            if p not in seen:
                candidates.append((p, _parse_guidellm_json)); seen.add(p)
    elif suite == "inference":
        for p in _find_files(result_dir, ["mlperf_log_summary.txt"]):
            candidates.append((p, _parse_loadgen_summary))
    else:
        names = ["result.txt", "result_0.txt", "result_1.txt",
                 "train.log", "training.log", "trainer.log", "log.txt"]
        for p in _find_files(result_dir, names):
            candidates.append((p, _parse_training_log))
        run_log = os.path.join(log_dir, "run.log")
        if os.path.isfile(run_log):
            candidates.append((run_log, _parse_training_log))

    if not candidates:
        return None, None

    last_err: Optional[str] = None
    for path, parser in candidates:
        try:
            data = parser(path)
            if data:
                return data, None
        except Exception as e:  # noqa: BLE001
            last_err = f"{os.path.basename(path)}: {type(e).__name__}: {e}"
            continue

    return None, last_err


# ---------------------------------------------------------------------------
# Live log buffer parser (mlperf MLLOG, fallback for in-progress runs)
# ---------------------------------------------------------------------------


def _as_number(v: Any) -> Optional[float]:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def _metric_display(metric_values: Dict[str, Any], limit: int = 10,
                    priority: Optional[List[str]] = None) -> List[Dict[str, Any]]:
    if priority is None:
        priority = [
            "samples_per_second", "tokens_per_second", "train_loss", "loss",
            "eval_accuracy", "eval_error", "validation_loss", "perplexity",
            "train_step_time", "validation_time", "step", "samples_count",
            "run_stop_status",
        ]
    keys: List[str] = []
    for k in priority:
        if k in metric_values and k not in keys:
            keys.append(k)
    for k in sorted(metric_values.keys()):
        if k not in keys:
            keys.append(k)
    out: List[Dict[str, Any]] = []
    for k in keys[:limit]:
        out.append({"key": k, "value": metric_values[k]})
    return out


def parse_log_buffer_lines(lines: List[str], suite: str) -> Dict[str, Any]:
    """Parse metrics directly from platform log buffer lines (training MLLOG)."""
    source = "live_log_buffer"
    text = "\n".join(str(raw).rstrip("\n") for raw in lines)
    metric_values, run_stop_seen, target_quality_seen = _parse_training_text(text)

    metric_values = {k: v for k, v in metric_values.items() if k in MLPERF_PARSED_METRIC_KEYS}
    out: Dict[str, Any] = {
        "kind": suite,
        "_source": source,
        "metric_values": metric_values,
        "metric_display": _metric_display(metric_values, priority=[
            "train_loss", "train_step_time", "eval_accuracy", "validation_time",
            "step", "samples_count", "eval_samples", "global_batch_size", "duration_sec",
        ]),
        "run_stop_seen": run_stop_seen,
        "target_quality_seen": target_quality_seen,
    }

    if "train_loss" in metric_values:
        out["train_loss"] = metric_values["train_loss"]
    if "train_step_time" in metric_values:
        out["train_step_time"] = metric_values["train_step_time"]
    if "eval_accuracy" in metric_values:
        out["eval_accuracy"] = metric_values["eval_accuracy"]
    if "validation_time" in metric_values:
        out["validation_time"] = metric_values["validation_time"]
    return out
