#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./mlperf_train_v51.sh \
    --run-id train_v51_001 \
    --gpu-type H100 \
    --host gpu-node03 \
    --benchmark llama2_70b_lora

Usually called by:
  ./mlperf_run.sh --suite training --version v5.1 ...

Supported:
  MLPerf Training v5.1

Benchmarks:
  llama2_70b_lora
  llama31_8b

Supported GPU:
  V100
  A100
  H100
  RTX6000
  RTX_PRO_6000
  GH200
  B300

V100/A100 are enabled for platform validation and reuse the x86 Docker image path used by the other non-GH200 GPUs.

Data root:
  /opt/poc-platform/data

Data:
  llama2_70b_lora:
    training_llama2_70b_lora/data
    training_llama2_70b_lora/model

  llama31_8b:
    training_llama31_8b/8b

Docker image tar root:
  /opt/poc-platform/data/dockerimgs

Options:
  --stop
  --run-id <id>
  --gpu-type <gpu>
  --host <hostname>
  --benchmark llama2_70b_lora|llama31_8b
  --docker-image <image>
  --mlperf-root <path>
  --data-root <path>
  --log-root <path>
  --config <path>
  --dry-run
EOF
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

MODE="run"
RUN_ID=""
GPU_TYPE=""
HOST=""
BENCHMARK="llama2_70b_lora"
DOCKER_IMAGE=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
LOG_ROOT="/opt/poc-platform/mlperf_logs_train_v51"
CONFIG_PATH=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE="stop"; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --benchmark) BENCHMARK="${2:-}"; shift 2 ;;
    --docker-image) DOCKER_IMAGE="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || die "--run-id is required"
