#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/pd/pd_serve_vllm.sh
# --------------------------
# Brings up a vLLM Prefill/Decode disaggregated topology and runs
# `vllm bench serve` against the proxy.  Modeled directly on the user's
# working `run_multi_nixl.sh` script (NIXL transport).
#
# Architecture
#   * Prefill containers run on prefill_hosts, kv_role=kv_producer
#   * Decode containers run on decode_hosts,  kv_role=kv_consumer
#   * One `toy_proxy_server.py` runs LOCALLY (on the platform host) and
#     fronts both tiers; bench targets the proxy.
#   * Each container is a SEPARATE docker container (no Ray).  All
#     containers share the host network so the proxy can reach them by IP.
#
# Defaults match the user's environment:
#   image:       vllm-openai-nixl:v0.14.0   (custom user build with NIXL)
#   model dir:   /opt/poc-platform/models/<MODEL_NAME>
#   dataset:     /opt/poc-platform/datasets/ShareGPT_V3_unfiltered_cleaned_split.json
#   vllm src:    /opt/poc-platform/vllm  (for toy_proxy_server.py)
#   encodings:   /opt/poc-platform/encodings -> /etc/encodings
#
# Port plan (matches user's run_multi_nixl.sh)
#   PORT_BLOCK=100, case_idx*PORT_BLOCK is added to base ports
#   prefill: 12000+,  decode: 13000+,  proxy: 14000+, side_channel: 5600+
#   internal vllm port (env): prefill=24000+, decode=25000+
#
# Stdout schema:
#   [PHASE] validate|prepare|prefill_serve|decode_serve|wait|proxy|bench|collect|done|stop
#   PD_BENCH_RESULT_JSON={ ... }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

usage() {
  cat <<'EOU'
Usage:
  ./pd_serve_vllm.sh \
    --run-id pd_001 \
    --gpu-type H100 \
    --leader gpu-node01 \
    --prefill-hosts gpu-node01 --prefill-tp 4 \
    --decode-hosts  gpu-node02 --decode-tp 4 \
    --model Qwen3-32B \
    --bench-data sharegpt
EOU
}

MODE="run"
RUN_ID=""
GPU_TYPE=""
LEADER=""
PREFILL_HOSTS_CSV=""
DECODE_HOSTS_CSV=""
PREFILL_TP=""
DECODE_TP=""
PREFILL_INSTANCES="1"
DECODE_INSTANCES="1"
MODEL=""
MODEL_PATH=""
BENCH_DATA="sharegpt"
NUM_PROMPTS=""
REQUEST_RATE=""
MAX_MODEL_LEN=""
DOCKER_IMAGE=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
LOG_ROOT=""
EXTRA_ARGS=""
EXTRA_DOCKER_ARGS=""
PREFILL_EXTRA_ARGS=""
DECODE_EXTRA_ARGS=""
PREFILL_EXTRA_DOCKER_ARGS=""
DECODE_EXTRA_DOCKER_ARGS=""
PREFILL_SPECS=""
DECODE_SPECS=""
PROXY_PORT_CLI=""
GPU_MAPS=()
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE="stop"; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --leader) LEADER="${2:-}"; shift 2 ;;
    --prefill-hosts) PREFILL_HOSTS_CSV="${2:-}"; shift 2 ;;
    --decode-hosts) DECODE_HOSTS_CSV="${2:-}"; shift 2 ;;
    --prefill-tp) PREFILL_TP="${2:-}"; shift 2 ;;
    --decode-tp) DECODE_TP="${2:-}"; shift 2 ;;
    --prefill-instances) PREFILL_INSTANCES="${2:-}"; shift 2 ;;
    --decode-instances) DECODE_INSTANCES="${2:-}"; shift 2 ;;
    --prefill-specs) PREFILL_SPECS="${2:-}"; shift 2 ;;
    --decode-specs) DECODE_SPECS="${2:-}"; shift 2 ;;
    --proxy-port) PROXY_PORT_CLI="${2:-}"; shift 2 ;;
    --extra-docker-args) EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --prefill-extra-args) PREFILL_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --decode-extra-args) DECODE_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --prefill-extra-docker-args) PREFILL_EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --decode-extra-docker-args) DECODE_EXTRA_DOCKER_ARGS="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --bench-data) BENCH_DATA="${2:-}"; shift 2 ;;
    --num-prompts) NUM_PROMPTS="${2:-}"; shift 2 ;;
    --request-rate) REQUEST_RATE="${2:-}"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="${2:-}"; shift 2 ;;
    --docker-image) DOCKER_IMAGE="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --extra-args) EXTRA_ARGS="${2:-}"; shift 2 ;;
    --gpu-map) GPU_MAPS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; cm_die "Unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || cm_die "--run-id required"
[[ -n "$LEADER" ]] || cm_die "--leader required"
[[ -n "$PREFILL_HOSTS_CSV" ]] || cm_die "--prefill-hosts required"
[[ -n "$DECODE_HOSTS_CSV"  ]] || cm_die "--decode-hosts required"
cm_validate_run_id "$RUN_ID"
cm_validate_host "$LEADER"

