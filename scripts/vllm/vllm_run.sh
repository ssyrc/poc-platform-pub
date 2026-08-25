#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/vllm/vllm_run.sh
# -----------------------
# Dispatcher for the vLLM Bench tab.
#
# Input groups are described as "<gpu_type>:<host1>,<host2>,...".
# Multiple groups can be passed.  Hosts inside the SAME group form a single
# vLLM serving cluster (Ray head on group leader, workers on the rest).
# Different groups run in parallel - they're independent benchmarks.
#
# Each per-group runner is scripts/vllm/vllm_bench.sh (engine=vllm) or
# scripts/vllm/sglang_bench.sh (engine=sglang).
#
# Stdout from each group is prefixed with [<leader_host>] so the platform's
# runner can attribute it to a host.  This matches mlperf_run.sh's contract.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

usage() {
  cat <<'EOU'
Usage:
  ./vllm_run.sh \
    --run-id vllm_001 \
    --engine vllm \
    --model meta-llama/Llama-2-7b-chat-hf \
    --bench-data sharegpt \
    --group H100:gpu-node05,gpu-node06 \
    --group A100:agpu1321,agpu1472

Options:
  --stop
  --run-id <id>
  --engine vllm|sglang
  --model <hf-name-or-local-path>
  --bench-data sharegpt|random
  --group <GPU_TYPE>:<host1,host2,...>   repeatable
  --num-prompts <int>                    default 200
  --request-rate <float>                 default inf (offline)
  --max-model-len <int>                  default 4096
  --tp <int>                             override per-host tensor-parallel size
  --pp <int>                             override pipeline-parallel size
  --mlperf-root <path>                   path to /home/.../mlperf
  --data-root <path>                     path to /home/.../mlperf/data
  --log-root <path>                      override log root
  --docker-image <image>                 override engine image
  --gpu-memory-utilization <float>         vLLM serve GPU memory utilization
  --extra-args "..."                     extra args appended to vllm serve
  --extra-docker-args "..."              extra docker args for vLLM serve containers
  --dry-run
EOU
}

MODE="run"
RUN_ID=""
ENGINE="vllm"
MODEL=""
MODEL_PATH=""
BENCH_DATA="sharegpt"
GROUP_SPECS=()
GPU_MAPS=()
BMT_HOST=""
NUM_PROMPTS="200"
REQUEST_RATE="inf"
MAX_MODEL_LEN="4096"
GPU_MEMORY_UTILIZATION=""
TP_OVERRIDE=""
PP_OVERRIDE=""
TOPOLOGY_MODE=""              # single | multi
VLLM_PORT=""
RAY_HEAD_PORT=""
RAY_WORKER_PORT=""
MAX_CONCURRENCY=""
DATASET_PATH=""
INPUT_LEN=""
OUTPUT_LEN=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
LOG_ROOT=""
DOCKER_IMAGE=""
EXTRA_ARGS=""
EXTRA_DOCKER_ARGS=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE="stop"; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --engine) ENGINE="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --bench-data) BENCH_DATA="${2:-}"; shift 2 ;;
    --group) GROUP_SPECS+=("${2:-}"); shift 2 ;;
    --gpu-map) GPU_MAPS+=("${2:-}"); shift 2 ;;
    --bmt-host) BMT_HOST="${2:-}"; shift 2 ;;
    --num-prompts) NUM_PROMPTS="${2:-}"; shift 2 ;;
    --request-rate) REQUEST_RATE="${2:-}"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="${2:-}"; shift 2 ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION="${2:-}"; shift 2 ;;
    --tp) TP_OVERRIDE="${2:-}"; shift 2 ;;
    --pp) PP_OVERRIDE="${2:-}"; shift 2 ;;
    --mode) TOPOLOGY_MODE="${2:-}"; shift 2 ;;
    --port) VLLM_PORT="${2:-}"; shift 2 ;;
    --ray-head-port) RAY_HEAD_PORT="${2:-}"; shift 2 ;;
    --ray-worker-port) RAY_WORKER_PORT="${2:-}"; shift 2 ;;
    --max-concurrency) MAX_CONCURRENCY="${2:-}"; shift 2 ;;
    --dataset-path) DATASET_PATH="${2:-}"; shift 2 ;;
    --input-len) INPUT_LEN="${2:-}"; shift 2 ;;
    --output-len) OUTPUT_LEN="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --docker-image) DOCKER_IMAGE="${2:-}"; shift 2 ;;
    --extra-args) EXTRA_ARGS="${2:-}"; shift 2 ;;
    --extra-docker-args) EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; cm_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || cm_die "--run-id is required"