[[ -n "$HOST" ]] || die "--host is required"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid run-id"
[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host"
[[ "$MLPERF_ROOT" == /* ]] || die "--mlperf-root must be absolute"
[[ "$DATA_ROOT" == /* ]] || die "--data-root must be absolute"
[[ "$LOG_ROOT" == /* ]] || die "--log-root must be absolute"

SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"
CONTAINER_NAME="mlperf_train_v51_${SAFE_RUN_ID}"

LOCAL_SHORT="$(hostname -s 2>/dev/null || hostname)"
LOCAL_FQDN="$(hostname -f 2>/dev/null || hostname)"

is_local_host() {
  [[ "$1" == "localhost" || "$1" == "127.0.0.1" || "$1" == "$LOCAL_SHORT" || "$1" == "$LOCAL_FQDN" ]]
}

remote_bash() {
  if is_local_host "$HOST"; then
    bash -s -- "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" bash -s -- "$@"
  fi
}

if [[ "$MODE" == "stop" ]]; then
  echo "[PHASE] stop"
  remote_bash "$CONTAINER_NAME" <<'REMOTE_STOP'
set -Eeuo pipefail
CONTAINER_NAME="$1"

if ! command -v docker >/dev/null 2>&1; then
  echo "[WARN] docker unavailable"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "[INFO] docker stop -t 30 ${CONTAINER_NAME}"
    docker stop -t 30 "$CONTAINER_NAME" || docker rm -f "$CONTAINER_NAME" || true
  else
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
else
  echo "[INFO] no container found: ${CONTAINER_NAME}"
fi
REMOTE_STOP
  echo "[PHASE] done"
  exit 0
fi

[[ -n "$GPU_TYPE" ]] || die "--gpu-type is required"

case "$GPU_TYPE" in
  V100|A100|H100|GH200|B300|RTX6000|RTX_PRO_6000) ;;
  *) die "Training v5.1 supports only V100, A100, H100, RTX6000, RTX_PRO_6000, GH200, B300. Invalid gpu-type: ${GPU_TYPE}" ;;
esac

case "$BENCHMARK" in
  llama2_70b_lora|llama31_8b) ;;
  *) die "Unsupported benchmark: $BENCHMARK" ;;
esac

if ! is_local_host "$HOST"; then
  echo "[INFO] checking SSH reachability: ${HOST}"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "echo ok" >/dev/null 2>&1 || die "SSH unreachable: $HOST"
fi

# Advanced MLPerf args arrive as environment variables from backend/runner.py.
# When HOST is remote, ssh does not preserve arbitrary caller env, so serialize an
# allowlist and evaluate it inside the remote heredoc before Docker is launched.
build_env_exports() {
  local env_name q
  local out=""
  for env_name in \
    POC_PLATFORM_DOCKERIMG_DIRS \
    MLPERF_TRAIN_IMAGE_TAR \
    MLPERF_RUN_CMD \
    MLPERF_ENTRY_SCRIPT \
    MLPERF_MAX_STEPS \
    MLPERF_LIMIT_VAL_BATCHES \
    MLPERF_VAL_CHECK_INTERVAL \
    MLPERF_LOG_EVERY_N_STEPS \
    MLPERF_ENABLE_PROGRESS_BAR \
    MLPERF_EXTRA_OVERRIDES \
    TRAINER_PRECISION \
    MLPERF_TRAINER_PRECISION \
    GPU_ARCH \
    NUM_GPUS \
    MLPERF_NUM_GPUS \
    TP \
    PP \
    CP \
    MBS \
    MINIBS \
    GBS \
    MAX_SEQLEN \
    SEQ_LENGTH \
    MAX_STEPS \
    LIMIT_VAL_BATCHES \
    VAL_CHECK_INTERVAL \
    TENSOR_MODEL_PARALLEL \
    PIPELINE_MODEL_PARALLEL \
    CONTEXT_PARALLEL \
    MICRO_BATCH_SIZE \
    GLOBAL_BATCH_SIZE \
    LR \
    WARMUP_STEPS \
    TARGET_LOG_PPL \
    FP8 \
    FP8_HYBRID \
    MASTER_ADDR \
    MASTER_PORT \
    NCCL_DEBUG \
    NCCL_IB_HCA \
    NCCL_SOCKET_IFNAME \
    NCCL_IB_DISABLE \
    NCCL_P2P_DISABLE \
    NCCL_SHM_DISABLE \
    NCCL_NVLS_ENABLE \
    NCCL_CUMEM_ENABLE \
    NCCL_MNNVL_ENABLE \
    NCCL_NET_PLUGIN \
    NCCL_TUNER_PLUGIN \
    NCCL_NET \
    NCCL_COLLNET_ENABLE \
    UCX_TLS \
    UCX_NET_DEVICES \
    UCX_IB_GPU_DIRECT_RDMA \
    UCX_LOG_LEVEL \
    UCC_TLS \
    UCC_LOG_LEVEL \
    UCX_HANDLE_ERRORS \
    UCX_ERROR_SIGNALS \
    CUDA_LAUNCH_BLOCKING \
    TORCH_SHOW_CPP_STACKTRACES \
    TORCH_CPP_LOG_LEVEL \
    PYTHONFAULTHANDLER \
    NVTE_DEBUG \
    NVTE_DEBUG_LEVEL \
    MLPERF_CUDA_VISIBLE_DEVICES \
    MLPERF_NODE_MODE \
    MLPERF_TRAIN_NNODES \
    MLPERF_NODE_RANK \
    MLPERF_WORLD_SIZE \
    WORLD_SIZE_GPUS \
    DOCKER_HUB_IMAGE_PREFIX \
    DOCKER_HUB_PULL_PREFIX \
    DOCKER_REGISTRY \
    DOCKER_HTTP_PROXY \
    DOCKER_HTTPS_PROXY \
    DOCKER_INSECURE_REGISTRIES
  do
    if [[ -n "${!env_name:-}" ]]; then
      printf -v q '%q' "${!env_name}"
      out+="export ${env_name}=${q}"$'\n'
    fi
  done
  printf '%s' "$out"
}

ADV_ENV_EXPORTS="$(build_env_exports)"
ADV_ENV_B64=""
if [[ -n "$ADV_ENV_EXPORTS" ]]; then
  ADV_ENV_B64="$(printf '%s' "$ADV_ENV_EXPORTS" | base64 | tr -d '\n')"
  echo "[INFO] advanced env forwarded: $(printf '%s' "$ADV_ENV_EXPORTS" | sed -E 's/^export ([A-Za-z0-9_]+)=.*/\1/' | paste -sd, -)"
fi

remote_bash \
  "$RUN_ID" \
  "$CONTAINER_NAME" \
  "$GPU_TYPE" \
  "$HOST" \
  "$BENCHMARK" \
  "${DOCKER_IMAGE:-__EMPTY__}" \
  "$MLPERF_ROOT" \
  "$DATA_ROOT" \
  "$LOG_ROOT" \
  "$DRY_RUN" \
  "$ADV_ENV_B64" <<'REMOTE_RUN'
set -Eeuo pipefail
trap 'echo "[FATAL] command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

RUN_ID="$1"
CONTAINER_NAME="$2"
GPU_TYPE="$3"
HOST="$4"
BENCHMARK="$5"
USER_DOCKER_IMAGE="$6"
MLPERF_ROOT="$7"
DATA_ROOT="$8"
LOG_ROOT="$9"
DRY_RUN="${10}"
ADV_ENV_B64="${11:-}"
if [[ -n "$ADV_ENV_B64" ]]; then
  ADV_ENV_EXPORTS="$(printf '%s' "$ADV_ENV_B64" | base64 -d)"
  eval "$ADV_ENV_EXPORTS"
fi

print_effective_mlperf_args() {
  local env_name
  echo "[INFO] effective advanced env after remote forwarding:"
  for env_name in \
    MLPERF_RUN_CMD MLPERF_MAX_STEPS MLPERF_LIMIT_VAL_BATCHES MLPERF_VAL_CHECK_INTERVAL MLPERF_LOG_EVERY_N_STEPS MLPERF_ENABLE_PROGRESS_BAR MLPERF_EXTRA_OVERRIDES TRAINER_PRECISION MLPERF_TRAINER_PRECISION \
    GPU_ARCH NUM_GPUS MLPERF_NUM_GPUS TP PP CP MBS MINIBS GBS MAX_SEQLEN SEQ_LENGTH MAX_STEPS LIMIT_VAL_BATCHES VAL_CHECK_INTERVAL \
    TENSOR_MODEL_PARALLEL PIPELINE_MODEL_PARALLEL CONTEXT_PARALLEL MICRO_BATCH_SIZE GLOBAL_BATCH_SIZE \
    LR WARMUP_STEPS TARGET_LOG_PPL FP8 FP8_HYBRID MLPERF_NODE_MODE MLPERF_TRAIN_NNODES MLPERF_NODE_RANK MLPERF_WORLD_SIZE WORLD_SIZE_GPUS MASTER_ADDR MASTER_PORT NCCL_DEBUG NCCL_IB_HCA NCCL_SOCKET_IFNAME NCCL_IB_DISABLE
  do
    if [[ -n "${!env_name:-}" ]]; then
      printf '[INFO]   %s=%q\n' "$env_name" "${!env_name}"
    fi
  done
}
print_effective_mlperf_args

[[ "$USER_DOCKER_IMAGE" == "__EMPTY__" ]] && USER_DOCKER_IMAGE=""

START_TIME="$(date --iso-8601=seconds)"
START_EPOCH="$(date +%s)"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_ROOT}/${STAMP}_${HOST}_training_v5.1_${BENCHMARK}_${RUN_ID}"
RESULT_DIR="${LOG_DIR}/results"

DOCKERIMG_DIR="${DATA_ROOT}/dockerimgs"

LLAMA2_REPO="${MLPERF_ROOT}/training_results_v5.1-main/NVIDIA/benchmarks/llama2_70b_lora/implementations/nemo"
LLAMA2_IMAGE_SM90="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90"
LLAMA2_TAR_SM90="${DOCKERIMG_DIR}/mlperf-nvidia_llama2_70b_lora-pyt-sm90.tar.gz"
LLAMA2_DATA_DIR="${DATA_ROOT}/training_llama2_70b_lora/data"
LLAMA2_MODEL_DIR="${DATA_ROOT}/training_llama2_70b_lora/model"

LLAMA31_REPO="${MLPERF_ROOT}/training_results_v5.1-main/NVIDIA/benchmarks/llama31_8b/implementations/nemo"
LLAMA31_IMAGE_SM90="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/donnmyth/mlperf-nvidia:llama31_8b-pyt-sm90"
LLAMA31_TAR_SM90="${DOCKERIMG_DIR}/llama31_8b-pyt-sm90.tar"
LLAMA31_DATA_DIR="${DATA_ROOT}/training_llama31_8b/8b"

CERT_FILE="${DATA_ROOT}/certs/ca-certificates.crt"

REGISTRY_HOST="${DOCKER_REGISTRY:-}"
REGISTRY_USER="${DOCKER_USERNAME:-}"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_summary() {
  local status="$1"
  local code="$2"
  local hint="$3"
  local end_time
  local end_epoch
  local duration

  end_time="$(date --iso-8601=seconds)"
  end_epoch="$(date +%s)"
  duration="$((end_epoch - START_EPOCH))"

  printf 'MLPerf_RESULT_JSON={'
  printf '"status":"%s",' "$(json_escape "$status")"
  printf '"run_id":"%s",' "$(json_escape "$RUN_ID")"
  printf '"host":"%s",' "$(json_escape "$HOST")"
  printf '"gpu_type":"%s",' "$(json_escape "$GPU_TYPE")"
  printf '"suite":"training",'
  printf '"mlperf_version":"v5.1",'
  printf '"benchmark":"%s",' "$(json_escape "$BENCHMARK")"
  printf '"docker_image":"%s",' "$(json_escape "$DOCKER_IMAGE")"
  printf '"docker_container":"%s",' "$(json_escape "$CONTAINER_NAME")"
  printf '"start_time":"%s",' "$(json_escape "$START_TIME")"
  printf '"end_time":"%s",' "$(json_escape "$end_time")"
  printf '"duration_sec":%s,' "$duration"
  printf '"log_dir":"%s",' "$(json_escape "$LOG_DIR")"
  printf '"exit_code":%s,' "$code"
  printf '"result_hint":"%s"' "$(json_escape "$hint")"
  printf '}\n'
}

fail_run() {
  echo "[ERROR] $1"
  emit_summary "failed" "${2:-1}" "$1"
  exit "${2:-1}"
}

host_arch() {
  uname -m 2>/dev/null || echo unknown
}

normalize_arch() {
  case "$1" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64|arm64/v8) echo arm64 ;;
    *) echo "$1" ;;
  esac
}

docker_image_arch() {
  docker image inspect "$1" --format '{{.Architecture}}' 2>/dev/null || true
}

validate_image_platform() {
  local harch
  local iarch

  harch="$(normalize_arch "$(host_arch)")"
  iarch="$(docker_image_arch "$1")"

  echo "[INFO] host_arch=${harch}"
  echo "[INFO] image_arch=${iarch:-unknown}"

  if [[ -n "$iarch" && "$harch" == "arm64" && "$iarch" == "amd64" ]]; then
    fail_run "Image architecture mismatch: host arm64, image amd64" 67
  fi

  if [[ -n "$iarch" && "$harch" == "amd64" && "$iarch" == "arm64" ]]; then
    fail_run "Image architecture mismatch: host amd64, image arm64" 67
  fi
}

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

normalize_image_ref() {
  local_dockerhub_ref "$1"
}