IFS=',' read -ra PHOSTS_RAW <<< "$PREFILL_HOSTS_CSV"
IFS=',' read -ra DHOSTS_RAW <<< "$DECODE_HOSTS_CSV"
for h in "${PHOSTS_RAW[@]}" "${DHOSTS_RAW[@]}"; do cm_validate_host "$h"; done
[[ "$PREFILL_INSTANCES" =~ ^[0-9]+$ && "$PREFILL_INSTANCES" -ge 1 ]] || cm_die "--prefill-instances must be >= 1"
[[ "$DECODE_INSTANCES" =~ ^[0-9]+$ && "$DECODE_INSTANCES" -ge 1 ]] || cm_die "--decode-instances must be >= 1"
PHOSTS=(); DHOSTS=()
declare -a PRE_SPEC_NUM_GPUS PRE_SPEC_TP PRE_SPEC_CUDA PRE_SPEC_GPU_UTIL PRE_SPEC_MAXLEN PRE_SPEC_PORT
declare -a DEC_SPEC_NUM_GPUS DEC_SPEC_TP DEC_SPEC_CUDA DEC_SPEC_GPU_UTIL DEC_SPEC_MAXLEN DEC_SPEC_PORT
parse_instance_specs() {
  local role="$1" raw="$2" entry h ng tp cuda util maxlen port i=0
  [[ -n "$raw" ]] || return 1
  IFS='|' read -ra _ENTRIES <<< "$raw"
  for entry in "${_ENTRIES[@]}"; do
    [[ -n "$entry" ]] || continue
    IFS='^' read -r h ng tp cuda util maxlen port <<< "$entry"
    cm_validate_host "$h"
    if [[ "$role" == "prefill" ]]; then
      PHOSTS+=("$h"); PRE_SPEC_NUM_GPUS[i]="${ng:-}"; PRE_SPEC_TP[i]="${tp:-}"; PRE_SPEC_CUDA[i]="${cuda:-}"; PRE_SPEC_GPU_UTIL[i]="${util:-}"; PRE_SPEC_MAXLEN[i]="${maxlen:-}"; PRE_SPEC_PORT[i]="${port:-}"
    else
      DHOSTS+=("$h"); DEC_SPEC_NUM_GPUS[i]="${ng:-}"; DEC_SPEC_TP[i]="${tp:-}"; DEC_SPEC_CUDA[i]="${cuda:-}"; DEC_SPEC_GPU_UTIL[i]="${util:-}"; DEC_SPEC_MAXLEN[i]="${maxlen:-}"; DEC_SPEC_PORT[i]="${port:-}"
    fi
    i=$((i+1))
  done
  return 0
}
if ! parse_instance_specs prefill "$PREFILL_SPECS"; then
  for ((i=0; i<PREFILL_INSTANCES; i++)); do PHOSTS+=("${PHOSTS_RAW[$(( i % ${#PHOSTS_RAW[@]} ))]}"); done
fi
if ! parse_instance_specs decode "$DECODE_SPECS"; then
  for ((i=0; i<DECODE_INSTANCES; i++)); do DHOSTS+=("${DHOSTS_RAW[$(( i % ${#DHOSTS_RAW[@]} ))]}"); done
fi
P_N="${#PHOSTS[@]}"
D_N="${#DHOSTS[@]}"
PREFILL_INSTANCES="$P_N"
DECODE_INSTANCES="$D_N"

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

count_role_instances_for_host() {
  local role="$1" target="$2" c=0 h
  if [[ "$role" == "prefill" ]]; then
    for h in "${PHOSTS[@]}"; do [[ "$h" == "$target" ]] && c=$((c+1)); done
  else
    for h in "${DHOSTS[@]}"; do [[ "$h" == "$target" ]] && c=$((c+1)); done
  fi
  echo "$c"
}
occurrence_index_for_role_host() {
  local role="$1" target="$2" upto="$3" c=0 i
  if [[ "$role" == "prefill" ]]; then
    for ((i=0; i<upto; i++)); do [[ "${PHOSTS[i]}" == "$target" ]] && c=$((c+1)); done
  else
    for ((i=0; i<upto; i++)); do [[ "${DHOSTS[i]}" == "$target" ]] && c=$((c+1)); done
  fi
  echo "$c"
}
remote_gpu_count_for_host() {
  local h="$1" n
  n="$(cm_remote_bash "$h" <<'GPUC'
nvidia-smi -L 2>/dev/null | wc -l
GPUC
)"
  n="$(echo "$n" | tr -dc '0-9')"
  [[ -n "$n" && "$n" != "0" ]] || n=1
  echo "$n"
}
split_visible_for_instance() {
  local h="$1" role="$2" idx="$3" base total instances occ chunk start end arr out i
  if [[ "$role" == "prefill" && -n "${PRE_SPEC_CUDA[$idx]:-}" ]]; then printf '%s' "${PRE_SPEC_CUDA[$idx]}"; return 0; fi
  if [[ "$role" == "decode" && -n "${DEC_SPEC_CUDA[$idx]:-}" ]]; then printf '%s' "${DEC_SPEC_CUDA[$idx]}"; return 0; fi
  base="$(gpu_visible_for_host "$h")"
  if [[ -n "$base" ]]; then
    IFS=',' read -ra arr <<< "$base"
    total="${#arr[@]}"
  else
    total="$(remote_gpu_count_for_host "$h")"
    arr=(); for ((i=0; i<total; i++)); do arr+=("$i"); done
  fi
  instances="$(count_role_instances_for_host "$role" "$h")"
  occ="$(occurrence_index_for_role_host "$role" "$h" "$idx")"
  chunk=$(( total / instances )); [[ "$chunk" -ge 1 ]] || chunk=1
  start=$(( occ * chunk )); end=$(( start + chunk - 1 )); (( end >= total )) && end=$(( total - 1 ))
  out=""
  for ((i=start; i<=end; i++)); do [[ -z "$out" ]] && out="${arr[i]}" || out="$out,${arr[i]}"; done
  printf '%s' "$out"
}

if [[ "$MODE" == "run" ]]; then
  [[ -n "$MODEL" ]] || cm_die "--model required"
  [[ -n "$MODEL_PATH" ]] || cm_die "--model-path required (absolute path to pre-staged local model directory)"
fi

# ---------- Defaults from user's working scripts ----------

VLLM_IMG_DEFAULT="${VLLM_IMG_DEFAULT:-vllm-openai-nixl:v0.14.0}"
VLLM_IMG="${DOCKER_IMAGE:-${VLLM_IMG:-$VLLM_IMG_DEFAULT}}"
DOCKERIMG_ROOT="${DOCKERIMG_ROOT:-${DATA_ROOT}/dockerimgs}"
VLLM_IMG_TAR="${VLLM_IMG_TAR:-${DOCKERIMG_ROOT}/vllm-openai-nixl_v0.14.0.tar}"

