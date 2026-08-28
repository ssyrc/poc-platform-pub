#!/usr/bin/env bash
set -Eeuo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_LIB_DIR}/lib_ssh.sh"

usage() {
  cat <<'EOU'
Usage:
  ./mlperf_infer_v60.sh \
    --run-id infer_v60_001 \
    --gpu-type H100 \
    --host gpu-node03

Usually called by:
  ./mlperf_run.sh --suite inference --version v6.0 ...

Supported:
  MLPerf Inference v6.0
  Benchmark: llama2_70b

Purpose:
  Local bring-up script for air-gapped/internal GPU servers.
  This is not an official MLPerf submission script.

Expected source tree:
  <mlperf-root>/inference_results_v6.0-main/closed/NVIDIA

Expected 3rdparty:
  <mlperf-root>/inference_results_v6.0-main/closed/NVIDIA/3rdparty/trtllm
  <mlperf-root>/inference_results_v6.0-main/closed/NVIDIA/3rdparty/mlc-inference

Expected model source:
  <mlperf-root>/inference_results_v6.0-main/closed/NVIDIA/build/models/Llama2/Llama-2-70b-chat-hf
  Optional/prebuilt quantized checkpoint/output:
    <mlperf-root>/inference_results_v6.0-main/closed/NVIDIA/build/models/Llama2/llama2-70b-chat-hf-torch-fp4_mlperf-inf-v6.0
    or set MLPERF_QUANT_MODEL_DIR to your local Hugging Face snapshot/output directory.

Expected OpenOrca data:
  <data-root>/inference_llama2_70b/open_orca/
    open_orca_gpt4_tokenized_llama.sampled_24576.pkl
    open_orca_gpt4_tokenized_llama.calibration_1000.pkl

Options:
  --stop
  --run-id <id>
  --gpu-type <gpu>
  --host <hostname>
  --benchmark llama2_70b
  --docker-image <image>
  --mlperf-root <path>
  --data-root <path>
  --log-root <path>
  --config <path>
  --dry-run
EOU
}