configure_docker_for_pull() {
  # Full host bootstrap is handled by scripts/common.sh before this script runs.
  # Direct invocations may still provide registry credentials in the environment.
  if [[ -n "${DOCKER_REGISTRY:-}" && -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    printf '%s\n' "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin >/dev/null || true
  fi
}

docker_pull_with_retry() {
  local local_image="$1"
  local pull_image
  pull_image="$(pull_dockerhub_ref "$local_image")"
  echo "[INFO] trying docker pull: $pull_image"
  if docker pull "$pull_image"; then
    if [[ "$pull_image" != "$local_image" ]]; then
      docker tag "$pull_image" "$local_image" || return 1
    fi
    return 0
  fi
  echo "[WARN] docker pull failed; re-applying Docker proxy/daemon config and retrying: $pull_image"
  configure_docker_for_pull || true
  echo "[INFO] retrying docker pull after Docker config refresh: $pull_image"
  docker pull "$pull_image" || return 1
  if [[ "$pull_image" != "$local_image" ]]; then
    docker tag "$pull_image" "$local_image" || return 1
  fi
}

ensure_image() {
  local image="$1"
  local tar_file="$2"
  local out=""
  local loaded_ref=""

  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "[INFO] Docker image exists: $image"
    validate_image_platform "$image"
    return 0
  fi

  echo "[WARN] Docker image missing: $image"
  echo "[INFO] trying fallback tar before docker pull: ${tar_file:-<none>}"

  # Fall back to extra tar directories when the primary path is absent — the
  # staging area is not always under this host's DATA_ROOT (a shared mgmt
  # server, a different mount on a test host). POC_PLATFORM_DOCKERIMG_DIRS is
  # a colon-separated list searched by basename, set in .env.
  if [[ -n "$tar_file" && ! -f "$tar_file" && -n "${POC_PLATFORM_DOCKERIMG_DIRS:-}" ]]; then
    _tar_base="$(basename "$tar_file")"
    IFS=':' read -ra _tar_dirs <<< "$POC_PLATFORM_DOCKERIMG_DIRS"
    for _tar_dir in "${_tar_dirs[@]}"; do
      [[ -n "$_tar_dir" ]] || continue
      if [[ -f "${_tar_dir}/${_tar_base}" ]]; then
        echo "[INFO] tar not at primary path; using ${_tar_dir}/${_tar_base}"
        tar_file="${_tar_dir}/${_tar_base}"
        break
      fi
    done
  fi

  if [[ -n "$tar_file" && -f "$tar_file" ]]; then
    if out="$(docker load -i "$tar_file" 2>&1)"; then
      echo "$out"
      if docker image inspect "$image" >/dev/null 2>&1; then
        validate_image_platform "$image"
        return 0
      fi
      loaded_ref="$(echo "$out" | awk -F': ' '/Loaded image:/ {print $2}' | tail -n 1)"
      if [[ -n "$loaded_ref" ]]; then
        docker tag "$loaded_ref" "$image" || true
        if docker image inspect "$image" >/dev/null 2>&1; then
          validate_image_platform "$image"
          return 0
        fi
      fi
      echo "[WARN] fallback tar loaded but expected image tag is still missing: $image"
    else
      echo "$out"
      echo "[WARN] docker load failed; trying docker pull next: $tar_file"
    fi
  else
    echo "[WARN] fallback tar not found; trying docker pull next: ${tar_file:-<empty>}"
  fi

  if docker_pull_with_retry "$image"; then
    validate_image_platform "$image"
    return 0
  fi

  fail_run "Docker image missing and fallback-load/pull failed: $image" 24
}

gpu_count() {
  local n
  n="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | wc -l | awk '{print $1}')"
  [[ -n "$n" && "$n" != "0" ]] || fail_run "No NVIDIA GPU detected" 60
  printf '%s' "$n"
}

gpu_name() {
  nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 | sed 's/^ *//;s/ *$//' || true
}

cuda_devices() {
  local n="$1"
  local out=""
  local i

  for ((i=0; i<n; i++)); do
    [[ -z "$out" ]] && out="$i" || out="${out},${i}"
  done

  printf '%s' "$out"
}

cleanup() {
  if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    docker stop -t 30 "$CONTAINER_NAME" >/dev/null 2>&1 || docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

trap 'cleanup; emit_summary "stopped" 130 "stopped by signal"; exit 130' INT TERM HUP

mkdir -p "$LOG_DIR"
exec > >(tee -a "${LOG_DIR}/run.log") 2>&1

echo "[PHASE] validate"
echo "[INFO] start_time=${START_TIME}"
echo "[INFO] run_id=${RUN_ID}"
echo "[INFO] host=${HOST}"
echo "[INFO] gpu_type=${GPU_TYPE}"
echo "[INFO] benchmark=${BENCHMARK}"
echo "[INFO] mlperf_version=v5.1"
echo "[INFO] log_dir=${LOG_DIR}"

command -v docker >/dev/null 2>&1 || fail_run "docker unavailable" 20
command -v nvidia-smi >/dev/null 2>&1 || fail_run "nvidia-smi unavailable" 21

case "$GPU_TYPE" in
  V100|A100|H100|GH200|B300|RTX6000|RTX_PRO_6000) ;;
  *) fail_run "Training v5.1 supports only V100, A100, H100, RTX6000, RTX_PRO_6000, GH200, B300. Invalid gpu-type: ${GPU_TYPE}" 69 ;;
esac

GPU_COUNT="$(gpu_count)"
GPU_NAME="$(gpu_name)"
REQUESTED_NUM_GPUS="${NUM_GPUS:-${MLPERF_NUM_GPUS:-}}"
if [[ -n "$REQUESTED_NUM_GPUS" ]]; then
  [[ "$REQUESTED_NUM_GPUS" =~ ^[0-9]+$ ]] || fail_run "NUM_GPUS must be a positive integer: ${REQUESTED_NUM_GPUS}" 70
  (( REQUESTED_NUM_GPUS >= 1 )) || fail_run "NUM_GPUS must be >= 1" 70
  (( REQUESTED_NUM_GPUS <= GPU_COUNT )) || fail_run "NUM_GPUS(${REQUESTED_NUM_GPUS}) exceeds detected GPUs(${GPU_COUNT}) on ${HOST}" 70
  GPU_COUNT="$REQUESTED_NUM_GPUS"
fi
export MLPERF_NUM_GPUS="$GPU_COUNT"
CUDA_VISIBLE_DEVICES_VALUE="${MLPERF_CUDA_VISIBLE_DEVICES:-$(cuda_devices "$GPU_COUNT")}"
if [[ -n "${MLPERF_CUDA_VISIBLE_DEVICES:-}" ]]; then
  GPU_COUNT="$(awk -F, '{print NF}' <<< "$MLPERF_CUDA_VISIBLE_DEVICES")"
  export MLPERF_NUM_GPUS="$GPU_COUNT"
fi

case "$BENCHMARK" in
  llama2_70b_lora)
    case "$GPU_TYPE" in
      GH200)
        [[ -n "$USER_DOCKER_IMAGE" ]] || fail_run "training v5.1 llama2_70b_lora on GH200 requires --docker-image with v5.1 arm64 image." 68
        DOCKER_IMAGE="$USER_DOCKER_IMAGE"
        FALLBACK_TAR=""
        ;;
      V100|A100|H100|B300|RTX6000|RTX_PRO_6000)
        # -sm90 is built with NVTE_CUDA_ARCHS="89;90;100a;103a", so despite the
        # name it also covers Ada and datacenter Blackwell. Keeping every
        # non-GH200 part on this one image is both wider coverage than the
        # blackwell-only tag and one less tar to stage offline.
        DOCKER_IMAGE="${USER_DOCKER_IMAGE:-$LLAMA2_IMAGE_SM90}"
        FALLBACK_TAR="$LLAMA2_TAR_SM90"
        ;;
    esac

    BENCH_DIR="$LLAMA2_REPO"
    DATA_DIR="$LLAMA2_DATA_DIR"
    MODEL_DIR="$LLAMA2_MODEL_DIR"

    [[ -d "$BENCH_DIR" ]] || fail_run "Repo missing: $BENCH_DIR" 23
    [[ -f "${DATA_DIR}/train.npy" ]] || fail_run "Missing data: ${DATA_DIR}/train.npy" 41
    [[ -f "${DATA_DIR}/validation.npy" ]] || fail_run "Missing data: ${DATA_DIR}/validation.npy" 41
    [[ -d "$MODEL_DIR" ]] || fail_run "Model missing: $MODEL_DIR" 42
    ;;

  llama31_8b)
    case "$GPU_TYPE" in
      GH200)
        [[ -n "$USER_DOCKER_IMAGE" ]] || fail_run "training v5.1 llama31_8b on GH200 requires --docker-image with v5.1 arm64 image." 68
        DOCKER_IMAGE="$USER_DOCKER_IMAGE"
        FALLBACK_TAR=""
        ;;
      V100|A100|H100|B300|RTX6000|RTX_PRO_6000)
        # See the llama2_70b_lora branch: -sm90 carries 89;90;100a;103a.
        DOCKER_IMAGE="${USER_DOCKER_IMAGE:-$LLAMA31_IMAGE_SM90}"
        FALLBACK_TAR="$LLAMA31_TAR_SM90"
        ;;
    esac

    BENCH_DIR="$LLAMA31_REPO"
    DATA_DIR="$LLAMA31_DATA_DIR"
    MODEL_DIR=""

    [[ -d "$BENCH_DIR" ]] || fail_run "Repo missing: $BENCH_DIR" 23
    [[ -f "${DATA_DIR}/c4-train.en_6_text_document.bin" ]] || fail_run "Missing llama31 data bin: ${DATA_DIR}" 41
    [[ -f "${DATA_DIR}/c4-train.en_6_text_document.idx" ]] || fail_run "Missing llama31 data idx: ${DATA_DIR}" 41
    [[ -d "${DATA_DIR}/tokenizer" ]] || fail_run "Missing llama31 tokenizer: ${DATA_DIR}/tokenizer" 41
    ;;

  *)
    fail_run "Unsupported benchmark: $BENCHMARK" 26
    ;;
