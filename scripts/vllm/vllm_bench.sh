#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/vllm/vllm_bench.sh
# -------------------------
# Runs ONE vLLM serving cluster + benchmark for a single GPU group.
# Modeled on the user's working `multi_serve_and_bench.sh` script.
#
# Architecture (matching user's working flow):
#   * `--hosts h1,h2,...` form a Ray cluster:
#       - h1 = ray head (vLLM api server runs INSIDE the same container via
#              `docker exec -d ray-head ... vllm serve ...`)
#       - h2..hN = ray workers
#   * `--bmt-host` (defaults to first host) runs `vllm bench serve` against
#     the head's exposed serve port. This is a SEPARATE docker run on the
#     bmt host - it does NOT need GPUs (CUDA_VISIBLE_DEVICES is empty).
#
# Defaults match the user's environment:
#   image AMD64 local tag: docker.io/vllm/vllm-openai:latest
#   image ARM64/GH200: rajesh550/gh200-vllm:0.11.1rc2
#   HOST_INFER_DIR=/opt/poc-platform/inference  -> /workspace
#   HOST_MODELS_DIR=/opt/poc-platform/models  -> /workspace/models
#   ENCODINGS_DIR=/opt/poc-platform/encodings  -> /etc/encodings
#
# Environment overrides (read from process env, set by the runner via
# params.args from the UI):
#   HOST_INFER_DIR, HOST_MODELS_DIR, ENCODINGS_DIR
#   VLLM_PORT (default 9001), RAY_PORT (default 6379)
#   IMG_NVIDIA_AMD64, IMG_NVIDIA_ARM64, TAR_NVIDIA_ARM64
#   MODEL_NAME (default = --model arg)
#   NUM_PROMPTS, CONCURRENCY, RANDOM_ISL, RANDOM_OSL, SHAREGPT_OSL
#   SHAREGPT_PATH (overrides /workspace/datasets/...)
#   TP, PP                  (override --tp / --pp)
#   READY_TIMEOUT_SEC (default 300)
#   BMT_HOST (override --bmt-host)
#
# Stdout schema:
#   [PHASE] validate|prepare|ray_head|ray_workers|serve|wait|bench|collect|done|stop
#   VLLM_BENCH_RESULT_JSON={ ... }       <- final summary line consumed by runner

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

usage() {
  cat <<'EOU'
Usage:
  ./vllm_bench.sh \
    --run-id vllm_001 \
    --gpu-type H100 \
    --leader gpu-node01 \
    --hosts gpu-node01,gpu-node02 \
    --bmt-host gpu-node03 \
    --model gpt-oss-120b \
    --bench-data sharegpt
EOU
}

MODE="run"
RUN_ID=""
GPU_TYPE=""
LEADER=""
HOSTS_CSV=""
BMT_HOST=""
MODEL=""
MODEL_PATH=""
BENCH_DATA="sharegpt"
NUM_PROMPTS=""
REQUEST_RATE="inf"
MAX_MODEL_LEN=""
GPU_MEMORY_UTILIZATION_CLI=""
TP_OVERRIDE=""
PP_OVERRIDE=""
TOPOLOGY_MODE=""              # single | multi (default: auto-detect from --hosts)
VLLM_PORT_CLI=""              # --port  (vllm serve)
RAY_HEAD_PORT_CLI=""          # --ray-head-port
RAY_WORKER_PORT_CLI=""        # --ray-worker-port (port workers dial on head)
MAX_CONCURRENCY_CLI=""        # --max-concurrency
DATASET_PATH_CLI=""           # --dataset-path
INPUT_LEN_CLI=""              # --input-len   (random only)
OUTPUT_LEN_CLI=""             # --output-len  (random / sharegpt)
DOCKER_IMAGE=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
LOG_ROOT=""
EXTRA_ARGS=""
EXTRA_DOCKER_ARGS=""
GPU_MAPS=()
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE="stop"; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --leader) LEADER="${2:-}"; shift 2 ;;
    --hosts) HOSTS_CSV="${2:-}"; shift 2 ;;
    --bmt-host) BMT_HOST="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --bench-data) BENCH_DATA="${2:-}"; shift 2 ;;
    --num-prompts) NUM_PROMPTS="${2:-}"; shift 2 ;;
    --request-rate) REQUEST_RATE="${2:-}"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="${2:-}"; shift 2 ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION_CLI="${2:-}"; shift 2 ;;
    --tp) TP_OVERRIDE="${2:-}"; shift 2 ;;
    --pp) PP_OVERRIDE="${2:-}"; shift 2 ;;
    --mode) TOPOLOGY_MODE="${2:-}"; shift 2 ;;
    --port) VLLM_PORT_CLI="${2:-}"; shift 2 ;;
    --ray-head-port) RAY_HEAD_PORT_CLI="${2:-}"; shift 2 ;;
    --ray-worker-port) RAY_WORKER_PORT_CLI="${2:-}"; shift 2 ;;
    --max-concurrency) MAX_CONCURRENCY_CLI="${2:-}"; shift 2 ;;
    --dataset-path) DATASET_PATH_CLI="${2:-}"; shift 2 ;;
    --input-len) INPUT_LEN_CLI="${2:-}"; shift 2 ;;
    --output-len) OUTPUT_LEN_CLI="${2:-}"; shift 2 ;;
    --docker-image) DOCKER_IMAGE="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --extra-args) EXTRA_ARGS="${2:-}"; shift 2 ;;
    --extra-docker-args) EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --gpu-map) GPU_MAPS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; cm_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || cm_die "--run-id is required"
[[ -n "$LEADER" ]] || cm_die "--leader is required"
[[ -n "$HOSTS_CSV" ]] || cm_die "--hosts is required"
cm_validate_run_id "$RUN_ID"
cm_validate_host "$LEADER"

