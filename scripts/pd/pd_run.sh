#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/pd/pd_run.sh
# -------------------
# Top-level dispatcher for the PD (Prefill/Decode disaggregation) tab.
#
# Unlike vllm_run.sh which has parallel groups, PD has a SINGLE serving
# topology: one set of prefill hosts + one set of decode hosts forming one
# disaggregated cluster.  This script just validates the request and hands
# off to scripts/pd/pd_serve_vllm.sh or pd_serve_sglang.sh.
#
# Stdout from the serve script is prefixed with [<leader>] to match the
# host-attribution contract used by mlperf_run.sh and vllm_run.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

usage() {
  cat <<'EOU'
Usage:
  ./pd_run.sh \
    --run-id pd_001 \
    --engine vllm \
    --model meta-llama/Llama-2-7b-chat-hf \
    --bench-data sharegpt \
    --gpu-type H100 \
    --prefill-hosts gpu-node01,gpu-node02 --prefill-tp 4 \
    --decode-hosts gpu-node03,gpu-node04  --decode-tp 4

Options:
  --stop
  --run-id <id>
  --engine vllm|sglang
  --model <hf-name-or-local-path>
  --bench-data sharegpt|random
  --gpu-type <gpu>
  --prefill-hosts <h1,h2,...>
  --decode-hosts  <h1,h2,...>
  --prefill-tp <int>
  --decode-tp  <int>
  --num-prompts <int>
  --request-rate <float|inf>
  --max-model-len <int>
  --mlperf-root <path>
  --data-root <path>
  --log-root <path>
  --docker-image <image>
  --extra-args "..."
  --dry-run
EOU
}

MODE="run"
RUN_ID=""
ENGINE="vllm"
MODEL=""
MODEL_PATH=""
BENCH_DATA="sharegpt"
GPU_TYPE=""
PREFILL_HOSTS_CSV=""
DECODE_HOSTS_CSV=""
PREFILL_TP=""
DECODE_TP=""
PREFILL_INSTANCES=""
DECODE_INSTANCES=""
NUM_PROMPTS="200"
REQUEST_RATE="inf"
MAX_MODEL_LEN="4096"
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
LOG_ROOT=""
DOCKER_IMAGE=""
EXTRA_ARGS=""
EXTRA_DOCKER_ARGS=""
PREFILL_EXTRA_ARGS=""
DECODE_EXTRA_ARGS=""
PREFILL_EXTRA_DOCKER_ARGS=""
DECODE_EXTRA_DOCKER_ARGS=""
PREFILL_SPECS=""
DECODE_SPECS=""
PROXY_PORT=""
GPU_MAPS=()
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE="stop"; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --engine) ENGINE="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --bench-data) BENCH_DATA="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --prefill-hosts) PREFILL_HOSTS_CSV="${2:-}"; shift 2 ;;
    --decode-hosts) DECODE_HOSTS_CSV="${2:-}"; shift 2 ;;
    --prefill-tp) PREFILL_TP="${2:-}"; shift 2 ;;
    --decode-tp) DECODE_TP="${2:-}"; shift 2 ;;
    --prefill-instances) PREFILL_INSTANCES="${2:-}"; shift 2 ;;
    --decode-instances) DECODE_INSTANCES="${2:-}"; shift 2 ;;
    --prefill-specs) PREFILL_SPECS="${2:-}"; shift 2 ;;
    --decode-specs) DECODE_SPECS="${2:-}"; shift 2 ;;
    --proxy-port) PROXY_PORT="${2:-}"; shift 2 ;;
    --extra-docker-args) EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --prefill-extra-args) PREFILL_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --decode-extra-args) DECODE_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --prefill-extra-docker-args) PREFILL_EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --decode-extra-docker-args) DECODE_EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --num-prompts) NUM_PROMPTS="${2:-}"; shift 2 ;;
    --request-rate) REQUEST_RATE="${2:-}"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --docker-image) DOCKER_IMAGE="${2:-}"; shift 2 ;;
    --extra-args) EXTRA_ARGS="${2:-}"; shift 2 ;;
    --gpu-map) GPU_MAPS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; cm_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || cm_die "--run-id required"
cm_validate_run_id "$RUN_ID"

[[ -n "$PREFILL_HOSTS_CSV" ]] || cm_die "--prefill-hosts required"
[[ -n "$DECODE_HOSTS_CSV" ]]  || cm_die "--decode-hosts required"

IFS=',' read -ra PHOSTS <<< "$PREFILL_HOSTS_CSV"
IFS=',' read -ra DHOSTS <<< "$DECODE_HOSTS_CSV"
for h in "${PHOSTS[@]}" "${DHOSTS[@]}"; do cm_validate_host "$h"; done

# Engine selection
case "$ENGINE" in
  vllm)   TARGET="${SCRIPT_DIR}/pd_serve_vllm.sh" ;;
  sglang) TARGET="${SCRIPT_DIR}/pd_serve_sglang.sh" ;;
  *) cm_die "Unsupported --engine: $ENGINE" ;;