esac

DOCKER_IMAGE="$(normalize_image_ref "$DOCKER_IMAGE")"
echo "[INFO] docker_image=${DOCKER_IMAGE}"
echo "[INFO] fallback_tar=${FALLBACK_TAR:-<none>}"
echo "[INFO] bench_dir=${BENCH_DIR}"
echo "[INFO] data_dir=${DATA_DIR}"
echo "[INFO] model_dir=${MODEL_DIR:-<none>}"
echo "[INFO] dockerimg_dir=${DOCKERIMG_DIR}"
echo "[INFO] cert_file=${CERT_FILE}"
echo "[INFO] gpu_count=${GPU_COUNT}"
echo "[INFO] gpu_name=${GPU_NAME}"
echo "[INFO] cuda_visible_devices=${CUDA_VISIBLE_DEVICES_VALUE}"

# Overriding the image with --docker-image leaves FALLBACK_TAR pointing at the
# default image's tar, which then loads the wrong image and falls through to a
# pull. MLPERF_TRAIN_IMAGE_TAR names the matching tar, mirroring
# MLPERF_INFER_IMAGE_TAR on the inference side.
FALLBACK_TAR="${MLPERF_TRAIN_IMAGE_TAR:-$FALLBACK_TAR}"
echo "[INFO] fallback_tar=${FALLBACK_TAR:-<none>}"
ensure_image "$DOCKER_IMAGE" "$FALLBACK_TAR"

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  fail_run "Container already exists: $CONTAINER_NAME" 25
fi

echo "[PHASE] prepare"

if [[ "$BENCHMARK" == "llama2_70b_lora" ]]; then
  CONTAINER_CMD='
set -Eeuo pipefail
trap '"'"'echo "[CONTAINER][FATAL] command failed at line ${LINENO}: ${BASH_COMMAND}" >&2'"'"' ERR

restore_train_py() {
  if [[ -n "${TRAIN_PY_BAK:-}" && -f "${TRAIN_PY_BAK}" ]]; then
    cp -f "${TRAIN_PY_BAK}" ./train.py || true
    rm -f "${TRAIN_PY_BAK}" || true
    echo "[CONTAINER] restored train.py"
  fi
}

trap restore_train_py EXIT

cd "$BENCH_DIR"
mkdir -p "$RESULT_DIR"

TRAIN_PY_BAK="/tmp/train.py.${MLPERF_RUN_ID}.bak"
cp -f ./train.py "$TRAIN_PY_BAK"

python3 - <<PY
from pathlib import Path

p = Path("train.py")
s = p.read_text()

s = s.replace(
    '"'"'rank = int(os.getenv("SLURM_PROCID", 0))'"'"',
    '"'"'rank = int(os.getenv("RANK", os.getenv("SLURM_PROCID", 0)))'"'"',
)
s = s.replace(
    '"'"'torch.cuda.set_device(int(os.getenv("SLURM_LOCALID", "0")))'"'"',
    '"'"'torch.cuda.set_device(int(os.getenv("LOCAL_RANK", os.getenv("SLURM_LOCALID", "0"))))'"'"',
)
s = s.replace(
    '"'"'return int(os.getenv("SLURM_PROCID", 0))'"'"',
    '"'"'return int(os.getenv("RANK", os.getenv("SLURM_PROCID", 0)))'"'"',
)

p.write_text(s)
print("[CONTAINER] patched train.py for Docker-only torchrun")
PY

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export TOKENIZERS_PARALLELISM=false
export HYDRA_FULL_ERROR=1

export MASTER_ADDR="${MASTER_ADDR:-127.0.0.1}"
export MASTER_PORT="${MASTER_PORT:-29500}"
export CUDA_DEVICE_MAX_CONNECTIONS="${CUDA_DEVICE_MAX_CONNECTIONS:-1}"
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"

# The HPC-X plugin that this image injects into NCCL
# (/opt/hpcx/nccl_rdma_sharp_plugin/lib/libnccl-net.so, logged as "NCCL RDMA
# Plugin v10") segfaults inside ncclCommInitRankConfig on B300 with the
# NCCL 2.28.3 shipped here. It reproduces with a single rank, before any
# collective runs, so it is not a topology, NVLink or multi-GPU problem --
# scripts/nccl_probe.sh reproduces and clears it in about thirty seconds.
#
# Disabling the external plugin makes NCCL fall back to its own IB/RDMA
# transport, which is correct on one node and across nodes alike. What is
# given up is SHARP in-network reduction, so multi-node allreduce is slower
# than it could be -- but it runs, which the plugin does not.
#
# Scoped to B300 because that is where the crash is demonstrated; other GPU
# types keep the plugin. Set NCCL_NET_PLUGIN yourself to override either way.
if [[ "${MLPERF_GPU_TYPE:-}" == "B300" && -z "${NCCL_NET_PLUGIN:-}" ]]; then
  export NCCL_NET_PLUGIN="none"
  echo "[CONTAINER] B300: NCCL_NET_PLUGIN=none (HPC-X plugin crashes ncclCommInitRankConfig; using NCCL built-in IB, no SHARP)"
fi

case "$MLPERF_GPU_TYPE" in
  V100|A100|H100|GH200)
    export GPU_ARCH="${GPU_ARCH:-h}"
    ;;
  B300|RTX6000|RTX_PRO_6000)
    export GPU_ARCH="${GPU_ARCH:-b}"
    ;;
  *)
    echo "[CONTAINER][ERROR] Unsupported GPU for training v5.1: $MLPERF_GPU_TYPE" >&2
    exit 69
    ;;
esac

export TP="${TP:-$MLPERF_NUM_GPUS}"
export PP="${PP:-1}"
export CP="${CP:-1}"
export MBS="${MBS:-1}"
export GBS="${GBS:-${GLOBAL_BATCH_SIZE:-128}}"
export SEQ_LENGTH="${SEQ_LENGTH:-${MAX_SEQLEN:-8192}}"

