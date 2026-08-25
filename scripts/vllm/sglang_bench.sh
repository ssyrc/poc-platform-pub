#!/usr/bin/env bash
set -Eeuo pipefail
# scripts/vllm/sglang_bench.sh
# ---------------------------
# Placeholder. SGLang benchmarking on vLLM Bench tab is not implemented yet.
# When implemented, this script should mirror vllm_bench.sh structure:
#  1) Bring up SGLang server cluster (multi-node via tp + dp)
#  2) Wait for /health
#  3) Run sglang.bench_serving with the chosen dataset
#  4) emit VLLM_BENCH_RESULT_JSON (same line schema)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

LEADER=""
RUN_ID=""
GPU_TYPE=""
HOSTS_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) shift ;;  # stop is a no-op for the placeholder
    --leader) LEADER="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --hosts) HOSTS_CSV="${2:-}"; shift 2 ;;
    --dry-run) shift ;;
    --*) shift 2 ;;   # ignore everything else (placeholder)
    *) shift ;;
  esac
done

cm_phase validate
cm_warn "sglang engine on vLLM Bench tab is not implemented yet (placeholder)."
cm_phase done

cm_emit_json_line VLLM_BENCH_RESULT_JSON \
  status      failed \
  run_id      "${RUN_ID:-unknown}" \
  host        "${LEADER:-unknown}" \
  gpu_type    "${GPU_TYPE:-unknown}" \
  suite       "vllm_bench" \
  engine      "sglang" \
  exit_code   2 \
  result_hint "sglang engine TBD"

exit 2