cm_validate_run_id "$RUN_ID"
[[ "${#GROUP_SPECS[@]}" -gt 0 ]] || cm_die "at least one --group required"

case "$ENGINE" in
  vllm) TARGET_SCRIPT="${SCRIPT_DIR}/vllm_bench.sh" ;;
  sglang) TARGET_SCRIPT="${SCRIPT_DIR}/sglang_bench.sh" ;;
  *) cm_die "Unsupported --engine: $ENGINE (use vllm|sglang)" ;;
esac

[[ -x "$TARGET_SCRIPT" ]] || cm_die "Target script not executable: $TARGET_SCRIPT"

if [[ "$MODE" == "run" ]]; then
  [[ -n "$MODEL" ]] || cm_die "--model is required for run"
fi

# Default LOG_ROOT per engine.
if [[ -z "$LOG_ROOT" ]]; then
  LOG_ROOT="${MLPERF_ROOT}/${ENGINE}_logs_bench"
fi

STATUS_DIR="/tmp/${ENGINE}_run_${RUN_ID}_$$_$(date +%s)"
mkdir -p "$STATUS_DIR"

cm_phase dispatch
cm_inf "engine=${ENGINE}"
cm_inf "run_id=${RUN_ID}"
cm_inf "model=${MODEL:-<stop-mode>}"
cm_inf "model_path=${MODEL_PATH:-<unset>}"
cm_inf "bench_data=${BENCH_DATA}"
cm_inf "groups=${GROUP_SPECS[*]}"
cm_inf "log_root=${LOG_ROOT}"