export MLPERF_MAX_STEPS="${MLPERF_MAX_STEPS:-10}"
export MLPERF_LIMIT_VAL_BATCHES="${MLPERF_LIMIT_VAL_BATCHES:-1}"
export MLPERF_VAL_CHECK_INTERVAL="${MLPERF_VAL_CHECK_INTERVAL:-10}"
export MLPERF_LOG_EVERY_N_STEPS="${MLPERF_LOG_EVERY_N_STEPS:-1}"
export MLPERF_ENABLE_PROGRESS_BAR="${MLPERF_ENABLE_PROGRESS_BAR:-true}"
export TRAINER_PRECISION="${TRAINER_PRECISION:-${MLPERF_TRAINER_PRECISION:-bf16-mixed}}"
case "${TRAINER_PRECISION}" in
  FP32|32|32-true|FP64|64|64-true)
    echo "[CONTAINER][WARN] TRAINER_PRECISION=${TRAINER_PRECISION} is not supported by this NeMo/Megatron MLPerf training path; using bf16-mixed" >&2
    TRAINER_PRECISION="bf16-mixed"
    ;;
  FP16|16|16-true|fp16-mixed)
    TRAINER_PRECISION="16-mixed"
    ;;
  BF16|bf16-true)
    TRAINER_PRECISION="bf16"
    ;;
  BF16-mixed)
    TRAINER_PRECISION="bf16-mixed"
    ;;
  FP8)
    TRAINER_PRECISION="transformer-engine"
    FP8="True"
    FP8_HYBRID="False"
    ;;
  FP8_HYBRID)
    TRAINER_PRECISION="transformer-engine"
    FP8="True"
    FP8_HYBRID="True"
    ;;
esac
export TRAINER_PRECISION MLPERF_TRAINER_PRECISION="${TRAINER_PRECISION}" FP8 FP8_HYBRID
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export TQDM_MININTERVAL="${TQDM_MININTERVAL:-0}"
export DGXNNODES="${MLPERF_TRAIN_NNODES:-${DGXNNODES:-1}}"
export MLPERF_NODE_RANK="${MLPERF_NODE_RANK:-0}"
export MLPERF_WORLD_SIZE="${MLPERF_WORLD_SIZE:-${WORLD_SIZE_GPUS:-$(( DGXNNODES * MLPERF_NUM_GPUS ))}}"

validate_training_parallel_config() {
  for v in MLPERF_NUM_GPUS MLPERF_WORLD_SIZE DGXNNODES TP PP CP MBS GBS; do
    [[ "${!v:-}" =~ ^[0-9]+$ ]] || { echo "[CONTAINER][ERROR] $v must be a positive integer: ${!v:-}" >&2; exit 70; }
    (( ${!v} >= 1 )) || { echo "[CONTAINER][ERROR] $v must be >= 1" >&2; exit 70; }
  done
  local mp=$(( TP * PP * CP ))
  if (( mp > MLPERF_WORLD_SIZE )); then
    echo "[CONTAINER][ERROR] TP*PP*CP=${mp} exceeds WORLD_SIZE_GPUS=${MLPERF_WORLD_SIZE}" >&2
    exit 70
  fi
  if (( MLPERF_WORLD_SIZE % mp != 0 )); then
    echo "[CONTAINER][ERROR] WORLD_SIZE_GPUS=${MLPERF_WORLD_SIZE} must be divisible by TP*PP*CP=${mp}" >&2
    exit 70
  fi
  local dp=$(( MLPERF_WORLD_SIZE / mp ))
  local min_gbs=$(( MBS * dp ))
  if (( GBS < min_gbs )); then
    echo "[CONTAINER][ERROR] GLOBAL_BATCH_SIZE/GBS=${GBS} must be >= MBS(${MBS})*DP(${dp})=${min_gbs}" >&2
    exit 70
  fi
  if (( GBS % min_gbs != 0 )); then
    echo "[CONTAINER][ERROR] GLOBAL_BATCH_SIZE/GBS=${GBS} must be divisible by MBS(${MBS})*DP(${dp})=${min_gbs}" >&2
    exit 70
  fi
  local grad_accum=$(( GBS / min_gbs ))
  echo "[CONTAINER] parallel config: NNODES=${DGXNNODES} NODE_RANK=${MLPERF_NODE_RANK} NUM_GPUS_PER_NODE=${MLPERF_NUM_GPUS} WORLD_SIZE_GPUS=${MLPERF_WORLD_SIZE} TP=${TP} PP=${PP} CP=${CP} DP=${dp} MBS=${MBS} GBS=${GBS}"
  echo "[CONTAINER] effective GBS = MBS(${MBS}) * DP(${dp}) * grad_accum(${grad_accum}) = ${GBS}"
}

validate_training_parallel_config

if [[ -n "${MLPERF_RUN_CMD:-}" ]]; then
  echo "[CONTAINER] running custom command from MLPERF_RUN_CMD"
  exec bash -lc "$MLPERF_RUN_CMD"
fi

# v5.1 Hydra configs differ by benchmark/image. Use ++ for trainer/model keys so
# platform-provided overrides work whether the key already exists or must be appended.
OVERRIDES=(
  "++ckpt_root=${MODEL_DIR}"
  "++data_root=${DATA_DIR}"
  "++trainer.devices=${MLPERF_NUM_GPUS}"
  "++trainer.num_nodes=${DGXNNODES}"
  "++trainer.max_steps=${MLPERF_MAX_STEPS}"
  "++trainer.limit_val_batches=${MLPERF_LIMIT_VAL_BATCHES}"
  "++trainer.val_check_interval=${MLPERF_VAL_CHECK_INTERVAL}"
  "++trainer.log_every_n_steps=${MLPERF_LOG_EVERY_N_STEPS}"
  "++trainer.enable_progress_bar=${MLPERF_ENABLE_PROGRESS_BAR}"
  "++trainer.precision=${TRAINER_PRECISION}"
)

append_hydra_if_set() {
  local env_name="$1"
  local hydra_key="$2"
  local val
  val="${!env_name:-}"
  if [[ -n "$val" ]]; then
    OVERRIDES+=("++${hydra_key}=${val}")
  fi
}

append_hydra_if_set TP model.tensor_model_parallel_size
append_hydra_if_set PP model.pipeline_model_parallel_size
append_hydra_if_set CP model.context_parallel_size
append_hydra_if_set MBS model.micro_batch_size
append_hydra_if_set GBS model.global_batch_size
append_hydra_if_set MAX_SEQLEN model.encoder_seq_length
append_hydra_if_set SEQ_LENGTH model.encoder_seq_length
append_hydra_if_set FP8 model.fp8
append_hydra_if_set FP8_HYBRID model.fp8_hybrid

append_extra_hydra_overrides_safe() {
  local ov
  if [[ -n "${MLPERF_EXTRA_OVERRIDES:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_OVERRIDES=( ${MLPERF_EXTRA_OVERRIDES} )
    for ov in "${EXTRA_OVERRIDES[@]}"; do
      case "$ov" in
        ++*|+*|~*)
          OVERRIDES+=("$ov")
          ;;
        trainer.*=*|model.*=*|exp_manager.*=*|ckpt_root=*|data_root=*)
          OVERRIDES+=("++${ov}")
          ;;
        *)
          OVERRIDES+=("$ov")
          ;;
      esac
    done
  fi
}
append_extra_hydra_overrides_safe

echo "[CONTAINER] GPU_ARCH=$GPU_ARCH"
echo "[CONTAINER] TP=$TP PP=$PP CP=$CP MBS=$MBS GBS=$GBS SEQ_LENGTH=$SEQ_LENGTH"
echo "[CONTAINER] LOG_EVERY_N_STEPS=$MLPERF_LOG_EVERY_N_STEPS ENABLE_PROGRESS_BAR=$MLPERF_ENABLE_PROGRESS_BAR"
printf "[CONTAINER] override %q\n" "${OVERRIDES[@]}"