IFS=',' read -ra HOSTS <<< "$HOSTS_CSV"
for h in "${HOSTS[@]}"; do cm_validate_host "$h"; done
NUM_HOSTS="${#HOSTS[@]}"

gpu_visible_for_host() {
  local target="$1" spec key value
  for spec in "${GPU_MAPS[@]}"; do
    [[ "$spec" == *=* ]] || continue
    key="${spec%%=*}"
    value="${spec#*=}"
    if [[ "$key" == "$target" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  printf '%s' ""
}

# ---- topology mode: explicit --mode wins, else infer from host count ----
if [[ -z "$TOPOLOGY_MODE" ]]; then
  if [[ "$NUM_HOSTS" -le 1 ]]; then
    TOPOLOGY_MODE="single"
  else
    TOPOLOGY_MODE="multi"
  fi
fi
case "$TOPOLOGY_MODE" in
  single|multi) ;;
  *) cm_die "Invalid --mode: $TOPOLOGY_MODE (single|multi)" ;;
esac

# bmt host: precedence is CLI arg > env BMT_HOST > leader.
if [[ -z "$BMT_HOST" ]]; then
  BMT_HOST="${BMT_HOST_ENV:-${BMT_HOST:-$LEADER}}"
  [[ -n "${BMT_HOST_OVERRIDE:-}" ]] && BMT_HOST="$BMT_HOST_OVERRIDE"
fi
cm_validate_host "$BMT_HOST"

# user-environment paths (override via env)
HOST_INFER_DIR="${VLLM_HOST_INFER_DIR:-${HOST_INFER_DIR:-${MLPERF_ROOT}/inference}}"
HOST_MODELS_DIR="${VLLM_HOST_MODELS_DIR:-${HOST_MODELS_DIR:-${MLPERF_ROOT}/models}}"
ENCODINGS_DIR="${VLLM_ENCODINGS_DIR:-${ENCODINGS_DIR:-${MLPERF_ROOT}/encodings}}"
PLATFORM_DATA_ROOT="${PLATFORM_DATA_ROOT:-${DATA_ROOT}}"
DOCKERIMG_ROOT="${DOCKERIMG_ROOT:-${PLATFORM_DATA_ROOT}/dockerimgs}"

# CLI args take precedence over env vars (which take precedence over defaults).
VLLM_PORT="${VLLM_PORT_CLI:-${VLLM_PORT:-9001}}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION_CLI:-${GPU_MEMORY_UTILIZATION:-}}"
RAY_PORT="${RAY_HEAD_PORT_CLI:-${RAY_PORT:-6379}}"
RAY_WORKER_PORT="${RAY_WORKER_PORT_CLI:-${RAY_WORKER_PORT:-$RAY_PORT}}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-300}"

REPO="${REPO:-${DOCKER_HUB_IMAGE_PREFIX:-docker.io}}"
IMG_NVIDIA_AMD64_DEFAULT="${REPO}/vllm/vllm-openai:latest"
IMG_NVIDIA_ARM64_DEFAULT="${REPO}/rajesh550/gh200-vllm:0.11.1rc2"
IMG_NVIDIA_AMD64="${IMG_NVIDIA_AMD64:-$IMG_NVIDIA_AMD64_DEFAULT}"
IMG_NVIDIA_ARM64="${IMG_NVIDIA_ARM64:-$IMG_NVIDIA_ARM64_DEFAULT}"
TAR_NVIDIA_AMD64="${TAR_NVIDIA_AMD64:-${DOCKERIMG_ROOT}/vllm-openai_latest.tar}"
TAR_NVIDIA_ARM64="${TAR_NVIDIA_ARM64:-${DOCKERIMG_ROOT}/gh200-vllm_0.11.1rc2.tar}"

SAFE_RUN_ID="$(cm_safe_id "$RUN_ID")"
RAY_HEAD_NAME="ray-head-${SAFE_RUN_ID}"      # multi-node: ray head container
RAY_WORKER_NAME="ray-worker-${SAFE_RUN_ID}"  # multi-node: ray worker containers
SERVE_NAME="vllm-serve-${SAFE_RUN_ID}"       # single-node: direct vllm serve container
BMT_NAME="bmt-vllm-${SAFE_RUN_ID}"

# ---------- STOP MODE ----------

if [[ "$MODE" == "stop" ]]; then
  cm_phase stop
  for h in "${HOSTS[@]}" "$BMT_HOST"; do
    cm_inf "stopping containers on ${h}"
    cm_remote_bash "$h" "$RAY_HEAD_NAME" "$RAY_WORKER_NAME" "$SERVE_NAME" "$BMT_NAME" <<'STOP'
set +e
H="$1"; W="$2"; S="$3"; B="$4"
for c in "$B" "$S" "$H" "$W"; do
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$c"; then
    docker stop -t 30 "$c" >/dev/null 2>&1
    docker rm -f "$c" >/dev/null 2>&1
  fi
done
STOP
  done
  cm_phase done
  exit 0
fi

# ---------- RUN MODE ----------

[[ -n "$GPU_TYPE" ]] || cm_die "--gpu-type required"
[[ -n "$MODEL" ]] || cm_die "--model required"
[[ -n "$MODEL_PATH" ]] || cm_die "--model-path required (absolute path to pre-staged local model directory)"

case "$BENCH_DATA" in
  sharegpt|random) ;;
  *) cm_die "Unsupported --bench-data: $BENCH_DATA (vllm engine supports sharegpt|random)" ;;
esac

START_TIME="$(date --iso-8601=seconds)"
START_EPOCH="$(date +%s)"
STAMP="$(date +%Y%m%d_%H%M%S)"
SAFE_LEADER="$(cm_safe_id "$LEADER")"
LOG_ROOT="${LOG_ROOT:-${MLPERF_ROOT}/vllm_logs_bench}"
LOG_DIR="${LOG_ROOT}/${STAMP}_${SAFE_LEADER}_vllm_${BENCH_DATA}_${RUN_ID}"
RESULT_DIR="${LOG_DIR}/results"
mkdir -p "$LOG_DIR"
exec > >(tee -a "${LOG_DIR}/run.log") 2>&1