die(){ echo "[ERROR] $*" >&2; exit 1; }
MODE="run"; RUN_ID=""; GPU_TYPE=""; HOST=""; BENCHMARK="llama2_70b"; DOCKER_IMAGE=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}}"; DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"; LOG_ROOT="${MLPERF_LOG_ROOT:-${POC_PLATFORM_ROOT:-/opt/poc-platform}}/mlperf_logs_infer_v60"; CONFIG_PATH=""; DRY_RUN="false"
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
[[ -n "$RUN_ID" ]] || die "--run-id is required"; [[ -n "$HOST" ]] || die "--host is required"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid run-id: $RUN_ID"; [[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host: $HOST"
[[ "$MLPERF_ROOT" == /* ]] || die "--mlperf-root must be absolute"; [[ "$DATA_ROOT" == /* ]] || die "--data-root must be absolute"; [[ "$LOG_ROOT" == /* ]] || die "--log-root must be absolute"
case "$BENCHMARK" in llama2_70b) ;; *) die "Inference v6.0 supports only benchmark=llama2_70b" ;; esac
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"; CONTAINER_NAME="mlperf_infer_v60_${SAFE_RUN_ID}"
LOCAL_SHORT="$(hostname -s 2>/dev/null || hostname)"; LOCAL_FQDN="$(hostname -f 2>/dev/null || hostname)"
is_local_host(){ [[ "$1" == "localhost" || "$1" == "127.0.0.1" || "$1" == "$LOCAL_SHORT" || "$1" == "$LOCAL_FQDN" ]]; }
remote_bash(){ if is_local_host "$HOST"; then bash -s -- "$@"; else
  local -a _sopt; ssh_opts_for _sopt "$HOST"
  ssh ${_sopt[@]+"${_sopt[@]}"} -o BatchMode=yes -o ConnectTimeout=8 "$HOST" bash -s -- "$@"; fi; }
if [[ "$MODE" == "stop" ]]; then
  echo "[PHASE] stop"
  remote_bash "$CONTAINER_NAME" <<'REMOTE_STOP'
set -Eeuo pipefail
CONTAINER_NAME="$1"
if ! command -v docker >/dev/null 2>&1; then echo "[WARN] docker unavailable"; exit 0; fi
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then echo "[INFO] docker stop -t 30 ${CONTAINER_NAME}"; docker stop -t 30 "$CONTAINER_NAME" || docker rm -f "$CONTAINER_NAME" || true; else echo "[INFO] removing stopped container: ${CONTAINER_NAME}"; docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true; fi
else echo "[INFO] no container found: ${CONTAINER_NAME}"; fi
REMOTE_STOP
  echo "[PHASE] done"; exit 0
fi
[[ -n "$GPU_TYPE" ]] || die "--gpu-type is required"
if ! is_local_host "$HOST"; then echo "[INFO] checking SSH reachability: ${HOST}"; ssh_opts_for _sopt "$HOST"; ssh_describe_route "$HOST"; ssh ${_sopt[@]+"${_sopt[@]}"} -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "echo ok" >/dev/null 2>&1 || die "SSH unreachable: $HOST"; fi

# Advanced inference args arrive as env vars from backend/runner.py.
# SSH does not reliably preserve arbitrary env or multiline shell snippets, so
# serialize an allowlist as base64 and decode it inside the remote shell.
build_env_exports() {
  local env_name q out=""
  for env_name in \
    POC_PLATFORM_DOCKERIMG_DIRS \
    MLPERF_SOURCE_EXTERNAL_CONFIG \
    MLPERF_RUN_CMD \
    MLPERF_RUN_ARGS_EXTRA \
    MLPERF_INFER_SYSTEM_NAME \
    MLPERF_INFER_KNOWN_SYSTEM_CANDIDATES \
    MLPERF_INFER_TP_SIZE \
    MLPERF_INFER_GPU_BATCH_SIZE \
    MLPERF_INFER_OFFLINE_QPS \
    MLPERF_INFER_MIN_DURATION_MS \
    MLPERF_INFER_MIN_QUERY_COUNT \
    MLPERF_INFER_SCENARIO \
    MLPERF_INFER_ACCURACY_TARGET \
    MLPERF_INFER_TEST_MODE \
    MLPERF_INFER_CORE_TYPE \
    MLPERF_INFER_PREBUILD \
    MLPERF_INFER_PREPROCESS \
    MLPERF_INFER_RUN_SERVER \
    MLPERF_INFER_RUN_HARNESS \
    MLPERF_INFER_SERVER_WAIT_SEC \
    MLPERF_CUDA_VISIBLE_DEVICES \
    MLPERF_BASE_MODEL_DIR \
    MLPERF_PREPROCESSED_DIR \
    MLPERF_ENGINE_DIR \
    MLPERF_QUANT_MODEL_DIR \
    NVCR_PULL_PREFIX \
    DOCKER_REGISTRY \
    DOCKER_HTTP_PROXY \
    DOCKER_HTTPS_PROXY \
    DOCKER_INSECURE_REGISTRIES; do
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
remote_bash "$RUN_ID" "$CONTAINER_NAME" "$GPU_TYPE" "$HOST" "${DOCKER_IMAGE:-__EMPTY__}" "$MLPERF_ROOT" "$DATA_ROOT" "$LOG_ROOT" "${CONFIG_PATH:-__EMPTY__}" "$DRY_RUN" "$ADV_ENV_B64" <<'REMOTE_RUN'
set -Eeuo pipefail
trap 'echo "[FATAL] command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
RUN_ID="$1"; CONTAINER_NAME="$2"; GPU_TYPE="$3"; HOST="$4"; USER_DOCKER_IMAGE="$5"; MLPERF_ROOT="$6"; DATA_ROOT="$7"; LOG_ROOT="$8"; CONFIG_PATH="$9"; DRY_RUN="${10}"; ADV_ENV_B64="${11:-}"
[[ "$USER_DOCKER_IMAGE" == "__EMPTY__" ]] && USER_DOCKER_IMAGE=""; [[ "$CONFIG_PATH" == "__EMPTY__" ]] && CONFIG_PATH=""
if [[ -n "$ADV_ENV_B64" ]]; then ADV_ENV_EXPORTS="$(printf '%s' "$ADV_ENV_B64" | base64 -d)"; eval "$ADV_ENV_EXPORTS"; fi
START_TIME="$(date --iso-8601=seconds)"; START_EPOCH="$(date +%s)"; STAMP="$(date +%Y%m%d_%H%M%S)"; LOG_DIR="${LOG_ROOT}/${STAMP}_${HOST}_inference_v6.0_llama2_70b_${RUN_ID}"; RESULT_DIR="${LOG_DIR}/results"
NVIDIA_ROOT="${MLPERF_ROOT}/inference_results_v6.0-main/closed/NVIDIA"; BENCH_CODE_DIR="${NVIDIA_ROOT}/code/llama2-70b/tensorrt"; LLMLIB_DIR="${NVIDIA_ROOT}/code/llmlib"
DOCKERIMG_ROOT="${DATA_ROOT}/dockerimgs"
GPU_TYPE_IMAGE_KEY="$(printf '%s' "$GPU_TYPE" | tr '[:lower:]' '[:upper:]')"
case "$GPU_TYPE_IMAGE_KEY" in
  GH200)
    DEFAULT_IMAGE="${NVCR_PULL_PREFIX:-nvcr.io}/nvidia/mlperf/mlperf-inference:tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_aarch64"
    DEFAULT_IMAGE_TAR="${DOCKERIMG_ROOT}/mlperf-inference_tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_aarch64.tar"
    ;;
  *)
    DEFAULT_IMAGE="${NVCR_PULL_PREFIX:-nvcr.io}/nvidia/mlperf/mlperf-inference:tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_x86"
    DEFAULT_IMAGE_TAR="${DOCKERIMG_ROOT}/mlperf-inference_tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_x86.tar"
    ;;
esac
if [[ -z "$USER_DOCKER_IMAGE" && "$GPU_TYPE_IMAGE_KEY" != "GH200" ]]; then
  HOST_DRIVER_MAJOR="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | awk -F. '{print $1}' || true)"
  if [[ -n "$HOST_DRIVER_MAJOR" && "$HOST_DRIVER_MAJOR" =~ ^[0-9]+$ && "$HOST_DRIVER_MAJOR" -lt 590 ]]; then
    echo "[WARN] host NVIDIA driver major=${HOST_DRIVER_MAJOR}; default v6.0 TensorRT-LLM image requires driver 590.44+. Using driver-560 compatible MLPerf image fallback."
    DEFAULT_IMAGE="${NVCR_PULL_PREFIX:-nvcr.io}/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64"
    DEFAULT_IMAGE_TAR="${DOCKERIMG_ROOT}/mlperf-inference_mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64.tar"
  fi
fi
DOCKER_IMAGE="${USER_DOCKER_IMAGE:-$DEFAULT_IMAGE}"
DOCKER_IMAGE_TAR="${MLPERF_INFER_IMAGE_TAR:-$DEFAULT_IMAGE_TAR}"
echo "[INFO] selected MLPerf Inference v6.0 image for ${GPU_TYPE}: ${DOCKER_IMAGE}"
echo "[INFO] selected MLPerf Inference v6.0 tar fallback: ${DOCKER_IMAGE_TAR}"
OPEN_ORCA_DIR="${DATA_ROOT}/inference_llama2_70b/open_orca"; CERT_FILE="${DATA_ROOT}/certs/ca-certificates.crt"
# Default model/data locations follow the platform data layout.  They can still
# be overridden via advanced env when a host keeps MLPerf artifacts elsewhere.
BASE_MODEL_DIR="${MLPERF_BASE_MODEL_DIR:-${DATA_ROOT}/inference_llama2_70b/model}"
# The platform keeps all MLPerf Inference Llama2-70B data under DATA_ROOT.
# For v6.0, use the pre-downloaded FP4 Hugging Face snapshot directly;
# do not require users to type this path in the UI.
QUANT_MODEL_DIR="${MLPERF_QUANT_MODEL_DIR:-${DATA_ROOT}/inference_llama2_70b/model_fp4}"
PREPROCESSED_DIR="${MLPERF_PREPROCESSED_DIR:-${DATA_ROOT}/inference_llama2_70b/preprocessed_data}"
ENGINE_DIR="${MLPERF_ENGINE_DIR:-${NVIDIA_ROOT}/build/engines/${GPU_TYPE}/llama2-70b}"
REGISTRY_HOST="${DOCKER_REGISTRY:-}"; REGISTRY_USER="${DOCKER_USERNAME:-}"
json_escape(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; printf '%s' "$s"; }
emit_summary(){ local status="$1" code="$2" hint="$3" end_time end_epoch duration; end_time="$(date --iso-8601=seconds)"; end_epoch="$(date +%s)"; duration="$((end_epoch - START_EPOCH))"; printf 'MLPerf_RESULT_JSON={'; printf '"status":"%s",' "$(json_escape "$status")"; printf '"run_id":"%s",' "$(json_escape "$RUN_ID")"; printf '"host":"%s",' "$(json_escape "$HOST")"; printf '"gpu_type":"%s",' "$(json_escape "$GPU_TYPE")"; printf '"suite":"inference",'; printf '"mlperf_version":"v6.0",'; printf '"benchmark":"llama2_70b",'; printf '"docker_image":"%s",' "$(json_escape "$DOCKER_IMAGE")"; printf '"docker_container":"%s",' "$(json_escape "$CONTAINER_NAME")"; printf '"start_time":"%s",' "$(json_escape "$START_TIME")"; printf '"end_time":"%s",' "$(json_escape "$end_time")"; printf '"duration_sec":%s,' "$duration"; printf '"log_dir":"%s",' "$(json_escape "$LOG_DIR")"; printf '"exit_code":%s,' "$code"; printf '"result_hint":"%s"' "$(json_escape "$hint")"; printf '}\n'; }
fail_run(){ echo "[ERROR] $1"; emit_summary "failed" "${2:-1}" "$1"; exit "${2:-1}"; }
gpu_count(){ local n; n="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | wc -l | awk '{print $1}')"; [[ -n "$n" && "$n" != "0" ]] || fail_run "No NVIDIA GPU detected" 60; printf '%s' "$n"; }
cuda_devices(){ local n="$1" out="" i; for ((i=0; i<n; i++)); do [[ -z "$out" ]] && out="$i" || out="${out},${i}"; done; printf '%s' "$out"; }

configure_docker_for_pull(){
  # Full host bootstrap is handled by scripts/common.sh before this script runs.
  if [[ -n "${DOCKER_REGISTRY:-}" && -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    printf '%s\n' "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin >/dev/null || true
  fi
}
docker_pull_with_retry(){
  local image="$1"
  echo "[INFO] trying docker pull: $image"
  if docker pull "$image"; then return 0; fi
  echo "[WARN] docker pull failed; re-applying Docker proxy/daemon config and retrying: $image"
  configure_docker_for_pull || true
  echo "[INFO] retrying docker pull after Docker config refresh: $image"
  docker pull "$image"
}
ensure_image(){
  local image="$1" tar_file="${2:-}" out="" loaded_ref=""
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "[INFO] Docker image exists: $image"
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
        echo "[INFO] Docker image loaded: $image"
        return 0
      fi
      loaded_ref="$(echo "$out" | awk -F': ' '/Loaded image:/ {print $2}' | tail -n 1)"
      if [[ -n "$loaded_ref" ]]; then
        docker tag "$loaded_ref" "$image" || true
        if docker image inspect "$image" >/dev/null 2>&1; then
          echo "[INFO] Docker image loaded and retagged: $image"
          return 0
        fi
      fi
      echo "[WARN] docker load completed but expected tag is still missing: $image"
    else
      echo "$out"
      echo "[WARN] docker load failed; trying docker pull next: $tar_file"
    fi
  else
    echo "[WARN] docker load fallback tar not found; trying docker pull next: ${tar_file:-<empty>}"
  fi
  if docker_pull_with_retry "$image"; then return 0; fi
  fail_run "Docker image missing and fallback-load/pull failed: $image" 24
}
cleanup(){ if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then docker stop -t 30 "$CONTAINER_NAME" >/dev/null 2>&1 || docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; fi; }
trap 'cleanup; emit_summary "stopped" 130 "stopped by signal"; exit 130' INT TERM HUP
mkdir -p "$LOG_DIR" "$RESULT_DIR"; exec > >(tee -a "${LOG_DIR}/run.log") 2>&1
echo "[INFO] log_dir=${LOG_DIR}"

echo "[PHASE] validate"; echo "[INFO] start_time=${START_TIME}"; echo "[INFO] run_id=${RUN_ID}"; echo "[INFO] host=${HOST}"; echo "[INFO] gpu_type=${GPU_TYPE}"; echo "[INFO] mlperf_version=v6.0"; echo "[INFO] benchmark=llama2_70b"; echo "[INFO] nvidia_root=${NVIDIA_ROOT}"; echo "[INFO] bench_code_dir=${BENCH_CODE_DIR}"; echo "[INFO] llmlib_dir=${LLMLIB_DIR}"; echo "[INFO] docker_image=${DOCKER_IMAGE}"; echo "[INFO] docker_image_tar=${DOCKER_IMAGE_TAR}"; echo "[INFO] open_orca_dir=${OPEN_ORCA_DIR}"; echo "[INFO] base_model_dir=${BASE_MODEL_DIR}"; echo "[INFO] quant_model_dir=${QUANT_MODEL_DIR}"; echo "[INFO] preprocessed_dir=${PREPROCESSED_DIR}"; echo "[INFO] engine_dir=${ENGINE_DIR}"
command -v docker >/dev/null 2>&1 || fail_run "docker unavailable" 20; command -v nvidia-smi >/dev/null 2>&1 || fail_run "nvidia-smi unavailable" 21
[[ -d "$NVIDIA_ROOT" ]] || fail_run "NVIDIA root not found: $NVIDIA_ROOT" 23; [[ -f "${NVIDIA_ROOT}/Makefile" ]] || fail_run "Makefile not found at NVIDIA root: ${NVIDIA_ROOT}/Makefile" 23; [[ -d "$BENCH_CODE_DIR" ]] || fail_run "Benchmark code dir not found: $BENCH_CODE_DIR" 23; [[ -f "${BENCH_CODE_DIR}/preprocess_data.py" ]] || fail_run "preprocess_data.py not found: ${BENCH_CODE_DIR}/preprocess_data.py" 23; [[ -d "$LLMLIB_DIR" ]] || fail_run "LLM lib dir not found: $LLMLIB_DIR" 23; [[ -f "${LLMLIB_DIR}/hf_quantize.py" ]] || fail_run "hf_quantize.py not found: ${LLMLIB_DIR}/hf_quantize.py" 23
[[ -d "$OPEN_ORCA_DIR" ]] || fail_run "OpenOrca data not found: $OPEN_ORCA_DIR" 43
if [[ ! -f "${OPEN_ORCA_DIR}/open_orca_gpt4_tokenized_llama.sampled_24576.pkl" && ! -f "${OPEN_ORCA_DIR}/open_orca_gpt4_tokenized_llama.sampled_24576.pkl.gz" ]]; then fail_run "Missing sampled pkl or pkl.gz under: $OPEN_ORCA_DIR" 43; fi
if [[ ! -f "${OPEN_ORCA_DIR}/open_orca_gpt4_tokenized_llama.calibration_1000.pkl" && ! -f "${OPEN_ORCA_DIR}/open_orca_gpt4_tokenized_llama.calibration_1000.pkl.gz" ]]; then fail_run "Missing calibration pkl or pkl.gz under: $OPEN_ORCA_DIR" 43; fi
[[ -d "${NVIDIA_ROOT}/3rdparty" ]] || fail_run "Missing 3rdparty directory: ${NVIDIA_ROOT}/3rdparty" 44; [[ -d "${NVIDIA_ROOT}/3rdparty/trtllm" ]] || fail_run "Missing TensorRT-LLM source: ${NVIDIA_ROOT}/3rdparty/trtllm" 45; [[ -d "${NVIDIA_ROOT}/3rdparty/mlc-inference" ]] || fail_run "Missing MLCommons inference source: ${NVIDIA_ROOT}/3rdparty/mlc-inference" 46
[[ -d "$BASE_MODEL_DIR" ]] || fail_run "Base model not found: $BASE_MODEL_DIR" 47
if [[ -d "$QUANT_MODEL_DIR" ]]; then
  echo "[INFO] quantized FP4 model dir exists: $QUANT_MODEL_DIR"
else
  fail_run "Quantized FP4 model dir not found: $QUANT_MODEL_DIR" 48
fi
GPU_COUNT="$(gpu_count)"; CUDA_VISIBLE_DEVICES_VALUE="${MLPERF_CUDA_VISIBLE_DEVICES:-$(cuda_devices "$GPU_COUNT")}"; if [[ -n "${MLPERF_CUDA_VISIBLE_DEVICES:-}" ]]; then GPU_COUNT="$(awk -F, '{print NF}' <<< "$MLPERF_CUDA_VISIBLE_DEVICES")"; fi; GPU_TYPE_UPPER="$(printf '%s' "$GPU_TYPE" | tr '[:lower:]' '[:upper:]')"
case "$GPU_TYPE_UPPER" in H100) DEFAULT_SYSTEM_NAME="DGX-H100_H100-SXM-80GBx8"; DEFAULT_KNOWN_SYSTEM_CANDIDATES="DGX_H100_H100_SXM_80GBx8 H100_SXM_80GBx8" ;; A100) DEFAULT_SYSTEM_NAME="DGX-A100_A100-SXM-80GBx8"; DEFAULT_KNOWN_SYSTEM_CANDIDATES="DGX_A100_A100_SXM_80GBx8 A100_SXM_80GBx8" ;; V100) DEFAULT_SYSTEM_NAME="DGX-1_V100-SXM2-32GBx8"; DEFAULT_KNOWN_SYSTEM_CANDIDATES="DGX_1_V100_SXM2_32GBx8 V100_SXM2_32GBx8" ;; GH200) DEFAULT_SYSTEM_NAME="GH200_GH200-96GBx1"; DEFAULT_KNOWN_SYSTEM_CANDIDATES="GH200_GH200_96GBx1 GH200" ;; B300) DEFAULT_SYSTEM_NAME="B300_B300-288GBx8"; DEFAULT_KNOWN_SYSTEM_CANDIDATES="B300_B300_288GBx8 B300" ;; *) DEFAULT_SYSTEM_NAME="${GPU_TYPE_UPPER}_${GPU_TYPE_UPPER}x${GPU_COUNT}"; DEFAULT_KNOWN_SYSTEM_CANDIDATES="${GPU_TYPE_UPPER}" ;; esac

echo "[INFO] gpu_count=${GPU_COUNT}"; echo "[INFO] cuda_visible_devices=${CUDA_VISIBLE_DEVICES_VALUE}"; echo "[INFO] default_system_name=${DEFAULT_SYSTEM_NAME}"; echo "[INFO] default_known_system_candidates=${DEFAULT_KNOWN_SYSTEM_CANDIDATES}"
# NVIDIA MLPerf inference Makefile refuses UID 0 inside the container.
# If the launcher is run as root, execute the container as the owner of the
# platform/data directory, preferably /opt/poc-user. This keeps root from
# tripping check_user_requirements while preserving write access to mounted data.
select_container_user(){
  local cand uid gid
  for cand in "/opt/poc-user" "$MLPERF_ROOT" "$DATA_ROOT"; do
    if [[ -e "$cand" ]]; then
      uid="$(stat -c '%u' "$cand" 2>/dev/null || echo 0)"
      gid="$(stat -c '%g' "$cand" 2>/dev/null || echo 0)"
      if [[ -n "$uid" && "$uid" != "0" ]]; then
        HOST_UID="$uid"; HOST_GID="$gid"
        HOST_USER="$(getent passwd "$HOST_UID" 2>/dev/null | awk -F: '{print $1}' || true)"
        HOST_GROUP="$(getent group "$HOST_GID" 2>/dev/null | awk -F: '{print $1}' || true)"
        HOST_USER="${HOST_USER:-mlperf}"
        HOST_GROUP="${HOST_GROUP:-mlperf}"
        return 0
      fi
    fi
  done
  HOST_UID="1000"; HOST_GID="1000"; HOST_USER="mlperf"; HOST_GROUP="mlperf"
}
if [[ "$(id -u)" == "0" ]]; then
  select_container_user
  echo "[INFO] launcher is root; running MLPerf container as non-root uid=${HOST_UID} gid=${HOST_GID}"
else
  HOST_UID="$(id -u)"; HOST_GID="$(id -g)"; HOST_USER="$(id -un 2>/dev/null || echo mlperf)"; HOST_GROUP="$(id -gn 2>/dev/null || echo mlperf)"
fi
CONTAINER_HOME="${LOG_DIR}/container_home"; mkdir -p "$CONTAINER_HOME"; chmod 700 "$CONTAINER_HOME" || true
mkdir -p "$PREPROCESSED_DIR" "$ENGINE_DIR" || true
if [[ "$(id -u)" == "0" ]]; then chown -R "${HOST_UID}:${HOST_GID}" "$LOG_DIR" "$PREPROCESSED_DIR" "$ENGINE_DIR" || true; fi
CONTAINER_PASSWD="${LOG_DIR}/container_passwd"; CONTAINER_GROUP="${LOG_DIR}/container_group"; cat /etc/passwd > "$CONTAINER_PASSWD"; if ! awk -F: -v uid="$HOST_UID" '$3 == uid { found=1 } END { exit !found }' "$CONTAINER_PASSWD"; then echo "${HOST_USER}:x:${HOST_UID}:${HOST_GID}:MLPerf User:${CONTAINER_HOME}:/bin/bash" >> "$CONTAINER_PASSWD"; fi; cat /etc/group > "$CONTAINER_GROUP"; if ! awk -F: -v gid="$HOST_GID" '$3 == gid { found=1 } END { exit !found }' "$CONTAINER_GROUP"; then echo "${HOST_GROUP}:x:${HOST_GID}:" >> "$CONTAINER_GROUP"; fi
DOCKER_SOCK="/var/run/docker.sock"; DOCKER_SOCK_GID=""; [[ -S "$DOCKER_SOCK" ]] && DOCKER_SOCK_GID="$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || true)"
HOST_DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
DOCKER_WRAPPER_DIR="${LOG_DIR}/docker-wrapper"
mkdir -p "$DOCKER_WRAPPER_DIR"
cat > "${DOCKER_WRAPPER_DIR}/docker" <<'DOCKER_WRAP'
#!/usr/bin/env bash
set -Eeuo pipefail
rewrite_arg() {
  local a="$1"
  if [[ "$a" == *"nvcr.io/"* && "$a" != *"proxy-docker-nvcr.io/"* ]]; then
    if [[ "$a" == nvcr.io/* ]]; then a="${NVCR_PULL_PREFIX:-nvcr.io}/${a#nvcr.io/}"; fi
  fi
  printf '%s' "$a"
}
args=()
for a in "$@"; do args+=("$(rewrite_arg "$a")"); done
# Some MLPerf Makefile paths call `${DOCKER} --target ...` while they
# actually mean `docker build --target ...`.  Native docker treats
# top-level --target as an unknown flag, so normalize this pattern.
if [[ "${#args[@]}" -gt 0 ]]; then
  case "${args[0]}" in
    --target|--file|-f|--tag|-t|--build-arg|--network|--label|--cache-from|--cache-to|--load|--push|--progress)
      args=(build "${args[@]}")
      ;;
  esac
fi
exec /usr/bin/docker "${args[@]}"
DOCKER_WRAP
chmod +x "${DOCKER_WRAPPER_DIR}/docker"
add_runtime_group_for_uid(){
  local gid="$1" name="$2"
  [[ -n "$gid" && "$gid" =~ ^[0-9]+$ ]] || return 0
  name="${name}_${gid}"
  if ! awk -F: -v gid="$gid" -v user="$HOST_USER" '($3 == gid && ("," $4 ",") ~ ("," user ",")) { found=1 } END { exit !found }' "$CONTAINER_GROUP"; then
    echo "${name}:x:${gid}:${HOST_USER}" >> "$CONTAINER_GROUP"
  fi
}
RUNTIME_GROUP_ADDS=()
[[ -n "$DOCKER_SOCK_GID" ]] && { add_runtime_group_for_uid "$DOCKER_SOCK_GID" "dockerhost"; RUNTIME_GROUP_ADDS+=("$DOCKER_SOCK_GID"); }
while IFS= read -r dev_gid; do
  add_runtime_group_for_uid "$dev_gid" "nvidiahost"
  RUNTIME_GROUP_ADDS+=("$dev_gid")
done < <(find /dev -maxdepth 2 \( -name 'nvidia*' -o -path '/dev/nvidia-caps/*' \) -printf '%g\n' 2>/dev/null | sort -nu)
# De-duplicate supplemental gids before docker --group-add.
if [[ "${#RUNTIME_GROUP_ADDS[@]}" -gt 0 ]]; then
  mapfile -t RUNTIME_GROUP_ADDS < <(printf '%s\n' "${RUNTIME_GROUP_ADDS[@]}" | awk 'NF && !seen[$0]++')
fi
echo "[INFO] remote_user=${HOST_USER}"; echo "[INFO] remote_uid=${HOST_UID}"; echo "[INFO] remote_gid=${HOST_GID}"; echo "[INFO] remote_group=${HOST_GROUP}"; echo "[INFO] container_home=${CONTAINER_HOME}"; [[ -n "$DOCKER_SOCK_GID" ]] && { echo "[INFO] docker_sock=${DOCKER_SOCK}"; echo "[INFO] docker_sock_gid=${DOCKER_SOCK_GID}"; } || echo "[WARN] docker socket not found or gid unavailable: ${DOCKER_SOCK}"; [[ -n "$HOST_DOCKER_BIN" ]] && echo "[INFO] host_docker_cli=${HOST_DOCKER_BIN}" || echo "[WARN] host docker CLI not found for container mount"; [[ "${#RUNTIME_GROUP_ADDS[@]}" -gt 0 ]] && echo "[INFO] runtime supplemental gids=${RUNTIME_GROUP_ADDS[*]}"
ensure_image "$DOCKER_IMAGE" "$DOCKER_IMAGE_TAR"; if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then fail_run "Container already exists: $CONTAINER_NAME" 25; fi
DOCKER_GPU_ARGS=(--gpus all)
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
  DOCKER_GPU_ARGS=(--runtime=nvidia --gpus all)
fi
CONTAINER_CMD='set -Eeuo pipefail
trap '\''echo "[CONTAINER][FATAL] command failed at line ${LINENO}: ${BASH_COMMAND}" >&2'\'' ERR
cd "$NVIDIA_ROOT"; mkdir -p "$RESULT_DIR"
if [[ ! -d /data ]]; then echo "[CONTAINER][FATAL] /data bind mount is missing" >&2; exit 65; fi
echo "[CONTAINER] data_dir=/data"
ls -ld /data || true
if [[ -n "${CONFIG_PATH:-}" && -f "${CONFIG_PATH}" && "${MLPERF_SOURCE_EXTERNAL_CONFIG:-0}" == "1" ]]; then echo "[CONTAINER] sourcing external config: $CONFIG_PATH"; source "$CONFIG_PATH"; fi
if [[ -n "${MLPERF_RUN_CMD:-}" ]]; then echo "[CONTAINER] executing MLPERF_RUN_CMD override"; exec bash -lc "$MLPERF_RUN_CMD"; fi
export MLPERF_INFER_PREBUILD="${MLPERF_INFER_PREBUILD:-0}" MLPERF_INFER_PREPROCESS="${MLPERF_INFER_PREPROCESS:-1}" MLPERF_INFER_RUN_SERVER="${MLPERF_INFER_RUN_SERVER:-1}" MLPERF_INFER_RUN_HARNESS="${MLPERF_INFER_RUN_HARNESS:-1}"
export MLPERF_INFER_SCENARIO="${MLPERF_INFER_SCENARIO:-Offline}" MLPERF_INFER_CORE_TYPE="${MLPERF_INFER_CORE_TYPE:-trtllm_endpoint}" MLPERF_INFER_ACCURACY_TARGET="${MLPERF_INFER_ACCURACY_TARGET:-.999}" MLPERF_INFER_TEST_MODE="${MLPERF_INFER_TEST_MODE:-AccuracyOnly}" MLPERF_INFER_SERVER_WAIT_SEC="${MLPERF_INFER_SERVER_WAIT_SEC:-180}"
export MLPERF_INFER_SYSTEM_NAME="${MLPERF_INFER_SYSTEM_NAME:-$DEFAULT_SYSTEM_NAME}" MLPERF_INFER_KNOWN_SYSTEM_CANDIDATES="${MLPERF_INFER_KNOWN_SYSTEM_CANDIDATES:-$DEFAULT_KNOWN_SYSTEM_CANDIDATES}" MLPERF_INFER_TP_SIZE="${MLPERF_INFER_TP_SIZE:-${MLPERF_NUM_GPUS:-8}}" MLPERF_INFER_GPU_BATCH_SIZE="${MLPERF_INFER_GPU_BATCH_SIZE:-1}" MLPERF_INFER_OFFLINE_QPS="${MLPERF_INFER_OFFLINE_QPS:-1.0}" MLPERF_INFER_MIN_DURATION_MS="${MLPERF_INFER_MIN_DURATION_MS:-60000}" MLPERF_INFER_MIN_QUERY_COUNT="${MLPERF_INFER_MIN_QUERY_COUNT:-1}" MLPERF_INFER_OVERWRITE_CONFIG="${MLPERF_INFER_OVERWRITE_CONFIG:-1}" MLPERF_INFER_SCENARIO="${MLPERF_INFER_SCENARIO:-Offline}" MLPERF_INFER_ACCURACY_TARGET="${MLPERF_INFER_ACCURACY_TARGET:-.999}" MLPERF_INFER_TEST_MODE="${MLPERF_INFER_TEST_MODE:-AccuracyOnly}" MLPERF_INFER_CORE_TYPE="${MLPERF_INFER_CORE_TYPE:-trtllm_endpoint}" MLPERF_RUN_ARGS_EXTRA="${MLPERF_RUN_ARGS_EXTRA:-}"
echo "[INFO] effective inference env after remote forwarding:"
for env_name in MLPERF_INFER_SCENARIO MLPERF_INFER_CORE_TYPE MLPERF_INFER_TP_SIZE MLPERF_INFER_GPU_BATCH_SIZE MLPERF_INFER_OFFLINE_QPS MLPERF_INFER_MIN_DURATION_MS MLPERF_INFER_MIN_QUERY_COUNT MLPERF_INFER_ACCURACY_TARGET MLPERF_INFER_TEST_MODE MLPERF_RUN_ARGS_EXTRA MLPERF_INFER_PREBUILD MLPERF_INFER_PREPROCESS MLPERF_INFER_RUN_SERVER MLPERF_INFER_RUN_HARNESS MLPERF_INFER_SERVER_WAIT_SEC; do
  if [[ -n "${!env_name:-}" ]]; then printf "[INFO]   %s=%q\n" "$env_name" "${!env_name}"; fi
done
GEN_CONFIG_PATH="${RESULT_DIR}/generation_config.json"; mkdir -p "$(dirname "$GEN_CONFIG_PATH")"; cat > "$GEN_CONFIG_PATH" <<JSON
{"generation_config":{"eos_token_id":2,"bos_token_id":1,"max_output_len":1024,"min_output_len":1,"name":"llama","runtime_beam_width":1,"streaming":false,"temperature":1.0,"top_k":1,"top_p":0.001,"use_stop_tokens":false,"skip_special_tokens":true}}
JSON
create_basic_llama2_config(){ local system_name config_root config_dir config_file; system_name="${MLPERF_INFER_SYSTEM_NAME}"; config_root="${NVIDIA_ROOT}/configs"; config_dir="${config_root}/${system_name}/${MLPERF_INFER_SCENARIO}"; config_file="${config_dir}/llama2-70b.py"; mkdir -p "$config_dir"; touch "${config_root}/__init__.py" "${config_root}/${system_name}/__init__.py" "${config_dir}/__init__.py"; echo "[CONTAINER][PHASE] generating local config with fallback ATOMIC_EXPORTS: $config_file"; cat > "$config_file" <<PYCONF
from code.fields import general as gen_fields
from code.fields import loadgen as lg_fields
from code.fields import harness as harness_fields
from code.fields import models as model_fields
from code.fields import gen_engines as builder_fields
from code.llmlib import fields as llm_fields
def _field(module, name):
    value = getattr(module, name, None)
    if value is None:
        print(f"[LOCAL_CONFIG][WARN] missing field: {module.__name__}.{name}; skipping")
        return None
    return value
def _put(cfg, field, value):
    if field is not None:
        cfg[field] = value
_LOCAL_CONFIG = {}
_put(_LOCAL_CONFIG, _field(harness_fields, "core_type"), "${MLPERF_INFER_CORE_TYPE}")
_put(_LOCAL_CONFIG, _field(harness_fields, "gpu_indices"), "${CUDA_VISIBLE_DEVICES}")
_put(_LOCAL_CONFIG, _field(harness_fields, "config_id"), "default")
_put(_LOCAL_CONFIG, _field(harness_fields, "mpi_mode"), "leader")
_put(_LOCAL_CONFIG, _field(lg_fields, "offline_expected_qps"), float("${MLPERF_INFER_OFFLINE_QPS}"))
_put(_LOCAL_CONFIG, _field(lg_fields, "min_duration"), int("${MLPERF_INFER_MIN_DURATION_MS}"))
_put(_LOCAL_CONFIG, _field(lg_fields, "min_query_count"), int("${MLPERF_INFER_MIN_QUERY_COUNT}"))
_put(_LOCAL_CONFIG, _field(lg_fields, "performance_sample_count"), 24576)
_put(_LOCAL_CONFIG, _field(lg_fields, "accuracy_sample_count_override"), 1000)
_put(_LOCAL_CONFIG, _field(lg_fields, "test_mode"), "AccuracyOnly")
_put(_LOCAL_CONFIG, _field(gen_fields, "log_dir"), "${RESULT_DIR}")
_put(_LOCAL_CONFIG, _field(gen_fields, "engine_dir"), "${ENGINE_DIR}")
_put(_LOCAL_CONFIG, _field(gen_fields, "preprocessed_data_dir"), "${PREPROCESSED_DIR}")
_put(_LOCAL_CONFIG, _field(model_fields, "model_path"), "${BASE_MODEL_DIR}")
_put(_LOCAL_CONFIG, _field(model_fields, "precision"), "fp4")
_put(_LOCAL_CONFIG, _field(builder_fields, "calib_data_dir"), "${NVIDIA_ROOT}/build/preprocessed-data/llama2-70b/mlperf_llama2_openorca_calibration_1k")
_put(_LOCAL_CONFIG, _field(builder_fields, "calib_batch_size"), 1024)
_put(_LOCAL_CONFIG, _field(builder_fields, "calib_max_batches"), 1)
_put(_LOCAL_CONFIG, _field(builder_fields, "force_calibration"), False)
_put(_LOCAL_CONFIG, _field(builder_fields, "force_build_engines"), False)
_put(_LOCAL_CONFIG, _field(llm_fields, "llm_gen_config_path"), "${GEN_CONFIG_PATH}")
_put(_LOCAL_CONFIG, _field(llm_fields, "gen_config_path"), "${GEN_CONFIG_PATH}")
_put(_LOCAL_CONFIG, _field(gen_fields, "gen_config_path"), "${GEN_CONFIG_PATH}")
_LOCAL_CONFIG.setdefault("gen_config_path", "${GEN_CONFIG_PATH}")
_LOCAL_CONFIG.setdefault("llm_gen_config_path", "${GEN_CONFIG_PATH}")
_LOCAL_CONFIG.setdefault("generation_config_path", "${GEN_CONFIG_PATH}")
_put(_LOCAL_CONFIG, _field(llm_fields, "trtllm_lib_path"), "${NVIDIA_ROOT}/3rdparty/trtllm")
_put(_LOCAL_CONFIG, _field(llm_fields, "quantizer_lib_path_override"), "/work/code/llmlib")
_put(_LOCAL_CONFIG, _field(llm_fields, "tensor_parallelism"), ${MLPERF_INFER_TP_SIZE})
_put(_LOCAL_CONFIG, _field(llm_fields, "pipeline_parallelism"), 1)
_put(_LOCAL_CONFIG, _field(llm_fields, "quantizer_outdir"), "${QUANT_MODEL_DIR}")
_put(_LOCAL_CONFIG, _field(llm_fields, "capture_server_logs_dir"), "${RESULT_DIR}/server_logs")
_put(_LOCAL_CONFIG, _field(llm_fields, "trtllm_yml_override"), None)
_put(_LOCAL_CONFIG, _field(llm_fields, "trtllm_server_urls"), "0.0.0.0:30000")
_put(_LOCAL_CONFIG, _field(llm_fields, "readiness_timeout"), 300)
_put(_LOCAL_CONFIG, _field(llm_fields, "trtllm_build_flags"), {"max_batch_size":1,"max_num_tokens":8192,"max_input_len":2048,"max_seq_len":3072,"enable_attention_dp":None})
_put(_LOCAL_CONFIG, _field(llm_fields, "trtllm_runtime_flags"), {"trtllm_backend":"pytorch","max_batch_size":1,"max_num_tokens":8192,"max_concurrency":1,"kvcache_free_gpu_mem_frac":0.80,"enable_chunked_context":False,"workers_per_core":2,"http_backend":"custom_http"})
_put(_LOCAL_CONFIG, _field(llm_fields, "trtllm_checkpoint_flags"), {"kv_cache_dtype":None})
class _AnyAtomicExports(dict):
    def __getitem__(self, workload_setting):
        print("[LOCAL_CONFIG] ATOMIC_EXPORTS fallback for workload_setting =", workload_setting)
        return {"default": _LOCAL_CONFIG, "dynamo_cluster": _LOCAL_CONFIG}
    def get(self, workload_setting, default=None): return self.__getitem__(workload_setting)
    def keys(self): return ["<any WorkloadSetting>"]
    def items(self): return []
class _AnyExports(dict):
    def __getitem__(self, workload_setting):
        print("[LOCAL_CONFIG] EXPORTS fallback for workload_setting =", workload_setting)
        return _LOCAL_CONFIG
    def get(self, workload_setting, default=None): return self.__getitem__(workload_setting)
    def keys(self): return ["<any WorkloadSetting>"]
    def items(self): return []
ATOMIC_EXPORTS = _AnyAtomicExports(); EXPORTS = _AnyExports()
PYCONF
sed -n "1,320p" "$config_file"; }
SERVER_PID=""; stop_server(){ if [[ -n "$SERVER_PID" ]]; then echo "[CONTAINER] stopping LLM server pid=$SERVER_PID"; kill "$SERVER_PID" >/dev/null 2>&1 || true; wait "$SERVER_PID" >/dev/null 2>&1 || true; fi; }; trap stop_server EXIT
if [[ ! -d /data ]]; then echo "[CONTAINER][FATAL] /data bind mount is missing" >&2; exit 65; fi
if [[ ! -d /preprocessed_data ]]; then echo "[CONTAINER][FATAL] /preprocessed_data bind mount is missing" >&2; exit 66; fi
if [[ ! -d /model ]]; then echo "[CONTAINER][FATAL] /model bind mount is missing" >&2; exit 67; fi
echo "[CONTAINER] data_dir=/data"
echo "[CONTAINER] preprocessed_data_dir=/preprocessed_data"
echo "[CONTAINER] model_dir=/model"
ls -ld /data /preprocessed_data /model || true
echo "[CONTAINER] inference v6.0 llama2_70b"; grep -nE "^(prebuild|run_llm_server|run_harness|build|generate_engines):" Makefile Makefile.* 2>/dev/null || true
create_basic_llama2_config
run_prebuild(){ make prebuild ENV=release BENCHMARK=llama || make prebuild ENV=release BENCHMARKS=llama || make prebuild; }
if [[ "${MLPERF_INFER_PREBUILD:-1}" == "1" ]]; then echo "[CONTAINER][PHASE] make prebuild"; run_prebuild; else echo "[CONTAINER][SKIP] make prebuild"; fi
mkdir -p build/data/llama2-70b
if [[ -f /open_orca_src/open_orca_gpt4_tokenized_llama.sampled_24576.pkl ]]; then cp -f /open_orca_src/open_orca_gpt4_tokenized_llama.sampled_24576.pkl build/data/llama2-70b/; else gzip -dc /open_orca_src/open_orca_gpt4_tokenized_llama.sampled_24576.pkl.gz > build/data/llama2-70b/open_orca_gpt4_tokenized_llama.sampled_24576.pkl; fi
if [[ -f /open_orca_src/open_orca_gpt4_tokenized_llama.calibration_1000.pkl ]]; then cp -f /open_orca_src/open_orca_gpt4_tokenized_llama.calibration_1000.pkl build/data/llama2-70b/; else gzip -dc /open_orca_src/open_orca_gpt4_tokenized_llama.calibration_1000.pkl.gz > build/data/llama2-70b/open_orca_gpt4_tokenized_llama.calibration_1000.pkl; fi
if [[ "$MLPERF_INFER_PREPROCESS" == "1" ]]; then python3 code/llama2-70b/tensorrt/preprocess_data.py --data_dir build/data/ --preprocessed_data_dir build/preprocessed-data; else echo "[CONTAINER][SKIP] preprocess_data.py"; fi
[[ -d build/preprocessed-data && ! -e build/preprocessed_data ]] && ln -sfn preprocessed-data build/preprocessed_data
SERVER_RUN_ARGS="--benchmarks=llama2-70b --scenarios=${MLPERF_INFER_SCENARIO} --core_type=${MLPERF_INFER_CORE_TYPE} ${MLPERF_RUN_ARGS_EXTRA}"
HARNESS_RUN_ARGS="--benchmarks=llama2-70b --scenarios=${MLPERF_INFER_SCENARIO} --core_type=${MLPERF_INFER_CORE_TYPE} --accuracy_target=${MLPERF_INFER_ACCURACY_TARGET} --test_mode=${MLPERF_INFER_TEST_MODE} ${MLPERF_RUN_ARGS_EXTRA}"
run_make_server(){ make run_llm_server SYSTEM_NAME="$MLPERF_INFER_SYSTEM_NAME" RUN_ARGS="$SERVER_RUN_ARGS"; }
run_make_harness(){ make run_harness SYSTEM_NAME="$MLPERF_INFER_SYSTEM_NAME" RUN_ARGS="$HARNESS_RUN_ARGS"; }
if [[ "$MLPERF_INFER_RUN_SERVER" == "1" ]]; then set +e; run_make_server > "${RESULT_DIR}/llm_server.log" 2>&1 & SERVER_PID="$!"; set -e; sleep "$MLPERF_INFER_SERVER_WAIT_SEC"; if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then tail -500 "${RESULT_DIR}/llm_server.log" || true; wait "$SERVER_PID" || true; exit 55; fi; tail -160 "${RESULT_DIR}/llm_server.log" || true; else echo "[CONTAINER][SKIP] make run_llm_server"; fi
if [[ "$MLPERF_INFER_RUN_HARNESS" == "1" ]]; then run_make_harness; else echo "[CONTAINER][SKIP] make run_harness"; fi
echo "[CONTAINER] inference v6.0 completed"'
printf '%s\n' "$CONTAINER_CMD" > "${LOG_DIR}/container_entrypoint_inline.sh"
CONTAINER_ROOT_WRAPPER='set -Eeuo pipefail
echo "[CONTAINER][ROOT] nvidia preflight"
if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi -L || true; else echo "[CONTAINER][ROOT][WARN] nvidia-smi not found before user switch"; fi
if [[ "$(id -u)" == "0" && -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  echo "[CONTAINER][ROOT] switching to uid=${HOST_UID} gid=${HOST_GID} user=${HOST_USER:-mlperf} for MLPerf Makefile"
  export HOME="${HOME:-${MLPERF_LOG_DIR}/container_home}" USER="${HOST_USER:-mlperf}" LOGNAME="${HOST_USER:-mlperf}"
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid="${HOST_UID}" --regid="${HOST_GID}" --keep-groups bash -lc "cd \"${NVIDIA_ROOT}\" && bash \"${MLPERF_LOG_DIR}/container_entrypoint_inline.sh\""
  elif command -v runuser >/dev/null 2>&1; then
    exec runuser -u "${HOST_USER:-mlperf}" -- bash -lc "cd \"${NVIDIA_ROOT}\" && bash \"${MLPERF_LOG_DIR}/container_entrypoint_inline.sh\""
  else
    echo "[CONTAINER][ROOT][WARN] setpriv/runuser unavailable; running command as root may trip MLPerf check_user_requirements"
  fi
fi
exec bash "${MLPERF_LOG_DIR}/container_entrypoint_inline.sh"' 
DOCKER_CMD=(docker run --rm --name "$CONTAINER_NAME" --network=host --ipc=host "${DOCKER_GPU_ARGS[@]}" --privileged --shm-size=32gb --ulimit memlock=-1 --ulimit stack=67108864 -v "${CONTAINER_PASSWD}:/etc/passwd:ro" -v "${CONTAINER_GROUP}:/etc/group:ro" -v "${NVIDIA_ROOT}:${NVIDIA_ROOT}" -v "${DATA_ROOT}:${DATA_ROOT}" -v "${DATA_ROOT}:/data" -v "${PREPROCESSED_DIR}:/preprocessed_data" -v "${BASE_MODEL_DIR}:/model:ro" -v "${QUANT_MODEL_DIR}:/model_fp4:ro" -v "${ENGINE_DIR}:/engines" -v "${LOG_DIR}:${LOG_DIR}" -v "${CONTAINER_HOME}:${CONTAINER_HOME}" -v "${OPEN_ORCA_DIR}:/open_orca_src:ro" -v "${LLMLIB_DIR}:/work/code/llmlib:ro" -w "$NVIDIA_ROOT" -e "NVIDIA_DRIVER_CAPABILITIES=all" -e "NVIDIA_DISABLE_REQUIRE=1" -e "CUDA_MODULE_LOADING=LAZY" -e "HOST_USER=${HOST_USER}" -e "HOST_UID=${HOST_UID}" -e "HOST_GID=${HOST_GID}" -e "HOME=${CONTAINER_HOME}" -e "USER=${HOST_USER}" -e "LOGNAME=${HOST_USER}" -e "NVIDIA_ROOT=${NVIDIA_ROOT}" -e "BENCH_CODE_DIR=${BENCH_CODE_DIR}" -e "CONFIG_PATH=${CONFIG_PATH}" -e "MLPERF_LOG_DIR=${LOG_DIR}" -e "RESULT_DIR=${RESULT_DIR}" -e "MLPERF_GPU_TYPE=${GPU_TYPE}" -e "MLPERF_NUM_GPUS=${GPU_COUNT}" -e "NUM_GPUS=${GPU_COUNT}" -e "GPUS_PER_NODE=${GPU_COUNT}" -e "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES_VALUE}" -e "NVIDIA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES_VALUE}" -e "BASE_MODEL_DIR=${BASE_MODEL_DIR}" -e "QUANT_MODEL_DIR=${QUANT_MODEL_DIR}" -e "PREPROCESSED_DIR=${PREPROCESSED_DIR}" -e "ENGINE_DIR=${ENGINE_DIR}" -e "DATA_DIR=/data" -e "MLPERF_DATA_DIR=/data" -e "PREPROCESSED_DATA_DIR=/preprocessed_data" -e "MLPERF_PREPROCESSED_DATA_DIR=/preprocessed_data" -e "MODEL_DIR=/model" -e "MLPERF_MODEL_DIR=/model" -e "QUANT_MODEL_DIR_CONTAINER=/model_fp4" -e "GPU_TYPE_UPPER=${GPU_TYPE_UPPER}" -e "DEFAULT_SYSTEM_NAME=${DEFAULT_SYSTEM_NAME}" -e "DEFAULT_KNOWN_SYSTEM_CANDIDATES=${DEFAULT_KNOWN_SYSTEM_CANDIDATES}")
if [[ -S "$DOCKER_SOCK" ]]; then DOCKER_CMD+=(-v "${DOCKER_SOCK}:${DOCKER_SOCK}" -e "DOCKER_HOST=unix://${DOCKER_SOCK}"); fi
DOCKER_CMD+=(-v "${DOCKER_WRAPPER_DIR}/docker:/usr/local/bin/docker:ro")
if [[ -n "$HOST_DOCKER_BIN" && -x "$HOST_DOCKER_BIN" ]]; then DOCKER_CMD+=(-v "${HOST_DOCKER_BIN}:/usr/bin/docker:ro"); fi
for runtime_gid in "${RUNTIME_GROUP_ADDS[@]}"; do DOCKER_CMD+=(--group-add "$runtime_gid"); done
[[ -f "$CERT_FILE" ]] && DOCKER_CMD+=(-v "${CERT_FILE}:/etc/ssl/certs/ca-certificates.crt:ro")
for env_name in MLPERF_SOURCE_EXTERNAL_CONFIG MLPERF_RUN_CMD MLPERF_RUN_ARGS_EXTRA MLPERF_INFER_SYSTEM_NAME MLPERF_INFER_KNOWN_SYSTEM_CANDIDATES MLPERF_INFER_TP_SIZE MLPERF_INFER_GPU_BATCH_SIZE MLPERF_INFER_OFFLINE_QPS MLPERF_INFER_MIN_DURATION_MS MLPERF_INFER_MIN_QUERY_COUNT MLPERF_INFER_SCENARIO MLPERF_INFER_ACCURACY_TARGET MLPERF_INFER_TEST_MODE MLPERF_INFER_CORE_TYPE MLPERF_INFER_PREBUILD MLPERF_INFER_PREPROCESS MLPERF_INFER_RUN_SERVER MLPERF_INFER_RUN_HARNESS MLPERF_INFER_SERVER_WAIT_SEC; do [[ -n "${!env_name:-}" ]] && DOCKER_CMD+=(-e "${env_name}=${!env_name}"); done
DOCKER_CMD+=("$DOCKER_IMAGE" bash -lc "$CONTAINER_ROOT_WRAPPER")
printf '%q ' "${DOCKER_CMD[@]}" > "${LOG_DIR}/command.txt"; printf '\n' >> "${LOG_DIR}/command.txt"; echo "[INFO] exact Docker command:"; cat "${LOG_DIR}/command.txt"
if [[ "$DRY_RUN" == "true" ]]; then echo "[PHASE] dry-run"; emit_summary "success" 0 "dry-run completed"; exit 0; fi
echo "[PHASE] run"; set +e; "${DOCKER_CMD[@]}"; EXIT_CODE="$?"; set -e
echo "[PHASE] collect"; echo "[INFO] docker_exit_code=${EXIT_CODE}"
if [[ "$EXIT_CODE" -eq 0 ]]; then echo "[PHASE] done"; emit_summary "success" "$EXIT_CODE" "inference v6.0 completed successfully"; exit 0; else echo "[PHASE] done"; emit_summary "failed" "$EXIT_CODE" "inference v6.0 failed; inspect run.log, command.txt, and results/llm_server.log"; exit "$EXIT_CODE"; fi
REMOTE_RUN