if [[ "${DGXNNODES}" -gt 1 ]]; then
  TORCHRUN_ARGS=(--nnodes="$DGXNNODES" --node_rank="$MLPERF_NODE_RANK" --nproc_per_node="$MLPERF_NUM_GPUS" --rdzv_backend=c10d --rdzv_endpoint="${MASTER_ADDR}:${MASTER_PORT}")
else
  TORCHRUN_ARGS=(--standalone --nnodes=1 --nproc_per_node="$MLPERF_NUM_GPUS" --rdzv_backend=c10d --rdzv_endpoint="${MASTER_ADDR}:${MASTER_PORT}")
fi
exec torchrun "${TORCHRUN_ARGS[@]}" train.py "${OVERRIDES[@]}"
'
else
  CONTAINER_CMD='
set -Eeuo pipefail
trap '"'"'echo "[CONTAINER][FATAL] command failed at line ${LINENO}: ${BASH_COMMAND}" >&2'"'"' ERR

cd "$BENCH_DIR"
mkdir -p "$RESULT_DIR" "$MLPERF_LOG_DIR/npy_index"

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export TOKENIZERS_PARALLELISM=false
export HYDRA_FULL_ERROR=1

export MASTER_ADDR="${MASTER_ADDR:-127.0.0.1}"
export MASTER_PORT="${MASTER_PORT:-29500}"
export CUDA_DEVICE_MAX_CONNECTIONS="${CUDA_DEVICE_MAX_CONNECTIONS:-1}"
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"

# The HPC-X plugin that this image injects into NCCL
# (/opt/hpcx/nccl_rdma_sharp_plugin/lib/libnccl-net.so, logged as "NCCL RDMA
# Plugin v10") segfaults inside ncclCommInitRankConfig on B300 with the
# NCCL 2.28.3 shipped here. It reproduces with a single rank, before any
# collective runs, so it is not a topology, NVLink or multi-GPU problem --
# scripts/nccl_probe.sh reproduces and clears it in about thirty seconds.
#
# Disabling the external plugin makes NCCL fall back to its own IB/RDMA
# transport, which is correct on one node and across nodes alike. What is
# given up is SHARP in-network reduction, so multi-node allreduce is slower
# than it could be -- but it runs, which the plugin does not.
#
# Scoped to B300 because that is where the crash is demonstrated; other GPU
# types keep the plugin. Set NCCL_NET_PLUGIN yourself to override either way.
if [[ "${MLPERF_GPU_TYPE:-}" == "B300" && -z "${NCCL_NET_PLUGIN:-}" ]]; then
  export NCCL_NET_PLUGIN="none"
  echo "[CONTAINER] B300: NCCL_NET_PLUGIN=none (HPC-X plugin crashes ncclCommInitRankConfig; using NCCL built-in IB, no SHARP)"
fi

case "$MLPERF_GPU_TYPE" in
  V100|A100|H100|GH200)
    export GPU_ARCH="${GPU_ARCH:-h}"
    ;;
  B300|RTX6000|RTX_PRO_6000)
    export GPU_ARCH="${GPU_ARCH:-b}"
    ;;
  *)
    echo "[CONTAINER][ERROR] Unsupported GPU for training v5.1: $MLPERF_GPU_TYPE" >&2
    exit 69
    ;;
esac

export TP="${TP:-${TENSOR_MODEL_PARALLEL:-$MLPERF_NUM_GPUS}}"
export PP="${PP:-${PIPELINE_MODEL_PARALLEL:-1}}"
export CP="${CP:-${CONTEXT_PARALLEL:-1}}"
export MBS="${MBS:-${MICRO_BATCH_SIZE:-1}}"
export GBS="${GBS:-${GLOBAL_BATCH_SIZE:-128}}"
export SEQ_LENGTH="${SEQ_LENGTH:-${MAX_SEQLEN:-8192}}"
export LR="${LR:-0.0008}"
export WARMUP_STEPS="${WARMUP_STEPS:-2}"
export TARGET_LOG_PPL="${TARGET_LOG_PPL:-3.3}"
export FP8="${FP8:-${FP8_HYBRID:-False}}"
export FP8_HYBRID="${FP8_HYBRID:-$FP8}"
# llama31_8b is stricter than llama2_70b_lora here. Its pretrain.py
# (get_model_with_precision) accepts exactly one value:
#
#   elif config.trainer.precision == "bf16": ...
#   else: assert False, f"Unsupported precision {config.trainer.precision}"
#
# so "bf16-mixed" -- fine for llama2_70b_lora, which hardcodes its own
# MegatronMixedPrecision(precision="bf16-mixed") and never reads this key --
# aborts the 8b run before the first step. get_optimizer tests
# `config.trainer.precision == "bf16"` too, so the plain value is also what
# selects the bf16 optimizer path.
#
# FP8/FP4 do not go through this key: pretrain.py branches on config.model.fp8
# (passed below as ++model.fp8) and keeps trainer.precision at bf16.
export TRAINER_PRECISION="${TRAINER_PRECISION:-${MLPERF_TRAINER_PRECISION:-bf16}}"
case "${TRAINER_PRECISION}" in
  bf16)
    ;;
  BF16|bf16-true|BF16-true|bf16-mixed|BF16-mixed|bf16_mixed)
    TRAINER_PRECISION="bf16"
    ;;
  FP8)
    TRAINER_PRECISION="bf16"
    FP8="True"
    FP8_HYBRID="False"
    ;;
  FP8_HYBRID)
    TRAINER_PRECISION="bf16"
    FP8="True"
    FP8_HYBRID="True"
    ;;
  *)
    echo "[CONTAINER][WARN] TRAINER_PRECISION=${TRAINER_PRECISION} is not accepted by llama31_8b pretrain.py (bf16 only); using bf16" >&2
    TRAINER_PRECISION="bf16"
    ;;
esac
export TRAINER_PRECISION MLPERF_TRAINER_PRECISION="${TRAINER_PRECISION}" FP8 FP8_HYBRID
export MINIBS="${MINIBS:-$GBS}"

# The llama31_8b Hydra configs and pretrain.py resolve/read these names directly.
# Keep short UI/env names and official MLPerf config env names in sync.
export TENSOR_MODEL_PARALLEL="${TENSOR_MODEL_PARALLEL:-$TP}"
export PIPELINE_MODEL_PARALLEL="${PIPELINE_MODEL_PARALLEL:-$PP}"
export CONTEXT_PARALLEL="${CONTEXT_PARALLEL:-$CP}"
export MICRO_BATCH_SIZE="${MICRO_BATCH_SIZE:-$MBS}"
export GLOBAL_BATCH_SIZE="${GLOBAL_BATCH_SIZE:-$GBS}"
export MAX_SEQLEN="${MAX_SEQLEN:-$SEQ_LENGTH}"