# ---------- helpers ----------

emit_summary() {
  local status="$1" code="$2" hint="$3"
  local end_time end_epoch duration
  end_time="$(date --iso-8601=seconds)"
  end_epoch="$(date +%s)"
  duration="$((end_epoch - START_EPOCH))"
  cm_emit_json_line VLLM_BENCH_RESULT_JSON \
    status "$status" \
    run_id "$RUN_ID" \
    host "$LEADER" \
    bmt_host "$BMT_HOST" \
    gpu_type "$GPU_TYPE" \
    suite "vllm_bench" \
    engine "vllm" \
    benchmark "$BENCH_DATA" \
    model "$MODEL" \
    cluster_size "$NUM_HOSTS" \
    start_time "$START_TIME" \
    end_time "$end_time" \
    duration_sec "$duration" \
    log_dir "$LOG_DIR" \
    exit_code "$code" \
    result_hint "$hint"
}

fail_run() {
  cm_err "$1"
  emit_summary "failed" "${2:-1}" "$1"
  exit "${2:-1}"
}

cleanup_all() {
  cm_warn "cleaning up containers on all hosts"
  for h in "${HOSTS[@]}" "$BMT_HOST"; do
    cm_remote_bash "$h" "$RAY_HEAD_NAME" "$RAY_WORKER_NAME" "$SERVE_NAME" "$BMT_NAME" <<'CLEAN' || true
set +e
H="$1"; W="$2"; S="$3"; B="$4"
for c in "$B" "$S" "$H" "$W"; do
  docker stop -t 15 "$c" >/dev/null 2>&1
  docker rm -f "$c" >/dev/null 2>&1
done
CLEAN
  done
}
trap 'cleanup_all; emit_summary "stopped" 130 "stopped by signal"; exit 130' INT TERM HUP

wait_until_remote() {
  # wait_until_remote <host> <inner-cmd> <timeout-seconds> [<friendly-name>]
  local host="$1" cmd="$2" timeout="$3" name="${4:-task}"
  local start now
  start="$(date +%s)"
  while true; do
    if cm_remote_bash "$host" "$cmd" <<'REM' >/dev/null 2>&1
bash -lc "$1"
REM
    then
      cm_inf "[ready] ${name} on ${host}"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout )); then
      cm_err "[timeout] waiting for ${name} on ${host} after ${timeout}s"
      return 1
    fi
    sleep 2
  done
}

# ---------- VALIDATE ----------

cm_phase validate
cm_inf "start_time=${START_TIME}"
cm_inf "run_id=${RUN_ID}"
cm_inf "leader=${LEADER}"
cm_inf "hosts=${HOSTS_CSV} (${NUM_HOSTS})"
cm_inf "bmt_host=${BMT_HOST}"
cm_inf "gpu_type=${GPU_TYPE}"
cm_inf "engine=vllm"
cm_inf "model=${MODEL}"
cm_inf "model_path=${MODEL_PATH}"
cm_inf "bench_data=${BENCH_DATA}"
cm_inf "vllm_port=${VLLM_PORT} ray_port=${RAY_PORT}"
cm_inf "log_dir=${LOG_DIR}"

for h in "${HOSTS[@]}" "$BMT_HOST"; do
  if cm_is_local_host "$h"; then continue; fi
  cm_inf "checking SSH reachability: ${h}"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" "echo ok" >/dev/null 2>&1 \
    || fail_run "SSH unreachable: $h" 22
done

for h in "${HOSTS[@]}"; do
  cm_inf "checking model_path on ${h}: ${MODEL_PATH}"
  cm_remote_bash "$h" "$MODEL_PATH" <<'MP' >/dev/null || fail_run "model_path not found on $h: $MODEL_PATH" 42
[[ -d "$1" ]]
MP
done

# Detect arch on the leader; pick image accordingly.
LEADER_ARCH="$(cm_remote_bash "$LEADER" <<'X'
uname -m
X
)"
LEADER_ARCH="$(echo "$LEADER_ARCH" | tr -d '[:space:]')"
case "$LEADER_ARCH" in
  x86_64|amd64) ARCH="amd64"; AUTO_IMG="$IMG_NVIDIA_AMD64" ;;
  aarch64|arm64) ARCH="arm64"; AUTO_IMG="$IMG_NVIDIA_ARM64" ;;
  *) fail_run "unsupported leader arch: ${LEADER_ARCH}" 23 ;;
esac

