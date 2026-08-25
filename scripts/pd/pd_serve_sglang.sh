#!/usr/bin/env bash
set -Eeuo pipefail
# scripts/pd/pd_serve_sglang.sh
# ----------------------------
# Placeholder.  SGLang's PD support uses --disaggregation-mode prefill / decode
# and is much simpler than vLLM's KV connector approach, but we haven't
# wired it up here yet.  Mirrors pd_serve_vllm.sh structure when implemented.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

LEADER=""
RUN_ID=""
GPU_TYPE=""
PREFILL_HOSTS_CSV=""
DECODE_HOSTS_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --leader) LEADER="${2:-}"; shift 2 ;;
    --prefill-hosts) PREFILL_HOSTS_CSV="${2:-}"; shift 2 ;;
    --decode-hosts) DECODE_HOSTS_CSV="${2:-}"; shift 2 ;;
    --dry-run) shift ;;
    --*) shift 2 ;;
    *) shift ;;
  esac
done

cm_phase validate
cm_warn "sglang PD disaggregation is not implemented yet (placeholder)."
cm_phase done

cm_emit_json_line PD_BENCH_RESULT_JSON \
  status      failed \
  run_id      "${RUN_ID:-unknown}" \
  host        "${LEADER:-unknown}" \
  gpu_type    "${GPU_TYPE:-unknown}" \
  suite       "pd_bench" \
  engine      "sglang" \
  exit_code   2 \
  result_hint "sglang PD engine TBD"

exit 2