export MLPERF_MAX_STEPS="${MLPERF_MAX_STEPS:-10}"
export MLPERF_LIMIT_VAL_BATCHES="${MLPERF_LIMIT_VAL_BATCHES:-1}"
export MLPERF_VAL_CHECK_INTERVAL="${MLPERF_VAL_CHECK_INTERVAL:-10}"
export MLPERF_LOG_EVERY_N_STEPS="${MLPERF_LOG_EVERY_N_STEPS:-1}"
export MLPERF_ENABLE_PROGRESS_BAR="${MLPERF_ENABLE_PROGRESS_BAR:-true}"
# llama31_8b is stricter than llama2_70b_lora here. Its pretrain.py
# (get_model_with_precision) accepts exactly one value:
#
#   elif config.trainer.precision == "bf16": ...
#   else: assert False, f"Unsupported precision {config.trainer.precision}"
#
# so "bf16-mixed" -- fine for llama2_70b_lora, which hardcodes its own
# MegatronMixedPrecision(precision="bf16-mixed") and never reads this key --
# aborts the 8b run before the first step. get_optimizer tests
# `config.trainer.precision == "bf16"` too, so the plain value is also what
# selects the bf16 optimizer path.
#
# FP8/FP4 do not go through this key: pretrain.py branches on config.model.fp8
# (passed below as ++model.fp8) and keeps trainer.precision at bf16.
export TRAINER_PRECISION="${TRAINER_PRECISION:-${MLPERF_TRAINER_PRECISION:-bf16}}"
case "${TRAINER_PRECISION}" in
  bf16)
    ;;
  BF16|bf16-true|BF16-true|bf16-mixed|BF16-mixed|bf16_mixed)
    TRAINER_PRECISION="bf16"
    ;;
  FP8)
    TRAINER_PRECISION="bf16"
    FP8="True"
    FP8_HYBRID="False"
    ;;
  FP8_HYBRID)
    TRAINER_PRECISION="bf16"
    FP8="True"
    FP8_HYBRID="True"
    ;;
  *)
    echo "[CONTAINER][WARN] TRAINER_PRECISION=${TRAINER_PRECISION} is not accepted by llama31_8b pretrain.py (bf16 only); using bf16" >&2
    TRAINER_PRECISION="bf16"
    ;;
esac
export TRAINER_PRECISION MLPERF_TRAINER_PRECISION="${TRAINER_PRECISION}" FP8 FP8_HYBRID
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
export TQDM_MININTERVAL="${TQDM_MININTERVAL:-0}"
export DGXNNODES="${MLPERF_TRAIN_NNODES:-${DGXNNODES:-1}}"
export MLPERF_NODE_RANK="${MLPERF_NODE_RANK:-0}"
export MLPERF_WORLD_SIZE="${MLPERF_WORLD_SIZE:-${WORLD_SIZE_GPUS:-$(( DGXNNODES * MLPERF_NUM_GPUS ))}}"

validate_training_parallel_config() {
  for v in MLPERF_NUM_GPUS MLPERF_WORLD_SIZE DGXNNODES TP PP CP MBS GBS; do
    [[ "${!v:-}" =~ ^[0-9]+$ ]] || { echo "[CONTAINER][ERROR] $v must be a positive integer: ${!v:-}" >&2; exit 70; }
    (( ${!v} >= 1 )) || { echo "[CONTAINER][ERROR] $v must be >= 1" >&2; exit 70; }
  done
  local mp=$(( TP * PP * CP ))
  if (( mp > MLPERF_WORLD_SIZE )); then
    echo "[CONTAINER][ERROR] TP*PP*CP=${mp} exceeds WORLD_SIZE_GPUS=${MLPERF_WORLD_SIZE}" >&2
    exit 70
  fi
  if (( MLPERF_WORLD_SIZE % mp != 0 )); then
    echo "[CONTAINER][ERROR] WORLD_SIZE_GPUS=${MLPERF_WORLD_SIZE} must be divisible by TP*PP*CP=${mp}" >&2
    exit 70
  fi
  local dp=$(( MLPERF_WORLD_SIZE / mp ))
  local min_gbs=$(( MBS * dp ))
  if (( GBS < min_gbs )); then
    echo "[CONTAINER][ERROR] GLOBAL_BATCH_SIZE/GBS=${GBS} must be >= MBS(${MBS})*DP(${dp})=${min_gbs}" >&2
    exit 70
  fi
  if (( GBS % min_gbs != 0 )); then
    echo "[CONTAINER][ERROR] GLOBAL_BATCH_SIZE/GBS=${GBS} must be divisible by MBS(${MBS})*DP(${dp})=${min_gbs}" >&2
    exit 70
  fi
  local grad_accum=$(( GBS / min_gbs ))
  echo "[CONTAINER] parallel config: NNODES=${DGXNNODES} NODE_RANK=${MLPERF_NODE_RANK} NUM_GPUS_PER_NODE=${MLPERF_NUM_GPUS} WORLD_SIZE_GPUS=${MLPERF_WORLD_SIZE} TP=${TP} PP=${PP} CP=${CP} DP=${dp} MBS=${MBS} GBS=${GBS}"
  echo "[CONTAINER] effective GBS = MBS(${MBS}) * DP(${dp}) * grad_accum(${grad_accum}) = ${GBS}"
}

validate_training_parallel_config

if [[ -n "${MLPERF_RUN_CMD:-}" ]]; then
  echo "[CONTAINER] running custom command from MLPERF_RUN_CMD"
  exec bash -lc "$MLPERF_RUN_CMD"
fi

# v5.1 Hydra configs differ by benchmark/image. Use ++ for trainer/model keys so
# platform-provided overrides work whether the key already exists or must be appended.
OVERRIDES=(
  "++trainer.devices=${MLPERF_NUM_GPUS}"
  "++trainer.num_nodes=${DGXNNODES}"
  "++trainer.max_steps=${MLPERF_MAX_STEPS}"
  "++trainer.limit_val_batches=${MLPERF_LIMIT_VAL_BATCHES}"
  "++trainer.val_check_interval=${MLPERF_VAL_CHECK_INTERVAL}"
  "++trainer.log_every_n_steps=${MLPERF_LOG_EVERY_N_STEPS}"
  "++trainer.enable_progress_bar=${MLPERF_ENABLE_PROGRESS_BAR}"
  "++trainer.precision=${TRAINER_PRECISION}"
  "++model.base_config=8b"
  "++model.tokenizer.model=/preproc_data/tokenizer"
  "++model.data.mock_dataset=false"
  "++model.tensor_model_parallel_size=${TP}"
  "++model.pipeline_model_parallel_size=${PP}"
  "++model.context_parallel_size=${CP}"
  "++model.micro_batch_size=${MBS}"
  "++model.global_batch_size=${GBS}"
  "++model.encoder_seq_length=${SEQ_LENGTH}"
  "++model.optim.lr=${LR}"
  "++model.optim.sched.warmup_steps=${WARMUP_STEPS}"
  "++model.custom.target_log_ppl=${TARGET_LOG_PPL}"
  "++model.fp8=${FP8}"
  "++model.fp8_hybrid=${FP8_HYBRID}"
  "++exp_manager.explicit_log_dir=${RESULT_DIR}"
)

# PP=1 cannot use interleaved pipeline schedule.
# Disable virtual pipeline automatically so TP-only runs such as TP=8, PP=1 work without user-specified overrides.
if [[ "${PP}" == "1" ]]; then
  echo "[CONTAINER] PP=1 detected; disabling interleaved pipeline schedule"
  OVERRIDES+=(
    "++model.virtual_pipeline_model_parallel_size=null"
  )
fi

# Sequence parallelism splits the sequence dimension across the tensor-parallel
# group, so it is meaningless -- and rejected -- when that group has one rank:
#   model_parallel_config.py: raise ValueError(
#       "Can not use sequence paralllelism without tensor parallelism")
# The shipped 8b config leaves model.sequence_parallel on, which makes any TP=1
# run (a single-GPU smoke test, for instance) die in config validation before
# the model is built. Same treatment as PP=1 above.
if [[ "${TP}" == "1" ]]; then
  echo "[CONTAINER] TP=1 detected; disabling sequence parallelism"
  OVERRIDES+=(
    "++model.sequence_parallel=False"
  )
fi

append_extra_hydra_overrides_safe() {
  local ov
  if [[ -n "${MLPERF_EXTRA_OVERRIDES:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_OVERRIDES=( ${MLPERF_EXTRA_OVERRIDES} )
    for ov in "${EXTRA_OVERRIDES[@]}"; do
      case "$ov" in
        ++*|+*|~*)
          OVERRIDES+=("$ov")
          ;;
        trainer.*=*|model.*=*|exp_manager.*=*|ckpt_root=*|data_root=*)
          OVERRIDES+=("++${ov}")
          ;;
        *)
          OVERRIDES+=("$ov")
          ;;
      esac
    done
  fi
}
append_extra_hydra_overrides_safe