local_dockerhub_ref() {
  local image="$1"
  local local_prefix="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}"
  local pull_prefix="${DOCKER_HUB_PULL_PREFIX:-docker.io}"
  case "$image" in
    "${pull_prefix}"/*) printf '%s\n' "${local_prefix}/${image#${pull_prefix}/}" ;;
    "${local_prefix}"/*) printf '%s\n' "$image" ;;
    docker.io/*) printf '%s\n' "${local_prefix}/${image#docker.io/}" ;;
    *) printf '%s\n' "$image" ;;
  esac
}

pull_dockerhub_ref() {
  local image="$1"
  local local_prefix="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}"
  local pull_prefix="${DOCKER_HUB_PULL_PREFIX:-docker.io}"
  case "$image" in
    "${local_prefix}"/*) printf '%s\n' "${pull_prefix}/${image#${local_prefix}/}" ;;
    docker.io/*) printf '%s\n' "${pull_prefix}/${image#docker.io/}" ;;
    *) printf '%s\n' "$image" ;;
  esac
}

VLLM_IMG="$(local_dockerhub_ref "${DOCKER_IMAGE:-$AUTO_IMG}")"

# Probe leader GPU count for default TP.
LEADER_GPUS="$(cm_remote_bash "$LEADER" <<'X'
nvidia-smi -L 2>/dev/null | wc -l | awk '{print $1}'
X
)"
LEADER_GPUS="$(echo "$LEADER_GPUS" | tr -dc '0-9')"
[[ -n "$LEADER_GPUS" && "$LEADER_GPUS" != "0" ]] || fail_run "leader $LEADER: no GPU detected" 60

TP="${TP:-${TP_OVERRIDE:-$LEADER_GPUS}}"
PP="${PP:-${PP_OVERRIDE:-1}}"

cm_inf "arch=${ARCH} image=${VLLM_IMG} leader_gpus=${LEADER_GPUS} TP=${TP} PP=${PP}"

# Bench tunables. CLI > env > default.
# (Note: NUM_PROMPTS may come from --num-prompts; if blank fall back to env then default.)
[[ -z "$NUM_PROMPTS" ]] && NUM_PROMPTS="${NUM_PROMPTS_ENV:-${BENCH_NUM_PROMPTS:-320}}"
CONCURRENCY="${MAX_CONCURRENCY_CLI:-${CONCURRENCY:-32}}"

# Output length: --output-len > legacy SHAREGPT_OSL/RANDOM_OSL > 1024
if [[ -n "$OUTPUT_LEN_CLI" ]]; then
  SHAREGPT_OSL="$OUTPUT_LEN_CLI"
  RANDOM_OSL="$OUTPUT_LEN_CLI"
else
  SHAREGPT_OSL="${SHAREGPT_OSL:-1024}"
  RANDOM_OSL="${RANDOM_OSL:-1024}"
fi
# Input length is only meaningful for random.
RANDOM_ISL="${INPUT_LEN_CLI:-${RANDOM_ISL:-1024}}"

# Dataset path on the host (mounted into the bmt container as /workspace/datasets/...).
# Precedence: --dataset-path > env SHAREGPT_PATH > default under HOST_INFER_DIR.
SHAREGPT_PATH_HOST="${DATASET_PATH_CLI:-${SHAREGPT_PATH:-${HOST_INFER_DIR}/datasets/ShareGPT_V3_unfiltered_cleaned_split.json}}"

if [[ "$DRY_RUN" == "true" ]]; then
  cm_phase dry-run
  if [[ "$TOPOLOGY_MODE" == "single" ]]; then
    cm_inf "would run: single host=${LEADER}, bmt=${BMT_HOST}, vllm_port=${VLLM_PORT}, TP=${TP} PP=${PP}, model_path=${MODEL_PATH}"
  else
    cm_inf "would run: ray head=${LEADER}@${RAY_PORT}, workers=${HOSTS_CSV#${LEADER},}, bmt=${BMT_HOST}, vllm_port=${VLLM_PORT}"
  fi
  emit_summary "success" 0 "dry-run completed"
  exit 0
fi

# ---------- PREPARE: ensure image on every host ----------

cm_phase prepare
for h in "${HOSTS[@]}" "$BMT_HOST"; do
  cm_inf "ensuring image on ${h}: ${VLLM_IMG}"
  PULL_IMAGE="$(pull_dockerhub_ref "$VLLM_IMG")"
  if ! cm_remote_bash "$h" "$VLLM_IMG" "$PULL_IMAGE" "$ARCH" "$TAR_NVIDIA_AMD64" "$TAR_NVIDIA_ARM64" <<'IMG'
set -Eeuo pipefail
IMAGE="$1"; PULL_IMAGE="$2"; ARCH="$3"; TAR_AMD64="$4"; TAR_ARM64="$5"
TAR="$TAR_AMD64"
[[ "$ARCH" == "arm64" ]] && TAR="$TAR_ARM64"
docker_pull_with_retry() {
  echo "[INFO] trying docker pull: $PULL_IMAGE"
  if docker pull "$PULL_IMAGE"; then
    if [[ "$PULL_IMAGE" != "$IMAGE" ]]; then
      docker tag "$PULL_IMAGE" "$IMAGE" || return 1
    fi
    return 0
  fi
  echo "[WARN] docker pull failed: $PULL_IMAGE"
  return 1
}
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[INFO] image already present: $IMAGE"
  exit 0
fi

echo "[WARN] image missing: $IMAGE"
echo "[INFO] trying fallback tar before docker pull: ${TAR:-<none>}"
if [[ -f "$TAR" ]]; then
  if out="$(docker load -i "$TAR" 2>&1)"; then
    echo "$out"
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
      loaded_ref="$(echo "$out" | awk -F': ' '/Loaded image:/ {print $2}' | tail -n 1)"
      if [[ -n "$loaded_ref" ]]; then
        docker tag "$loaded_ref" "$IMAGE" || true
      fi
    fi
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      echo "[INFO] image loaded: $IMAGE"
      exit 0
    fi
    echo "[WARN] loaded tar but expected image tag is still missing: $IMAGE"
  else
    echo "$out"
    echo "[WARN] docker load failed; trying docker pull next: $TAR"
  fi
else
  echo "[WARN] image tar fallback missing; trying docker pull next: $TAR"
fi

if docker_pull_with_retry; then
  exit 0
fi

echo "[ERROR] image not present locally and fallback-load/pull failed: $IMAGE" >&2
exit 24
IMG
  then
    fail_run "failed to ensure image on $h" 24
  fi
done

# ---------- SERVE: launch container(s) + vllm serve ----------
# Sets SERVE_CONTAINER to the container that runs the vllm api server,
# used downstream for crashed-process detection and cleanup.

if [[ "$TOPOLOGY_MODE" == "single" ]]; then
  # =========== SINGLE NODE ===========
  # No Ray cluster. One container on LEADER runs `vllm serve` directly.
  cm_phase serve
  cm_inf "starting single-node vllm serve on ${LEADER} (container=${SERVE_NAME})"
  LEADER_VISIBLE_GPUS="$(gpu_visible_for_host "$LEADER")"
  cm_remote_bash "$LEADER" \
      "$SERVE_NAME" "$VLLM_IMG" "$MODEL" "$MODEL_PATH" "$VLLM_PORT" "$TP" "$PP" "$MAX_MODEL_LEN" "$GPU_MEMORY_UTILIZATION" \
      "$HOST_INFER_DIR" "$HOST_MODELS_DIR" "$ENCODINGS_DIR" "$LEADER_VISIBLE_GPUS" "$EXTRA_ARGS" "$EXTRA_DOCKER_ARGS" <<'SINGLE'
set -Eeuo pipefail
NAME="$1"; IMAGE="$2"; MODEL="$3"; MODEL_PATH="$4"; PORT="$5"; TP="$6"; PP="$7"; MAXLEN="$8"; GPU_UTIL="$9"
HOST_INFER_DIR="${10}"; HOST_MODELS_DIR="${11}"; ENCODINGS_DIR="${12}"; VISIBLE_GPUS="${13}"; SERVE_EXTRA_ARGS="${14:-}"; EXTRA_DOCKER_ARGS="${15:-}"

docker rm -f "$NAME" >/dev/null 2>&1 || true

NGPU=$(nvidia-smi -L 2>/dev/null | wc -l)
[[ "$NGPU" -ge 1 ]] || { echo "[ERROR] no GPU detected"; exit 60; }
GPU_ENV_ARGS=()
if [[ -n "${VISIBLE_GPUS:-}" ]]; then
  NGPU=$(awk -F, '{print NF}' <<< "$VISIBLE_GPUS")
  echo "[INFO] selected_gpus=${VISIBLE_GPUS}"
  GPU_ENV_ARGS=(-e CUDA_VISIBLE_DEVICES="$VISIBLE_GPUS" -e NVIDIA_VISIBLE_DEVICES="$VISIBLE_GPUS")
fi
EXTRA_DOCKER_ARGS_ARR=()
if [[ -n "${EXTRA_DOCKER_ARGS:-}" ]]; then
  read -r -a EXTRA_DOCKER_ARGS_ARR <<< "$EXTRA_DOCKER_ARGS"
fi

# Build the vllm-serve command. Optional serve flags are appended only if set.
MAXLEN_FLAG=""
if [[ -n "$MAXLEN" ]]; then
  MAXLEN_FLAG="--max-model-len ${MAXLEN}"
fi
GPU_UTIL_FLAG=""
if [[ -n "$GPU_UTIL" ]]; then
  GPU_UTIL_FLAG="--gpu-memory-utilization ${GPU_UTIL}"
fi

set -x
docker run -d --name "$NAME" \
  --runtime=nvidia --gpus all --privileged --network host --ipc host \
  --entrypoint /bin/bash \
  "${EXTRA_DOCKER_ARGS_ARR[@]}" \
  -v "${HOST_INFER_DIR}:/workspace" \
  -v "${MODEL_PATH}:/workspace/model:ro" \
  -v "${HOST_MODELS_DIR}:/workspace/models:ro" \
  -v "${ENCODINGS_DIR}:/etc/encodings/:ro" \
  -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  -e VLLM_TARGET_DEVICE=cuda \
  -e VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-INFO}" \
  "${GPU_ENV_ARGS[@]}" \
  "$IMAGE" \
  -lc "mkdir -p /workspace/results && nvidia-smi >/workspace/results/nvidia_preflight.log 2>&1 || true; \
       vllm serve '/workspace/model' \
         --host 0.0.0.0 --port ${PORT} \
         --served-model-name '${MODEL}' \
         --tensor-parallel-size ${TP} \
         --pipeline-parallel-size ${PP} \
         ${MAXLEN_FLAG} \
         ${GPU_UTIL_FLAG} \
         ${SERVE_EXTRA_ARGS} \
       > /workspace/results/vllm_serve_${MODEL//\//_}_tp${TP}_pp${PP}.log 2>&1"
set +x
echo "[INFO] vllm-serve container ${NAME} started"
SINGLE

  SERVE_CONTAINER="$SERVE_NAME"

else
  # =========== MULTI NODE (Ray) ===========
  # ---------- RAY HEAD (on leader) ----------
  cm_phase ray_head
  cm_inf "starting ray head on ${LEADER} (container=${RAY_HEAD_NAME}, port=${RAY_PORT})"
  LEADER_VISIBLE_GPUS="$(gpu_visible_for_host "$LEADER")"
  cm_remote_bash "$LEADER" \
      "$RAY_HEAD_NAME" "$VLLM_IMG" "$RAY_PORT" \
      "$HOST_INFER_DIR" "$HOST_MODELS_DIR" "$MODEL_PATH" "$ENCODINGS_DIR" "$LEADER_VISIBLE_GPUS" "$EXTRA_DOCKER_ARGS" <<'HEAD'
set -Eeuo pipefail
NAME="$1"; IMAGE="$2"; RAY_PORT="$3"
HOST_INFER_DIR="$4"; HOST_MODELS_DIR="$5"; MODEL_PATH="$6"; ENCODINGS_DIR="$7"; VISIBLE_GPUS="$8"; EXTRA_DOCKER_ARGS="${9:-}"

docker rm -f "$NAME" >/dev/null 2>&1 || true

NGPU=$(nvidia-smi -L 2>/dev/null | wc -l)
[[ "$NGPU" -ge 1 ]] || { echo "[ERROR] no GPU on head"; exit 60; }
GPU_ENV_ARGS=()
if [[ -n "${VISIBLE_GPUS:-}" ]]; then
  NGPU=$(awk -F, '{print NF}' <<< "$VISIBLE_GPUS")
  echo "[INFO] selected_gpus=${VISIBLE_GPUS}"
  GPU_ENV_ARGS=(-e CUDA_VISIBLE_DEVICES="$VISIBLE_GPUS" -e NVIDIA_VISIBLE_DEVICES="$VISIBLE_GPUS")
fi
EXTRA_DOCKER_ARGS_ARR=()
if [[ -n "${EXTRA_DOCKER_ARGS:-}" ]]; then
  read -r -a EXTRA_DOCKER_ARGS_ARR <<< "$EXTRA_DOCKER_ARGS"
fi

set -x
docker run -d --name "$NAME" \
  --runtime=nvidia --gpus all --privileged --network host --ipc host \
  --entrypoint /bin/bash \
  "${EXTRA_DOCKER_ARGS_ARR[@]}" \
  -v "${HOST_INFER_DIR}:/workspace" \
  -v "${MODEL_PATH}:/workspace/model:ro" \
  -v "${HOST_MODELS_DIR}:/workspace/models:ro" \
  -v "${ENCODINGS_DIR}:/etc/encodings/:ro" \
  -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  -e VLLM_TARGET_DEVICE=cuda \
  -e VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-INFO}" \
  "${GPU_ENV_ARGS[@]}" \
  "$IMAGE" \
  -lc "ray stop -f >/dev/null 2>&1 || true; \
       ray start --head --port=${RAY_PORT} --num-gpus=${NGPU}; \
       tail -f /dev/null"
set +x
echo "[INFO] ray-head container started"
HEAD

  # Wait for ray status OK on head.
  cm_inf "waiting for ray status on head"
  DEADLINE=$(( $(date +%s) + READY_TIMEOUT_SEC ))
  while true; do
    if cm_remote_bash "$LEADER" "$RAY_HEAD_NAME" <<'CHK' >/dev/null 2>&1
docker exec "$1" bash -lc 'ray status >/dev/null 2>&1'
CHK
    then
      cm_inf "ray head ready"
      break
    fi
    if (( $(date +%s) > DEADLINE )); then
      cleanup_all
      fail_run "ray head not ready in ${READY_TIMEOUT_SEC}s" 28
    fi
    sleep 2
  done

  # ---------- RAY WORKERS ----------
  cm_phase ray_workers
  if (( NUM_HOSTS > 1 )); then
    for w in "${HOSTS[@]:1}"; do
      cm_inf "starting ray worker on ${w} (connecting to ${LEADER}:${RAY_WORKER_PORT})"
      WORKER_VISIBLE_GPUS="$(gpu_visible_for_host "$w")"
      cm_remote_bash "$w" \
          "$RAY_WORKER_NAME" "$VLLM_IMG" "$LEADER" "$RAY_WORKER_PORT" \
          "$HOST_INFER_DIR" "$HOST_MODELS_DIR" "$MODEL_PATH" "$ENCODINGS_DIR" "$WORKER_VISIBLE_GPUS" "$EXTRA_DOCKER_ARGS" <<'WORK'
set -Eeuo pipefail
NAME="$1"; IMAGE="$2"; HEAD="$3"; RAY_WPORT="$4"
HOST_INFER_DIR="$5"; HOST_MODELS_DIR="$6"; MODEL_PATH="$7"; ENCODINGS_DIR="$8"; VISIBLE_GPUS="$9"; EXTRA_DOCKER_ARGS="${10:-}"

docker rm -f "$NAME" >/dev/null 2>&1 || true

NGPU=$(nvidia-smi -L 2>/dev/null | wc -l)
[[ "$NGPU" -ge 1 ]] || { echo "[ERROR] no GPU on worker"; exit 60; }
GPU_ENV_ARGS=()
if [[ -n "${VISIBLE_GPUS:-}" ]]; then
  NGPU=$(awk -F, '{print NF}' <<< "$VISIBLE_GPUS")
  echo "[INFO] selected_gpus=${VISIBLE_GPUS}"
  GPU_ENV_ARGS=(-e CUDA_VISIBLE_DEVICES="$VISIBLE_GPUS" -e NVIDIA_VISIBLE_DEVICES="$VISIBLE_GPUS")
fi
EXTRA_DOCKER_ARGS_ARR=()
if [[ -n "${EXTRA_DOCKER_ARGS:-}" ]]; then
  read -r -a EXTRA_DOCKER_ARGS_ARR <<< "$EXTRA_DOCKER_ARGS"
fi

set -x
docker run -d --name "$NAME" \
  --runtime=nvidia --gpus all --privileged --network host --ipc host \
  --entrypoint /bin/bash \
  "${EXTRA_DOCKER_ARGS_ARR[@]}" \
  -v "${HOST_INFER_DIR}:/workspace" \
  -v "${MODEL_PATH}:/workspace/model:ro" \
  -v "${HOST_MODELS_DIR}:/workspace/models:ro" \
  -v "${ENCODINGS_DIR}:/etc/encodings/:ro" \
  -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_DISABLE_REQUIRE=1 \
  -e VLLM_TARGET_DEVICE=cuda \
  -e VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-INFO}" \
  "${GPU_ENV_ARGS[@]}" \
  "$IMAGE" \
  -lc "ray stop -f >/dev/null 2>&1 || true; \
       ray start --address='${HEAD}:${RAY_WPORT}' --num-gpus=${NGPU}; \
       tail -f /dev/null"
set +x
echo "[INFO] ray-worker container started"
WORK
    done

    # Wait until head sees expected node count
    EXPECTED_NODES="$NUM_HOSTS"
    cm_inf "waiting for head to see ${EXPECTED_NODES} ray nodes"
    DEADLINE=$(( $(date +%s) + READY_TIMEOUT_SEC ))
    while true; do
      NODES_SEEN="$(cm_remote_bash "$LEADER" "$RAY_HEAD_NAME" <<'CHK' 2>/dev/null
docker exec "$1" bash -lc "python -c 'import ray; ray.init(address=\"auto\"); print(len(ray.nodes()))'" 2>/dev/null
CHK
      )"
      NODES_SEEN="$(echo "$NODES_SEEN" | tr -dc '0-9')"
      if [[ "$NODES_SEEN" == "$EXPECTED_NODES" ]]; then
        cm_inf "ray cluster has ${NODES_SEEN} nodes"
        break
      fi
      if (( $(date +%s) > DEADLINE )); then
        cleanup_all
        fail_run "ray cluster did not converge to ${EXPECTED_NODES} nodes (saw ${NODES_SEEN:-0})" 28
      fi
      sleep 3
    done
  fi

  # ---------- VLLM SERVE inside ray-head ----------
  cm_phase serve
  cm_inf "starting vLLM serve inside ${RAY_HEAD_NAME} on ${LEADER}"
  cm_remote_bash "$LEADER" \
      "$RAY_HEAD_NAME" "$MODEL" "$VLLM_PORT" "$TP" "$PP" "$MAX_MODEL_LEN" "$GPU_MEMORY_UTILIZATION" "$LOG_DIR" "$EXTRA_ARGS" <<'SERVE'
set -Eeuo pipefail
CNAME="$1"; MODEL="$2"; PORT="$3"; TP="$4"; PP="$5"; MAXLEN="$6"; GPU_UTIL="$7"; LOG_DIR="$8"; SERVE_EXTRA_ARGS="${9:-}"

mkdir -p "$LOG_DIR"

MAXLEN_FLAG=""
if [[ -n "$MAXLEN" ]]; then
  MAXLEN_FLAG="--max-model-len ${MAXLEN}"
fi
GPU_UTIL_FLAG=""
if [[ -n "$GPU_UTIL" ]]; then
  GPU_UTIL_FLAG="--gpu-memory-utilization ${GPU_UTIL}"
fi

# Use /workspace/models/<MODEL> as the model path inside the container.
docker exec -d "$CNAME" bash -lc "
  mkdir -p /workspace/results && \
  vllm serve '/workspace/model' \
    --host 0.0.0.0 --port ${PORT} \
    --served-model-name '${MODEL}' \
    --distributed-executor-backend ray \
    --tensor-parallel-size ${TP} \
    --pipeline-parallel-size ${PP} \
    ${MAXLEN_FLAG} \
    ${GPU_UTIL_FLAG} \
    ${SERVE_EXTRA_ARGS} \
  > /workspace/results/vllm_serve_${MODEL//\//_}_tp${TP}_pp${PP}.log 2>&1
"
echo "[INFO] vllm serve backgrounded inside ${CNAME}"
SERVE

  SERVE_CONTAINER="$RAY_HEAD_NAME"
fi

# ---------- WAIT for /health ----------

cm_phase wait
cm_inf "waiting up to ${READY_TIMEOUT_SEC}s for vLLM /health on ${LEADER}:${VLLM_PORT}"
DEADLINE=$(( $(date +%s) + READY_TIMEOUT_SEC ))
READY=0
while (( $(date +%s) < DEADLINE )); do
  set +e
  HEALTH="$(cm_remote_bash "$LEADER" "$VLLM_PORT" <<'C' 2>/dev/null
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:$1/health" 2>/dev/null || true
C
  )"
  HEALTH_RC=$?
  set -e
  HEALTH="$(echo "$HEALTH" | tr -dc '0-9')"
  if [[ "$HEALTH" == "200" ]]; then
    READY=1
    cm_inf "vllm /health = 200"
    break
  fi
  cm_inf "vllm not ready ($(date +%T)) http=${HEALTH:-?}"
  # Also detect crashed serve process inside the serve container.
  if ! cm_remote_bash "$LEADER" "$SERVE_CONTAINER" <<'P' >/dev/null 2>&1
docker exec "$1" pgrep -f 'vllm serve' >/dev/null
P
  then
    cm_err "vllm serve process is gone inside ${SERVE_CONTAINER}; dumping recent container logs"
    cm_remote_bash "$LEADER" "$SERVE_CONTAINER" <<'DUMP' || true
set +e
docker logs --tail 200 "$1" || true
if docker exec "$1" test -d /workspace/results >/dev/null 2>&1; then
  docker exec "$1" bash -lc 'for f in /workspace/results/*.log; do echo "===== $f ====="; tail -200 "$f"; done' || true
fi
DUMP
    cleanup_all
    fail_run "vllm serve process is gone inside ${SERVE_CONTAINER}" 29
  fi
  sleep 3
done

if (( READY != 1 )); then
  cleanup_all
  fail_run "vllm not ready in ${READY_TIMEOUT_SEC}s" 28
fi

# ---------- BENCH on bmt_host ----------

cm_phase bench
mkdir -p "$RESULT_DIR"
cm_inf "running bench on ${BMT_HOST} against http://${LEADER}:${VLLM_PORT}"

# Compute container-side dataset path and an optional extra mount.
# If SHAREGPT_PATH_HOST is under HOST_INFER_DIR (the default /workspace mount),
# translate to /workspace/...; otherwise mount its parent dir at the same
# absolute path inside the container so the file is reachable.
SHAREGPT_PATH_CTR=""
DATASET_EXTRA_MOUNT=""
if [[ -n "$SHAREGPT_PATH_HOST" ]]; then
  if [[ "$SHAREGPT_PATH_HOST" == "${HOST_INFER_DIR}/"* ]]; then
    SHAREGPT_PATH_CTR="/workspace/${SHAREGPT_PATH_HOST#${HOST_INFER_DIR}/}"
  else
    SHAREGPT_PATH_CTR="$SHAREGPT_PATH_HOST"
    DATASET_EXTRA_MOUNT="$(dirname "$SHAREGPT_PATH_HOST")"
  fi
fi

case "$BENCH_DATA" in
  sharegpt)
    BENCH_DATASET_ARGS=(
      --dataset-name sharegpt
      --dataset-path "$SHAREGPT_PATH_CTR"
      --sharegpt-output-len "$SHAREGPT_OSL"
    )
    ;;
  random)
    BENCH_DATASET_ARGS=(
      --dataset-name random
      --random-input-len "$RANDOM_ISL"
      --random-output-len "$RANDOM_OSL"
    )
    ;;
esac

set +e
cm_remote_bash "$BMT_HOST" \
    "$BMT_NAME" "$VLLM_IMG" "$MODEL" \
    "$LEADER" "$VLLM_PORT" "$NUM_PROMPTS" "$CONCURRENCY" "$REQUEST_RATE" \
    "$RESULT_DIR" "" \
    "$HOST_INFER_DIR" "$HOST_MODELS_DIR" "$ENCODINGS_DIR" \
    "$DATASET_EXTRA_MOUNT" \
    "${BENCH_DATASET_ARGS[@]}" <<'BENCH'
set -Eeuo pipefail
BMT_NAME="$1"; IMG="$2"; MODEL="$3"
SERVE_HOST="$4"; SERVE_PORT="$5"; NUM_PROMPTS="$6"; CONCURRENCY="$7"; RR="$8"
RESULT_DIR="$9"; EXTRA="${10}"
HOST_INFER_DIR="${11}"; HOST_MODELS_DIR="${12}"; ENCODINGS_DIR="${13}"
DATASET_EXTRA_MOUNT="${14}"
shift 14
DARGS=( "$@" )

mkdir -p "$RESULT_DIR"
docker rm -f "$BMT_NAME" >/dev/null 2>&1 || true

# Optional extra mount for user-supplied dataset paths outside HOST_INFER_DIR.
EXTRA_MOUNT_FLAGS=()
if [[ -n "$DATASET_EXTRA_MOUNT" && -d "$DATASET_EXTRA_MOUNT" ]]; then
  EXTRA_MOUNT_FLAGS=(-v "${DATASET_EXTRA_MOUNT}:${DATASET_EXTRA_MOUNT}:ro")
fi

# Compose the inner bench command as a mounted script instead of a long
# `bash -c "... ${DARGS[@]} ..."` string.  Expanding DARGS inside a quoted
# docker command can leak args such as `--dataset-name` into docker-run option
# parsing, where Docker may treat them as a `-v` value and fail with
# "invalid characters for a local volume name".
HOSTNAME_TAG="$(hostname)"
RESULT_FILENAME="bench_serving.json"
LOG_FILENAME="${HOSTNAME_TAG}_${MODEL}_vllm_out.log"
BENCH_SCRIPT="${RESULT_DIR}/run_vllm_bench.sh"

BENCH_CMD=(
  vllm bench serve
  --backend openai
  --base-url "http://${SERVE_HOST}:${SERVE_PORT}"
  --endpoint /v1/completions
  --model "$MODEL"
  --served-model-name "$MODEL"
)
BENCH_CMD+=( "${DARGS[@]}" )
BENCH_CMD+=(
  --num-prompts "$NUM_PROMPTS"
  --max-concurrency "$CONCURRENCY"
  --request-rate "$RR"
  --save-result
  --save-detailed
  --result-dir "$RESULT_DIR"
  --result-filename "$RESULT_FILENAME"
)
if [[ -n "${EXTRA:-}" ]]; then
  # Preserve the historical behavior where EXTRA is a user-supplied shell
  # fragment, while keeping normal dataset args as safely quoted argv tokens.
  read -r -a EXTRA_ARGS_ARR <<< "$EXTRA"
  BENCH_CMD+=( "${EXTRA_ARGS_ARR[@]}" )
fi

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -Eeuo pipefail\n'
  printf 'rm -f %q %q\n' "${RESULT_DIR}/${RESULT_FILENAME}" "${RESULT_DIR}/${LOG_FILENAME}"
  printf 'export TIKTOKEN_ENCODINGS_BASE=%q\n' '/etc/encodings'
  printf 'export CUDA_VISIBLE_DEVICES=%q\n' ''
  printf '%q ' "${BENCH_CMD[@]}"
  printf ' | tee %q\n' "${RESULT_DIR}/${LOG_FILENAME}"
} > "$BENCH_SCRIPT"
chmod +x "$BENCH_SCRIPT"
echo "[INFO] bench_script=${BENCH_SCRIPT}"

set -x
docker run --rm \
  --name "$BMT_NAME" \
  --network host --ipc host \
  --entrypoint /bin/bash \
  -e serve_host="$SERVE_HOST" -e serve_port="$SERVE_PORT" \
  -e MODEL_NAME="$MODEL" -e NUM_PROMPTS="$NUM_PROMPTS" \
  -e CONCURRENCY="$CONCURRENCY" -e RR="$RR" \
  -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings \
  -e CUDA_VISIBLE_DEVICES="" \
  -v "${HOST_INFER_DIR}:/workspace" \
  -v "${HOST_MODELS_DIR}:/workspace/models:ro" \
  -v "${ENCODINGS_DIR}:/etc/encodings/:ro" \
  -v "${RESULT_DIR}:${RESULT_DIR}" \
  "${EXTRA_MOUNT_FLAGS[@]}" \
  "$IMG" \
  "$BENCH_SCRIPT"
set +x

ls -l "${RESULT_DIR}/${RESULT_FILENAME}" || echo "[WARN] result JSON not found"
ls -l "${RESULT_DIR}/${LOG_FILENAME}" || echo "[WARN] result log not found"
BENCH
BENCH_EXIT=$?
set -e

# ---------- COLLECT ----------

cm_phase collect
cm_inf "bench_exit=${BENCH_EXIT}"

cleanup_all

cm_phase done
if [[ "$BENCH_EXIT" -eq 0 ]]; then
  emit_summary "success" 0 "vllm bench completed"
  exit 0
else
  emit_summary "failed" "$BENCH_EXIT" "vllm bench failed; inspect ${LOG_DIR}/run.log"
  exit "$BENCH_EXIT"
fi