# Where the platform user has model directories on every host. Models are
# expected to be pre-staged on each host (the user's scripts assume the
# same convention via shared filesystem).
HOST_MODELS_DIR="${PD_HOST_MODELS_DIR:-${HOST_MODELS_DIR:-${MLPERF_ROOT}/models}}"
ENCODINGS_DIR="${PD_ENCODINGS_DIR:-${ENCODINGS_DIR:-${MLPERF_ROOT}/encodings}}"

# vLLM source dir (on platform host) where toy_proxy_server.py lives.
VLLM_SRC="${PD_VLLM_SRC:-${VLLM_SRC:-${MLPERF_ROOT}/vllm}}"

# Bench / dataset path (the bench runs LOCALLY on the platform host).
DATASET_PATH="${PD_DATASET_PATH:-${DATASET_PATH:-${MLPERF_ROOT}/datasets/ShareGPT_V3_unfiltered_cleaned_split.json}}"

# KV connector (NIXL by default; also supports P2P and Mooncake).
# Accept either short forms (NIXL/P2P/MOONCAKE) or canonical vLLM class names
# (NixlConnector/P2PNcclConnector/MooncakeConnector). Normalize here so the
# rest of the script only branches on KV_CONNECTOR ∈ {NIXL,P2P,MOONCAKE}.
KV_CONNECTOR="${KV_CONNECTOR:-NIXL}"
case "${KV_CONNECTOR^^}" in
  NIXL|NIXLCONNECTOR)               KV_CONNECTOR="NIXL" ;;
  P2P|P2PNCCL|P2PNCCLCONNECTOR)     KV_CONNECTOR="P2P" ;;
  MOONCAKE|MOONCAKECONNECTOR)       KV_CONNECTOR="MOONCAKE" ;;
  *) cm_die "Unsupported KV_CONNECTOR: ${KV_CONNECTOR} (supported: NIXL, P2P, MOONCAKE)" ;;
esac
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"

# Per-side knobs.
PRE_GPU_UTIL="${PRE_GPU_UTIL:-0.95}"
PRE_MAX_NUM_SEQ="${PRE_MAX_NUM_SEQ:-64}"
PRE_MAX_NUM_BATCHED_TOKENS="${PRE_MAX_NUM_BATCHED_TOKENS:-32768}"
PRE_BLOCK_SIZE="${PRE_BLOCK_SIZE:-}"
PRE_ENABLE_PREFIX_CACHING="${PRE_ENABLE_PREFIX_CACHING:-false}"
DEC_GPU_UTIL="${DEC_GPU_UTIL:-0.95}"
DEC_MAX_NUM_SEQ="${DEC_MAX_NUM_SEQ:-64}"
DEC_MAX_NUM_BATCHED_TOKENS="${DEC_MAX_NUM_BATCHED_TOKENS:-32768}"
DEC_BLOCK_SIZE="${DEC_BLOCK_SIZE:-}"
DEC_ENABLE_PREFIX_CACHING="${DEC_ENABLE_PREFIX_CACHING:-false}"

# Mooncake-specific knobs (only used when KV_CONNECTOR=MOONCAKE).
MOONCAKE_MASTER="${MOONCAKE_MASTER:-}"            # host:port of the transfer-engine master, optional

# Bench knobs.
NUM_PROMPTS="${NUM_PROMPTS:-100}"
REQUEST_RATE="${REQUEST_RATE:-inf}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-50}"
SHAREGPT_OUTPUT_LEN="${SHAREGPT_OUTPUT_LEN:-1024}"
RANDOM_INPUT_LEN="${RANDOM_INPUT_LEN:-1024}"
RANDOM_OUTPUT_LEN="${RANDOM_OUTPUT_LEN:-256}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-16384}"

# Port plan (case_idx is always 1 for the platform — one PD topology per run).
CASE_IDX="${CASE_IDX:-1}"
PORT_BLOCK="${PORT_BLOCK:-100}"
PORT_BASE_PREFILL="${PORT_BASE_PREFILL:-12000}"
PORT_BASE_DECODE="${PORT_BASE_DECODE:-13000}"
PORT_BASE_PROXY="${PORT_BASE_PROXY:-14000}"
SIDE_BASE="${SIDE_BASE:-5600}"
SIDE_BLOCK="${SIDE_BLOCK:-100}"
INTERNAL_BASE_PREFILL="${INTERNAL_BASE_PREFILL:-24000}"
INTERNAL_BASE_DECODE="${INTERNAL_BASE_DECODE:-25000}"

READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-600}"
STOP_TIMEOUT_SEC="${STOP_TIMEOUT_SEC:-60}"

SAFE_RUN_ID="$(cm_safe_id "$RUN_ID")"

# Names per host: each prefill/decode host gets one container.
prefill_name_for() { echo "vllm-prefill-${SAFE_RUN_ID}-$1"; }
decode_name_for()  { echo "vllm-decode-${SAFE_RUN_ID}-$1"; }
PROXY_NAME="vllm-proxy-${SAFE_RUN_ID}"

# Resolve a host's reachable IP. Defaults to the host arg (works if it's
# already an IP or a resolvable hostname).
host_ip_for() {
  local h="$1"
  # Allow per-host override via env: HOST_IP_<safe_h>=...
  local var
  var="HOST_IP_$(cm_safe_id "$h")"
  echo "${!var:-$h}"
}

# Compute per-instance ports.
block_off=$(( CASE_IDX * PORT_BLOCK ))
proxy_port="${PROXY_PORT_CLI:-$(( PORT_BASE_PROXY + block_off ))}"
proxy_url="http://127.0.0.1:${proxy_port}"

declare -a PRE_PORTS PRE_SIDES PRE_INTERNALS PRE_URLS PRE_IPS PRE_NAMES
for i in "${!PHOSTS[@]}"; do
  PRE_PORTS[i]="${PRE_SPEC_PORT[$i]:-$(( PORT_BASE_PREFILL + block_off + i ))}"
  PRE_SIDES[i]=$(( SIDE_BASE + CASE_IDX * SIDE_BLOCK + i ))
  PRE_INTERNALS[i]=$(( INTERNAL_BASE_PREFILL + block_off + i ))
  PRE_IPS[i]="$(host_ip_for "${PHOSTS[i]}")"
  PRE_URLS[i]="http://${PRE_IPS[i]}:${PRE_PORTS[i]}"
  PRE_NAMES[i]="$(prefill_name_for "$i")"