esac

[[ -x "$TARGET" ]] || cm_die "Target script not executable: $TARGET"

# Default log root
if [[ -z "$LOG_ROOT" ]]; then
  LOG_ROOT="${MLPERF_ROOT}/${ENGINE}_logs_pd_bench"
fi

if [[ "$MODE" == "run" ]]; then
  [[ -n "$MODEL" ]] || cm_die "--model required"
  [[ -n "$GPU_TYPE" ]] || cm_die "--gpu-type required"
fi

LEADER="${PHOSTS[0]}"

cm_phase dispatch
cm_inf "engine=${ENGINE}"
cm_inf "run_id=${RUN_ID}"
cm_inf "model=${MODEL:-<stop-mode>}"
cm_inf "model_path=${MODEL_PATH:-<unset>}"
cm_inf "bench_data=${BENCH_DATA}"
cm_inf "gpu_type=${GPU_TYPE:-<unset>}"
cm_inf "prefill_hosts=${PREFILL_HOSTS_CSV}  prefill_tp=${PREFILL_TP:-auto}"
cm_inf "decode_hosts=${DECODE_HOSTS_CSV}    decode_tp=${DECODE_TP:-auto}"
cm_inf "leader=${LEADER}"
cm_inf "log_root=${LOG_ROOT}"

if [[ "$MODE" == "run" && "$DRY_RUN" != "true" ]]; then
  cm_ensure_docker_hosts "${PHOSTS[@]}" "${DHOSTS[@]}" localhost
fi

# Build args for the serve script
ARGS=(
  --run-id "$RUN_ID"
  --gpu-type "$GPU_TYPE"
  --leader "$LEADER"
  --prefill-hosts "$PREFILL_HOSTS_CSV"
  --decode-hosts "$DECODE_HOSTS_CSV"
  --model "$MODEL"
  --bench-data "$BENCH_DATA"
  --num-prompts "$NUM_PROMPTS"
  --request-rate "$REQUEST_RATE"
  --max-model-len "$MAX_MODEL_LEN"
  --mlperf-root "$MLPERF_ROOT"
  --data-root "$DATA_ROOT"
  --log-root "$LOG_ROOT"
)
[[ -n "$MODEL_PATH" ]] && ARGS+=(--model-path "$MODEL_PATH")
[[ -n "$PREFILL_TP" ]] && ARGS+=(--prefill-tp "$PREFILL_TP")
[[ -n "$DECODE_TP" ]]  && ARGS+=(--decode-tp "$DECODE_TP")
[[ -n "$PREFILL_INSTANCES" ]] && ARGS+=(--prefill-instances "$PREFILL_INSTANCES")
[[ -n "$DECODE_INSTANCES" ]] && ARGS+=(--decode-instances "$DECODE_INSTANCES")
[[ -n "$PREFILL_SPECS" ]] && ARGS+=(--prefill-specs "$PREFILL_SPECS")
[[ -n "$DECODE_SPECS" ]] && ARGS+=(--decode-specs "$DECODE_SPECS")
[[ -n "$PROXY_PORT" ]] && ARGS+=(--proxy-port "$PROXY_PORT")
[[ -n "$EXTRA_DOCKER_ARGS" ]] && ARGS+=(--extra-docker-args "$EXTRA_DOCKER_ARGS")
[[ -n "$PREFILL_EXTRA_ARGS" ]] && ARGS+=(--prefill-extra-args "$PREFILL_EXTRA_ARGS")
[[ -n "$DECODE_EXTRA_ARGS" ]] && ARGS+=(--decode-extra-args "$DECODE_EXTRA_ARGS")
[[ -n "$PREFILL_EXTRA_DOCKER_ARGS" ]] && ARGS+=(--prefill-extra-docker-args "$PREFILL_EXTRA_DOCKER_ARGS")
[[ -n "$DECODE_EXTRA_DOCKER_ARGS" ]] && ARGS+=(--decode-extra-docker-args "$DECODE_EXTRA_DOCKER_ARGS")
[[ -n "$DOCKER_IMAGE" ]] && ARGS+=(--docker-image "$DOCKER_IMAGE")
[[ -n "$EXTRA_ARGS" ]] && ARGS+=(--extra-args "$EXTRA_ARGS")
for gm in "${GPU_MAPS[@]}"; do [[ -n "$gm" ]] && ARGS+=(--gpu-map "$gm"); done
[[ "$DRY_RUN" == "true" ]] && ARGS+=(--dry-run)
[[ "$MODE" == "stop" ]] && ARGS=(--stop "${ARGS[@]}")

set +e
"$TARGET" "${ARGS[@]}" 2>&1 | sed -u "s/^/[${LEADER}] /"
RC="${PIPESTATUS[0]}"
set -e

cm_phase done
exit "$RC"