echo "[CONTAINER] GPU_ARCH=$GPU_ARCH"
echo "[CONTAINER] FP8=$FP8 FP8_HYBRID=$FP8_HYBRID TRAINER_PRECISION=$TRAINER_PRECISION"
echo "[CONTAINER] LOG_EVERY_N_STEPS=$MLPERF_LOG_EVERY_N_STEPS ENABLE_PROGRESS_BAR=$MLPERF_ENABLE_PROGRESS_BAR"
echo "[CONTAINER] TP=$TP PP=$PP CP=$CP MBS=$MBS GBS=$GBS MINIBS=$MINIBS SEQ_LENGTH=$SEQ_LENGTH"
echo "[CONTAINER] TENSOR_MODEL_PARALLEL=$TENSOR_MODEL_PARALLEL PIPELINE_MODEL_PARALLEL=$PIPELINE_MODEL_PARALLEL CONTEXT_PARALLEL=$CONTEXT_PARALLEL MICRO_BATCH_SIZE=$MICRO_BATCH_SIZE GLOBAL_BATCH_SIZE=$GLOBAL_BATCH_SIZE MAX_SEQLEN=$MAX_SEQLEN"
printf "[CONTAINER] override %q\n" "${OVERRIDES[@]}"

if [[ "${DGXNNODES}" -gt 1 ]]; then
  TORCHRUN_ARGS=(--nnodes="$DGXNNODES" --node_rank="$MLPERF_NODE_RANK" --nproc_per_node="$MLPERF_NUM_GPUS" --rdzv_backend=c10d --rdzv_endpoint="${MASTER_ADDR}:${MASTER_PORT}")
else
  TORCHRUN_ARGS=(--standalone --nnodes=1 --nproc_per_node="$MLPERF_NUM_GPUS" --rdzv_backend=c10d --rdzv_endpoint="${MASTER_ADDR}:${MASTER_PORT}")
fi
exec torchrun "${TORCHRUN_ARGS[@]}" pretrain.py "${OVERRIDES[@]}"
'
fi

printf '%s\n' "$CONTAINER_CMD" > "${LOG_DIR}/container_entrypoint_inline.sh"

DOCKER_CMD=(
  docker run --rm
  --name "$CONTAINER_NAME"
  --network=host
  --ipc=host
  --gpus all
  --ulimit memlock=-1
  --ulimit stack=67108864
  -v "${MLPERF_ROOT}:${MLPERF_ROOT}"
  -v "${LOG_DIR}:${LOG_DIR}"
)

# Expose host RDMA character devices to the container when present.  This is
# required for NCCL verbs/IB transport; --network=host alone only shares the
# network namespace and does not grant /dev/infiniband device access.
if [[ -d /dev/infiniband ]]; then
  for rdma_dev in /dev/infiniband/*; do
    [[ -e "$rdma_dev" ]] || continue
    DOCKER_CMD+=(--device "${rdma_dev}:${rdma_dev}")
  done
fi


if [[ "$BENCHMARK" == "llama31_8b" ]]; then
  DOCKER_CMD+=(
    -v "${DATA_DIR}:/preproc_data:ro"
    -v "${LOG_DIR}/npy_index:/npy_index"
  )
fi

if [[ -f "$CERT_FILE" ]]; then
  DOCKER_CMD+=(-v "${CERT_FILE}:/etc/ssl/certs/ca-certificates.crt:ro")
fi

DOCKER_CMD+=(
  -w "$BENCH_DIR"
  -e "BENCH_DIR=${BENCH_DIR}"
  -e "MLPERF_LOG_DIR=${LOG_DIR}"
  -e "MLPERF_RUN_ID=${RUN_ID}"
  -e "MLPERF_NUM_GPUS=${GPU_COUNT}"
  -e "MLPERF_GPU_TYPE=${GPU_TYPE}"
  -e "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES_VALUE}"
  -e "NVIDIA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES_VALUE}"
  -e "RESULT_DIR=${RESULT_DIR}"
  -e "DATA_DIR=${DATA_DIR}"
  -e "MODEL_DIR=${MODEL_DIR}"
)

for env_name in \
  MLPERF_RUN_CMD \
  MLPERF_MAX_STEPS \
  MLPERF_LIMIT_VAL_BATCHES \
  MLPERF_VAL_CHECK_INTERVAL \
  MLPERF_LOG_EVERY_N_STEPS \
  MLPERF_ENABLE_PROGRESS_BAR \
  MLPERF_EXTRA_OVERRIDES \
  TRAINER_PRECISION \
  MLPERF_TRAINER_PRECISION \
  GPU_ARCH \
  NUM_GPUS \
  MLPERF_NUM_GPUS \
  TP \
  PP \
  CP \
  MBS \
  GBS \
  MINIBS \
  MAX_SEQLEN \
  SEQ_LENGTH \
  TENSOR_MODEL_PARALLEL \
  PIPELINE_MODEL_PARALLEL \
  CONTEXT_PARALLEL \
  MICRO_BATCH_SIZE \
  GLOBAL_BATCH_SIZE \
  LR \
  WARMUP_STEPS \
  TARGET_LOG_PPL \
  FP8 \
  FP8_HYBRID \
  MASTER_ADDR \
  MASTER_PORT \
  NCCL_DEBUG \
  NCCL_IB_HCA \
  NCCL_SOCKET_IFNAME \
  NCCL_IB_DISABLE \
  NCCL_P2P_DISABLE \
  NCCL_SHM_DISABLE \
  NCCL_NVLS_ENABLE \
  NCCL_CUMEM_ENABLE \
  NCCL_MNNVL_ENABLE \
  NCCL_NET_PLUGIN \
  NCCL_TUNER_PLUGIN \
  NCCL_NET \
  NCCL_COLLNET_ENABLE \
  UCX_TLS \
  UCX_NET_DEVICES \
  UCX_IB_GPU_DIRECT_RDMA \
  UCX_LOG_LEVEL \
  UCC_TLS \
  UCC_LOG_LEVEL \
  UCX_HANDLE_ERRORS \
  UCX_ERROR_SIGNALS \
  CUDA_LAUNCH_BLOCKING \
  TORCH_SHOW_CPP_STACKTRACES \
  TORCH_CPP_LOG_LEVEL \
  PYTHONFAULTHANDLER \
  NVTE_DEBUG \
  NVTE_DEBUG_LEVEL \
  MLPERF_NODE_MODE \
  MLPERF_TRAIN_NNODES \
  MLPERF_NODE_RANK \
  MLPERF_WORLD_SIZE \
  WORLD_SIZE_GPUS \
  PYTHONUNBUFFERED \
  TQDM_MININTERVAL
do
  if [[ -n "${!env_name:-}" ]]; then
    DOCKER_CMD+=(-e "${env_name}=${!env_name}")
  fi
done

DOCKER_CMD+=("$DOCKER_IMAGE" bash -lc "$CONTAINER_CMD")

{
  printf '%q ' "${DOCKER_CMD[@]}"
  printf '\n'
} > "${LOG_DIR}/command.txt"

echo "[INFO] exact Docker command:"
cat "${LOG_DIR}/command.txt"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[PHASE] dry-run"
  emit_summary "success" 0 "dry-run completed"
  exit 0
fi

echo "[PHASE] run"

set +e
"${DOCKER_CMD[@]}"
EXIT_CODE="$?"
set -e

echo "[PHASE] collect"
echo "[INFO] docker_exit_code=${EXIT_CODE}"

if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "[PHASE] done"
  emit_summary "success" "$EXIT_CODE" "training v5.1 completed successfully"
  exit 0
else
  echo "[PHASE] done"
  emit_summary "failed" "$EXIT_CODE" "training v5.1 failed; inspect run.log and command.txt"
  exit "$EXIT_CODE"
fi
REMOTE_RUN