done

declare -a DEC_PORTS DEC_SIDES DEC_INTERNALS DEC_URLS DEC_IPS DEC_NAMES
for i in "${!DHOSTS[@]}"; do
  DEC_PORTS[i]="${DEC_SPEC_PORT[$i]:-$(( PORT_BASE_DECODE + block_off + i ))}"
  DEC_SIDES[i]=$(( SIDE_BASE + CASE_IDX * SIDE_BLOCK + 40 + i ))
  DEC_INTERNALS[i]=$(( INTERNAL_BASE_DECODE + block_off + i ))
  DEC_IPS[i]="$(host_ip_for "${DHOSTS[i]}")"
  DEC_URLS[i]="http://${DEC_IPS[i]}:${DEC_PORTS[i]}"
  DEC_NAMES[i]="$(decode_name_for "$i")"
done

# ---------- STOP MODE ----------

if [[ "$MODE" == "stop" ]]; then
  cm_phase stop
  for i in "${!PHOSTS[@]}"; do
    cm_inf "stopping prefill on ${PHOSTS[i]}"
    cm_remote_bash "${PHOSTS[i]}" "${PRE_NAMES[i]}" <<'STOP' || true
docker stop -t 30 "$1" >/dev/null 2>&1 || true
docker rm -f "$1" >/dev/null 2>&1 || true
STOP
  done
  for i in "${!DHOSTS[@]}"; do
    cm_inf "stopping decode on ${DHOSTS[i]}"
    cm_remote_bash "${DHOSTS[i]}" "${DEC_NAMES[i]}" <<'STOP' || true
docker stop -t 30 "$1" >/dev/null 2>&1 || true
docker rm -f "$1" >/dev/null 2>&1 || true
STOP
  done
  cm_inf "stopping proxy locally"
  docker stop -t 15 "$PROXY_NAME" >/dev/null 2>&1 || true
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
  cm_phase done
  exit 0
fi

# ---------- RUN MODE ----------

[[ -n "$GPU_TYPE" ]] || cm_die "--gpu-type required"
[[ -n "$MODEL" ]] || cm_die "--model required"
case "$BENCH_DATA" in
  sharegpt|random) ;;
  *) cm_die "Unsupported --bench-data: $BENCH_DATA" ;;
esac

START_TIME="$(date --iso-8601=seconds)"
START_EPOCH="$(date +%s)"
STAMP="$(date +%Y%m%d_%H%M%S)"
SAFE_LEADER="$(cm_safe_id "$LEADER")"
LOG_ROOT="${LOG_ROOT:-${MLPERF_ROOT}/vllm_logs_pd_bench}"
LOG_DIR="${LOG_ROOT}/${STAMP}_${SAFE_LEADER}_pd_${BENCH_DATA}_${RUN_ID}"
RESULT_DIR="${LOG_DIR}/results"
mkdir -p "$LOG_DIR" "$RESULT_DIR"
exec > >(tee -a "${LOG_DIR}/run.log") 2>&1

# Resolve TP defaults per instance.  If a host runs N instances, split its GPUs
# approximately evenly across those instances, so 8 GPUs + 4 decode instances
# defaults to decode_tp=2.
if [[ -z "$PREFILL_TP" ]]; then
  _pg="$(remote_gpu_count_for_host "${PHOSTS[0]}")"
  _pn="$(count_role_instances_for_host prefill "${PHOSTS[0]}")"
  PREFILL_TP=$(( _pg / _pn )); [[ "$PREFILL_TP" -ge 1 ]] || PREFILL_TP=1
fi
if [[ -z "$DECODE_TP" ]]; then
  _dg="$(remote_gpu_count_for_host "${DHOSTS[0]}")"
  _dn="$(count_role_instances_for_host decode "${DHOSTS[0]}")"
  DECODE_TP=$(( _dg / _dn )); [[ "$DECODE_TP" -ge 1 ]] || DECODE_TP=1
fi