build_base_args() {
  local gpu_type="$1" leader="$2" hosts_csv="$3"
  local -a args=(
    --run-id "$RUN_ID"
    --gpu-type "$gpu_type"
    --leader "$leader"
    --hosts "$hosts_csv"
    --model "$MODEL"
    --bench-data "$BENCH_DATA"
    --num-prompts "$NUM_PROMPTS"
    --request-rate "$REQUEST_RATE"
    --max-model-len "$MAX_MODEL_LEN"
    --mlperf-root "$MLPERF_ROOT"
    --data-root "$DATA_ROOT"
    --log-root "$LOG_ROOT"
  )
  [[ -n "$MODEL_PATH" ]]       && args+=(--model-path "$MODEL_PATH")
  [[ -n "$BMT_HOST" ]]         && args+=(--bmt-host "$BMT_HOST")
  [[ -n "$DOCKER_IMAGE" ]]     && args+=(--docker-image "$DOCKER_IMAGE")
  [[ -n "$GPU_MEMORY_UTILIZATION" ]] && args+=(--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION")
  [[ -n "$TP_OVERRIDE" ]]      && args+=(--tp "$TP_OVERRIDE")
  [[ -n "$PP_OVERRIDE" ]]      && args+=(--pp "$PP_OVERRIDE")
  [[ -n "$TOPOLOGY_MODE" ]]    && args+=(--mode "$TOPOLOGY_MODE")
  [[ -n "$VLLM_PORT" ]]        && args+=(--port "$VLLM_PORT")
  [[ -n "$RAY_HEAD_PORT" ]]    && args+=(--ray-head-port "$RAY_HEAD_PORT")
  [[ -n "$RAY_WORKER_PORT" ]]  && args+=(--ray-worker-port "$RAY_WORKER_PORT")
  [[ -n "$MAX_CONCURRENCY" ]]  && args+=(--max-concurrency "$MAX_CONCURRENCY")
  [[ -n "$DATASET_PATH" ]]     && args+=(--dataset-path "$DATASET_PATH")
  [[ -n "$INPUT_LEN" ]]        && args+=(--input-len "$INPUT_LEN")
  [[ -n "$OUTPUT_LEN" ]]       && args+=(--output-len "$OUTPUT_LEN")
  [[ -n "$EXTRA_ARGS" ]]       && args+=(--extra-args "$EXTRA_ARGS")
  [[ -n "$EXTRA_DOCKER_ARGS" ]] && args+=(--extra-docker-args "$EXTRA_DOCKER_ARGS")
  for gm in "${GPU_MAPS[@]}"; do [[ -n "$gm" ]] && args+=(--gpu-map "$gm"); done
  [[ "$DRY_RUN" == "true" ]]   && args+=(--dry-run)
  printf '%s\0' "${args[@]}"
}

build_stop_args() {
  local gpu_type="$1" leader="$2" hosts_csv="$3"
  local -a args=(
    --stop
    --run-id "$RUN_ID"
    --gpu-type "$gpu_type"
    --leader "$leader"
    --hosts "$hosts_csv"
    --mlperf-root "$MLPERF_ROOT"
    --data-root "$DATA_ROOT"
    --log-root "$LOG_ROOT"
  )
  [[ -n "$BMT_HOST" ]]      && args+=(--bmt-host "$BMT_HOST")
  [[ -n "$TOPOLOGY_MODE" ]] && args+=(--mode "$TOPOLOGY_MODE")
  printf '%s\0' "${args[@]}"
}

# Iterate groups
declare -a GROUP_HOSTS_CSV=()
declare -a GROUP_GPU_TYPES=()
declare -a GROUP_LEADERS=()
for spec in "${GROUP_SPECS[@]}"; do
  [[ "$spec" == *":"* ]] || cm_die "bad --group spec (need '<gpu>:host1,host2'): $spec"
  gpu="${spec%%:*}"
  rest="${spec#*:}"
  IFS=',' read -ra hosts <<< "$rest"
  [[ "${#hosts[@]}" -gt 0 ]] || cm_die "no hosts in group: $spec"
  for h in "${hosts[@]}"; do cm_validate_host "$h"; done
  leader="${hosts[0]}"
  GROUP_GPU_TYPES+=("$gpu")
  GROUP_LEADERS+=("$leader")
  GROUP_HOSTS_CSV+=("$(IFS=',' ; echo "${hosts[*]}")")
done

if [[ "$MODE" == "run" && "$DRY_RUN" != "true" ]]; then
  DOCKER_HOSTS=()
  for csv in "${GROUP_HOSTS_CSV[@]}"; do
    IFS=',' read -ra _hs <<< "$csv"
    for _h in "${_hs[@]}"; do [[ -n "$_h" ]] && DOCKER_HOSTS+=("$_h"); done
  done
  [[ -n "${BMT_HOST:-}" ]] && DOCKER_HOSTS+=("$BMT_HOST")
  cm_ensure_docker_hosts "${DOCKER_HOSTS[@]}"
fi

cm_phase dispatch_groups
i=0
for spec in "${GROUP_SPECS[@]}"; do
  gpu="${GROUP_GPU_TYPES[$i]}"
  leader="${GROUP_LEADERS[$i]}"
  hosts_csv="${GROUP_HOSTS_CSV[$i]}"
  cm_inf "group ${i}: gpu_type=${gpu} leader=${leader} hosts=${hosts_csv}"

  if [[ "$MODE" == "stop" ]]; then
    mapfile -d '' -t group_args < <(build_stop_args "$gpu" "$leader" "$hosts_csv")
  else
    mapfile -d '' -t group_args < <(build_base_args "$gpu" "$leader" "$hosts_csv")
  fi

  (
    set +e
    "$TARGET_SCRIPT" "${group_args[@]}" 2>&1 | sed -u "s/^/[${leader}] /"
    rc="${PIPESTATUS[0]}"
    echo "$rc" > "${STATUS_DIR}/group_${i}.status"
    exit "$rc"
  ) &
  i=$((i+1))
done

wait || true

cm_phase collect
FINAL_STATUS=0
i=0
for spec in "${GROUP_SPECS[@]}"; do
  leader="${GROUP_LEADERS[$i]}"
  if [[ -f "${STATUS_DIR}/group_${i}.status" ]]; then
    rc="$(cat "${STATUS_DIR}/group_${i}.status")"
  else
    rc=99
  fi
  cm_inf "group ${i} (leader=${leader}) exit_code=${rc}"
  [[ "$rc" != "0" ]] && FINAL_STATUS=1
  i=$((i+1))
done

cm_phase done
exit "$FINAL_STATUS"