emit_summary() {
  local status="$1" code="$2" hint="$3"
  local end_time end_epoch duration
  end_time="$(date --iso-8601=seconds)"
  end_epoch="$(date +%s)"
  duration="$((end_epoch - START_EPOCH))"
  cm_emit_json_line PD_BENCH_RESULT_JSON \
    status "$status" \
    run_id "$RUN_ID" \
    host "$LEADER" \
    gpu_type "$GPU_TYPE" \
    suite "pd_bench" \
    engine "vllm" \
    benchmark "$BENCH_DATA" \
    model "$MODEL" \
    docker_image "$VLLM_IMG" \
    prefill_hosts "$PREFILL_HOSTS_CSV" \
    decode_hosts "$DECODE_HOSTS_CSV" \
    prefill_tp "$PREFILL_TP" \
    decode_tp "$DECODE_TP" \
    prefill_instances "$PREFILL_INSTANCES" \
    decode_instances "$DECODE_INSTANCES" \
    proxy_port "$proxy_port" \
    kv_connector "$KV_CONNECTOR" \
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

cleanup_remote() {
  cm_warn "cleanup: stopping containers everywhere"
  for i in "${!PHOSTS[@]}"; do
    cm_remote_bash "${PHOSTS[i]}" "${PRE_NAMES[i]}" <<'C' || true
docker stop -t 15 "$1" >/dev/null 2>&1 || true
docker rm -f "$1" >/dev/null 2>&1 || true
C
  done
  for i in "${!DHOSTS[@]}"; do
    cm_remote_bash "${DHOSTS[i]}" "${DEC_NAMES[i]}" <<'C' || true
docker stop -t 15 "$1" >/dev/null 2>&1 || true
docker rm -f "$1" >/dev/null 2>&1 || true
C
  done
  docker stop -t 15 "$PROXY_NAME" >/dev/null 2>&1 || true
  docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
}
trap 'cleanup_remote; emit_summary "stopped" 130 "stopped by signal"; exit 130' INT TERM HUP

cm_phase validate
cm_inf "run_id=${RUN_ID} engine=vllm gpu_type=${GPU_TYPE} kv_connector=${KV_CONNECTOR}"
cm_inf "prefill_hosts=${PREFILL_HOSTS_CSV} instances=${PREFILL_INSTANCES} expanded=${P_N} prefill_tp=${PREFILL_TP}"
cm_inf "decode_hosts=${DECODE_HOSTS_CSV} instances=${DECODE_INSTANCES} expanded=${D_N} decode_tp=${DECODE_TP}"
cm_inf "model=${MODEL} model_path=${MODEL_PATH} bench_data=${BENCH_DATA}"
cm_inf "image=${VLLM_IMG}"
cm_inf "proxy=${proxy_url}"
cm_inf "log_dir=${LOG_DIR}"

# Pre-flight: SSH and prefill/decode containers on each host.
for h in "${PHOSTS[@]}" "${DHOSTS[@]}"; do
  cm_is_local_host "$h" && continue
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" "echo ok" >/dev/null 2>&1 \
    || fail_run "SSH unreachable: $h" 22
done

for h in "${PHOSTS[@]}" "${DHOSTS[@]}"; do
  cm_inf "checking model_path on ${h}: ${MODEL_PATH}"
  cm_remote_bash "$h" "$MODEL_PATH" <<'MP' >/dev/null || fail_run "model_path not found on $h: $MODEL_PATH" 42
[[ -d "$1" ]]
MP
done

# toy_proxy_server.py must exist where we'll mount it.
PROXY_SCRIPT_REL="tests/v1/kv_connector/nixl_integration/toy_proxy_server.py"
if [[ ! -f "${VLLM_SRC}/${PROXY_SCRIPT_REL}" ]]; then
  fail_run "toy_proxy_server.py not found at ${VLLM_SRC}/${PROXY_SCRIPT_REL}. set VLLM_SRC env to your vLLM source checkout." 41
fi

# Dataset must exist (bench runs on platform host so we check locally).
if [[ "$BENCH_DATA" == "sharegpt" && ! -f "$DATASET_PATH" ]]; then
  fail_run "ShareGPT dataset not found at $DATASET_PATH" 41
fi

if [[ "$DRY_RUN" == "true" ]]; then
  cm_phase dry-run
  cm_inf "would launch ${P_N} prefill + ${D_N} decode containers + 1 local proxy"
  cm_inf "model_path=${MODEL_PATH}"
  cm_inf "prefill ports: ${PRE_PORTS[*]}"
  cm_inf "decode  ports: ${DEC_PORTS[*]}"
  emit_summary "success" 0 "dry-run completed"
  exit 0
fi

# ---------- PREPARE ----------

cm_phase prepare
for h in "${PHOSTS[@]}" "${DHOSTS[@]}"; do
  cm_inf "ensuring image on ${h}: ${VLLM_IMG}"
  cm_remote_bash "$h" "$VLLM_IMG" "$VLLM_IMG_TAR" <<'IMG' || fail_run "image missing on $h: $VLLM_IMG" 24
set -Eeuo pipefail
IMAGE="$1"; TAR="$2"
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
      [[ -n "$loaded_ref" ]] && docker tag "$loaded_ref" "$IMAGE" || true
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

if docker pull "$IMAGE"; then
  exit 0
fi

echo "[ERROR] image not present locally and fallback-load/pull failed: $IMAGE" >&2
exit 24
IMG
done

# Ensure local docker can run the proxy.
if ! docker image inspect "$VLLM_IMG" >/dev/null 2>&1; then
  echo "[WARN] local image missing: $VLLM_IMG"
  echo "[INFO] trying fallback tar before docker pull: ${VLLM_IMG_TAR:-<none>}"
  if [[ -f "$VLLM_IMG_TAR" ]]; then
    if out="$(docker load -i "$VLLM_IMG_TAR" 2>&1)"; then
      echo "$out"
      if ! docker image inspect "$VLLM_IMG" >/dev/null 2>&1; then
        loaded_ref="$(echo "$out" | awk -F': ' '/Loaded image:/ {print $2}' | tail -n 1)"
        [[ -n "$loaded_ref" ]] && docker tag "$loaded_ref" "$VLLM_IMG" || true
      fi
    else
      echo "$out"
      echo "[WARN] docker load failed; trying docker pull next: $VLLM_IMG_TAR"
    fi
  else
    echo "[WARN] image tar fallback missing; trying docker pull next: ${VLLM_IMG_TAR:-<empty>}"
  fi
  if ! docker image inspect "$VLLM_IMG" >/dev/null 2>&1; then
    docker pull "$VLLM_IMG" || true
  fi
  docker image inspect "$VLLM_IMG" >/dev/null 2>&1 || {
    fail_run "image missing locally after fallback-load/pull: $VLLM_IMG" 24
  }
fi

# ---------- KV configs ----------

build_kv_config() {
  # build_kv_config <role: producer|consumer> <kv_port> <proxy_port> <http_port>
  local role="$1" kv_port="$2" pport="$3" hport="$4"
  if [[ "$KV_CONNECTOR" == "P2P" ]]; then
    if [[ "$role" == "producer" ]]; then
      printf '{"kv_connector":"P2pNcclConnector","kv_role":"kv_producer","kv_load_failure_policy":"fail","kv_buffer_device":"cuda","kv_buffer_size":"1e1","kv_port":"%s","kv_connector_extra_config":{"proxy_ip":"0.0.0.0","proxy_port":"%s","http_port":"%s","send_type":"PUT_ASYNC","nccl_num_channels":"16"}}' \
        "$kv_port" "$pport" "$hport"
    else
      printf '{"kv_connector":"P2pNcclConnector","kv_role":"kv_consumer","kv_load_failure_policy":"fail","kv_buffer_device":"cuda","kv_buffer_size":"8e9","kv_port":"%s","kv_connector_extra_config":{"proxy_ip":"0.0.0.0","proxy_port":"%s","http_port":"%s","nccl_num_channels":"16"}}' \
        "$kv_port" "$pport" "$hport"
    fi
  elif [[ "$KV_CONNECTOR" == "MOONCAKE" ]]; then
    # Mooncake transfer engine. Requires a running mooncake_master service.
    # If MOONCAKE_MASTER is set we pass it through; otherwise the connector
    # picks up its own defaults from the local environment.
    local extra=""
    if [[ -n "$MOONCAKE_MASTER" ]]; then
      extra=',"mooncake_master":"'"$MOONCAKE_MASTER"'"'
    fi
    if [[ "$role" == "producer" ]]; then
      printf '{"kv_connector":"MooncakeConnector","kv_role":"kv_producer","kv_load_failure_policy":"fail","kv_buffer_device":"cuda","kv_connector_extra_config":{"local_buffer_size":"1e10"%s}}' \
        "$extra"
    else
      printf '{"kv_connector":"MooncakeConnector","kv_role":"kv_consumer","kv_load_failure_policy":"fail","kv_buffer_device":"cuda","kv_connector_extra_config":{"local_buffer_size":"1e10"%s}}' \
        "$extra"
    fi
  else
    # NIXL (default).
    if [[ "$role" == "producer" ]]; then
      echo '{"kv_connector":"NixlConnector","kv_role":"kv_producer","kv_load_failure_policy":"fail","kv_buffer_device":"cuda","kv_connector_extra_config":{"backends":["UCX"]}}'
    else
      echo '{"kv_connector":"NixlConnector","kv_role":"kv_consumer","kv_load_failure_policy":"fail","kv_buffer_device":"cuda","kv_connector_extra_config":{"backends":["UCX"]}}'
    fi
  fi
}

# ---------- PREFILL ----------

cm_phase prefill_serve
for i in "${!PHOSTS[@]}"; do
  h="${PHOSTS[i]}"
  ip="${PRE_IPS[i]}"
  name="${PRE_NAMES[i]}"
  port="${PRE_PORTS[i]}"
  side="${PRE_SIDES[i]}"
  internal="${PRE_INTERNALS[i]}"
  kv_port=$(( 21001 + i ))
  kv_config="$(build_kv_config producer "$kv_port" "$proxy_port" "$port")"

  tp="${PRE_SPEC_TP[$i]:-$PREFILL_TP}"; util="${PRE_SPEC_GPU_UTIL[$i]:-$PRE_GPU_UTIL}"; maxlen="${PRE_SPEC_MAXLEN[$i]:-$MAX_MODEL_LEN}"
  cm_inf "launching prefill ${i} on ${h} (port=${port} side=${side} tp=${tp})"
  visible_gpus="$(split_visible_for_instance "$h" prefill "$i")"
  cm_remote_bash "$h" \
      "$name" "$VLLM_IMG" "$MODEL" "$MODEL_PATH" "$port" "$ip" "$side" "$internal" \
      "$tp" "$util" "$maxlen" \
      "$KV_CACHE_DTYPE" "$PRE_MAX_NUM_BATCHED_TOKENS" "$PRE_MAX_NUM_SEQ" \
      "$kv_config" "$HOST_MODELS_DIR" "$ENCODINGS_DIR" \
      "$PRE_BLOCK_SIZE" "$PRE_ENABLE_PREFIX_CACHING" "$visible_gpus" "$EXTRA_DOCKER_ARGS ${PREFILL_EXTRA_DOCKER_ARGS}" "$PREFILL_EXTRA_ARGS" \
    <<'PRE' || fail_run "failed launching prefill on $h" 25
set -Eeuo pipefail
NAME="$1"; IMG="$2"; MODEL="$3"; MODEL_PATH="$4"; PORT="$5"; IP="$6"
SIDE="$7"; INTERNAL="$8"; TP="$9"; GPU_UTIL="${10}"
MAXLEN="${11}"; KV_DTYPE="${12}"
MAX_BT="${13}"; MAX_SEQ="${14}"; KV_CONFIG="${15}"
HOST_MODELS_DIR="${16}"; ENCODINGS_DIR="${17}"
BLOCK_SIZE="${18}"; ENABLE_PREFIX_CACHING="${19}"; VISIBLE_GPUS="${20}"; EXTRA_DOCKER_ARGS="${21:-}"; SERVE_EXTRA_ARGS="${22:-}"

docker rm -f "$NAME" >/dev/null 2>&1 || true
GPU_ENV_ARGS=()
if [[ -n "${VISIBLE_GPUS:-}" ]]; then
  echo "[INFO] selected_gpus=${VISIBLE_GPUS}"
  GPU_ENV_ARGS=(-e CUDA_VISIBLE_DEVICES="$VISIBLE_GPUS" -e NVIDIA_VISIBLE_DEVICES="$VISIBLE_GPUS")
fi

# Assemble optional flags so we don't pass empty values to vllm serve.
EXTRA_DOCKER_ARGS_ARR=()
if [[ -n "${EXTRA_DOCKER_ARGS:-}" ]]; then
  # Internal platform input. Supports simple docker args such as: -v /a:/b:ro -e KEY=value
  read -r -a EXTRA_DOCKER_ARGS_ARR <<< "$EXTRA_DOCKER_ARGS"
fi
EXTRA_FLAGS=()
if [[ -n "$BLOCK_SIZE" ]]; then
  EXTRA_FLAGS+=(--block-size "$BLOCK_SIZE")
fi
case "${ENABLE_PREFIX_CACHING,,}" in
  true|1|yes|on)
    EXTRA_FLAGS+=(--enable-prefix-caching)
    ;;
esac

set -x
docker run -d --name "$NAME" \
  --network host --ipc=host --gpus all \
  "${EXTRA_DOCKER_ARGS_ARR[@]}" \
  -v "${MODEL_PATH}:/workspace/model:ro" \
  -v "${HOST_MODELS_DIR}:${HOST_MODELS_DIR}:ro" \
  -v "${ENCODINGS_DIR}:/etc/encodings/:ro" \
  -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings \
  -e VLLM_NIXL_SIDE_CHANNEL_HOST="$IP" \
  -e VLLM_NIXL_SIDE_CHANNEL_PORT="$SIDE" \
  -e UCX_TLS=all \
  -e UCX_NET_DEVICES=all \
  -e HF_HUB_OFFLINE=1 \
  "${GPU_ENV_ARGS[@]}" \
  -e VLLM_HOST_IP="$IP" \
  -e VLLM_PORT="$INTERNAL" \
  "$IMG" \
  --model "/workspace/model" \
  --served-model-name "$MODEL" \
  --host 0.0.0.0 --port "$PORT" \
  --tensor-parallel-size "$TP" \
  --gpu-memory-utilization "$GPU_UTIL" \
  --max-model-len "$MAXLEN" \
  --kv-cache-dtype "$KV_DTYPE" \
  --max-num-batched-tokens "$MAX_BT" \
  --max-num-seqs "$MAX_SEQ" \
  "${EXTRA_FLAGS[@]}" \
  $SERVE_EXTRA_ARGS \
  --kv-transfer-config "$KV_CONFIG"
set +x
echo "[INFO] prefill container $NAME up on port $PORT"
PRE
done

# ---------- DECODE ----------

cm_phase decode_serve
for i in "${!DHOSTS[@]}"; do
  h="${DHOSTS[i]}"
  ip="${DEC_IPS[i]}"
  name="${DEC_NAMES[i]}"
  port="${DEC_PORTS[i]}"
  side="${DEC_SIDES[i]}"
  internal="${DEC_INTERNALS[i]}"
  kv_port=$(( 22001 + i ))
  kv_config="$(build_kv_config consumer "$kv_port" "$proxy_port" "$port")"

  tp="${DEC_SPEC_TP[$i]:-$DECODE_TP}"; util="${DEC_SPEC_GPU_UTIL[$i]:-$DEC_GPU_UTIL}"; maxlen="${DEC_SPEC_MAXLEN[$i]:-$MAX_MODEL_LEN}"
  cm_inf "launching decode ${i} on ${h} (port=${port} side=${side} tp=${tp})"
  visible_gpus="$(split_visible_for_instance "$h" decode "$i")"
  cm_remote_bash "$h" \
      "$name" "$VLLM_IMG" "$MODEL" "$MODEL_PATH" "$port" "$ip" "$side" "$internal" \
      "$tp" "$util" "$maxlen" \
      "$KV_CACHE_DTYPE" "$DEC_MAX_NUM_BATCHED_TOKENS" "$DEC_MAX_NUM_SEQ" \
      "$kv_config" "$HOST_MODELS_DIR" "$ENCODINGS_DIR" \
      "$DEC_BLOCK_SIZE" "$DEC_ENABLE_PREFIX_CACHING" "$visible_gpus" "$EXTRA_DOCKER_ARGS ${DECODE_EXTRA_DOCKER_ARGS}" "$DECODE_EXTRA_ARGS" \
    <<'DEC' || fail_run "failed launching decode on $h" 26
set -Eeuo pipefail
NAME="$1"; IMG="$2"; MODEL="$3"; MODEL_PATH="$4"; PORT="$5"; IP="$6"
SIDE="$7"; INTERNAL="$8"; TP="$9"; GPU_UTIL="${10}"
MAXLEN="${11}"; KV_DTYPE="${12}"
MAX_BT="${13}"; MAX_SEQ="${14}"; KV_CONFIG="${15}"
HOST_MODELS_DIR="${16}"; ENCODINGS_DIR="${17}"
BLOCK_SIZE="${18}"; ENABLE_PREFIX_CACHING="${19}"; VISIBLE_GPUS="${20}"; EXTRA_DOCKER_ARGS="${21:-}"; SERVE_EXTRA_ARGS="${22:-}"

docker rm -f "$NAME" >/dev/null 2>&1 || true
GPU_ENV_ARGS=()
if [[ -n "${VISIBLE_GPUS:-}" ]]; then
  echo "[INFO] selected_gpus=${VISIBLE_GPUS}"
  GPU_ENV_ARGS=(-e CUDA_VISIBLE_DEVICES="$VISIBLE_GPUS" -e NVIDIA_VISIBLE_DEVICES="$VISIBLE_GPUS")
fi
EXTRA_DOCKER_ARGS_ARR=()
if [[ -n "${EXTRA_DOCKER_ARGS:-}" ]]; then
  read -r -a EXTRA_DOCKER_ARGS_ARR <<< "$EXTRA_DOCKER_ARGS"
fi

EXTRA_FLAGS=()
if [[ -n "$BLOCK_SIZE" ]]; then
  EXTRA_FLAGS+=(--block-size "$BLOCK_SIZE")
fi
case "${ENABLE_PREFIX_CACHING,,}" in
  true|1|yes|on)
    EXTRA_FLAGS+=(--enable-prefix-caching)
    ;;
esac

set -x
docker run -d --name "$NAME" \
  --network host --ipc=host --gpus all \
  "${EXTRA_DOCKER_ARGS_ARR[@]}" \
  -v "${MODEL_PATH}:/workspace/model:ro" \
  -v "${HOST_MODELS_DIR}:${HOST_MODELS_DIR}:ro" \
  -v "${ENCODINGS_DIR}:/etc/encodings/:ro" \
  -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings \
  -e VLLM_NIXL_SIDE_CHANNEL_HOST="$IP" \
  -e VLLM_NIXL_SIDE_CHANNEL_PORT="$SIDE" \
  -e UCX_TLS=all \
  -e UCX_NET_DEVICES=all \
  -e HF_HUB_OFFLINE=1 \
  "${GPU_ENV_ARGS[@]}" \
  -e VLLM_HOST_IP="$IP" \
  -e VLLM_PORT="$INTERNAL" \
  "$IMG" \
  --model "/workspace/model" \
  --served-model-name "$MODEL" \
  --host 0.0.0.0 --port "$PORT" \
  --tensor-parallel-size "$TP" \
  --gpu-memory-utilization "$GPU_UTIL" \
  --max-model-len "$MAXLEN" \
  --kv-cache-dtype "$KV_DTYPE" \
  --max-num-batched-tokens "$MAX_BT" \
  --max-num-seqs "$MAX_SEQ" \
  "${EXTRA_FLAGS[@]}" \
  $SERVE_EXTRA_ARGS \
  --kv-transfer-config "$KV_CONFIG"
set +x
echo "[INFO] decode container $NAME up on port $PORT"
DEC
done

# ---------- WAIT for /v1/models on each prefill/decode ----------

cm_phase wait
wait_models_ready() {
  local url="$1" name="$2"
  local deadline=$(( $(date +%s) + READY_TIMEOUT_SEC ))
  cm_inf "waiting for ${name} at ${url}/v1/models"
  while true; do
    local code
    code="$(curl -sS -o /dev/null -w "%{http_code}" "${url}/v1/models" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      cm_inf "[ready] ${name}"
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      cm_err "[timeout] ${name} did not become ready in ${READY_TIMEOUT_SEC}s"
      return 1
    fi
    sleep 3
  done
}

for i in "${!PRE_URLS[@]}"; do
  if ! wait_models_ready "${PRE_URLS[i]}" "${PRE_NAMES[i]}"; then
    cleanup_remote
    fail_run "prefill ${PRE_NAMES[i]} not ready" 28
  fi
done
for i in "${!DEC_URLS[@]}"; do
  if ! wait_models_ready "${DEC_URLS[i]}" "${DEC_NAMES[i]}"; then
    cleanup_remote
    fail_run "decode ${DEC_NAMES[i]} not ready" 28
  fi
done

# ---------- PROXY (local) ----------

cm_phase proxy
cm_inf "starting toy_proxy_server.py locally as ${PROXY_NAME} on port ${proxy_port}"

# Build host/port arrays for the proxy CLI.
PROXY_PRE_HOSTS=()
PROXY_PRE_PORTS=()
for i in "${!PRE_PORTS[@]}"; do
  PROXY_PRE_HOSTS+=("${PRE_IPS[i]}")
  PROXY_PRE_PORTS+=("${PRE_PORTS[i]}")
done
PROXY_DEC_HOSTS=()
PROXY_DEC_PORTS=()
for i in "${!DEC_PORTS[@]}"; do
  PROXY_DEC_HOSTS+=("${DEC_IPS[i]}")
  PROXY_DEC_PORTS+=("${DEC_PORTS[i]}")
done

docker stop -t 15 "$PROXY_NAME" >/dev/null 2>&1 || true
docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true

set -x
docker run -d --name "$PROXY_NAME" \
  --network host --ipc=host \
  -e CUDA_VISIBLE_DEVICES="" \
  -v "${VLLM_SRC}:/vllm-src:ro" \
  --entrypoint /usr/bin/python3 \
  "$VLLM_IMG" \
  "/vllm-src/${PROXY_SCRIPT_REL}" \
  --port "$proxy_port" \
  --prefiller-hosts "${PROXY_PRE_HOSTS[@]}" \
  --prefiller-ports "${PROXY_PRE_PORTS[@]}" \
  --decoder-hosts   "${PROXY_DEC_HOSTS[@]}" \
  --decoder-ports   "${PROXY_DEC_PORTS[@]}"
set +x

# Wait until the proxy port is open locally.
DEADLINE=$(( $(date +%s) + READY_TIMEOUT_SEC ))
while true; do
  if (echo > /dev/tcp/127.0.0.1/${proxy_port}) >/dev/null 2>&1; then
    cm_inf "proxy listening on 127.0.0.1:${proxy_port}"
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$PROXY_NAME"; then
    docker logs --tail 200 "$PROXY_NAME" || true
    cleanup_remote
    fail_run "proxy container exited before ready" 30
  fi
  if (( $(date +%s) > DEADLINE )); then
    docker logs --tail 200 "$PROXY_NAME" || true
    cleanup_remote
    fail_run "proxy not ready in ${READY_TIMEOUT_SEC}s" 30
  fi
  sleep 2
done

# ---------- BENCH (local, against proxy) ----------

cm_phase bench
cm_inf "running bench against proxy ${proxy_url}"

case "$BENCH_DATA" in
  sharegpt)
    BENCH_DATASET_ARGS=(
      --dataset-name sharegpt
      --dataset-path "$DATASET_PATH"
      --sharegpt-output-len "$SHAREGPT_OUTPUT_LEN"
    )
    ;;
  random)
    BENCH_DATASET_ARGS=(
      --dataset-name random
      --random-input-len "$RANDOM_INPUT_LEN"
      --random-output-len "$RANDOM_OUTPUT_LEN"
    )
    ;;
esac

set +e
set -x
docker run --rm \
  --network host \
  -v "$(dirname "$DATASET_PATH"):$(dirname "$DATASET_PATH"):ro" \
  -v "${HOST_MODELS_DIR}:${HOST_MODELS_DIR}:ro" \
  -v "${RESULT_DIR}:${RESULT_DIR}" \
  -e CUDA_VISIBLE_DEVICES="" \
  -e HF_HUB_OFFLINE=1 \
  --entrypoint vllm \
  "$VLLM_IMG" \
  bench serve \
    --backend openai \
    --base-url "$proxy_url" \
    --endpoint /v1/completions \
    --model "$MODEL" \
    --served-model-name "$MODEL" \
    "${BENCH_DATASET_ARGS[@]}" \
    --request-rate "$REQUEST_RATE" \
    --max-concurrency "$MAX_CONCURRENCY" \
    --num-prompts "$NUM_PROMPTS" \
    --save-result \
    --save-detailed \
    --result-dir "$RESULT_DIR" \
    --result-filename "pd_bench_serving.json" \
    $EXTRA_ARGS \
  2>&1 | tee "${RESULT_DIR}/pd_bench_${BENCH_DATA}.log"
BENCH_EXIT="${PIPESTATUS[0]}"
set +x
set -e

cm_phase collect
cm_inf "bench_exit=${BENCH_EXIT}"

cleanup_remote

cm_phase done
if [[ "$BENCH_EXIT" -eq 0 ]]; then
  emit_summary "success" 0 "PD vllm bench completed (proxy=${proxy_url})"
  exit 0
else
  emit_summary "failed" "$BENCH_EXIT" "PD vllm bench failed; inspect ${LOG_DIR}/run.log"
  exit "$BENCH_EXIT"
fi
