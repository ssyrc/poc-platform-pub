#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOU'
Usage:
  ./mlperf_run.sh \
    --run-id run001 \
    --suite training \
    --version v4.1 \
    --gpu-type H100 \
    --hosts gpu-node03,gpu-node04

Examples:
  # Training v4.1 llama2_70b_lora on multiple hosts
  ./mlperf_run.sh \
    --run-id train_v41_001 \
    --suite training \
    --version v4.1 \
    --gpu-type H100 \
    --hosts gpu-node03,gpu-node04

  # Training v5.1 llama2_70b_lora
  ./mlperf_run.sh \
    --run-id train_v51_001 \
    --suite training \
    --version v5.1 \
    --benchmark llama2_70b_lora \
    --gpu-type H100 \
    --hosts gpu-node03,gpu-node04

  # Training v5.1 llama31_8b
  ./mlperf_run.sh \
    --run-id train_v51_llama31_001 \
    --suite training \
    --version v5.1 \
    --benchmark llama31_8b \
    --gpu-type H100 \
    --hosts gpu-node03,gpu-node04

  # Inference v5.1 llama2_70b
  ./mlperf_run.sh \
    --run-id infer_v51_001 \
    --suite inference \
    --version v5.1 \
    --gpu-type H100 \
    --hosts gpu-node03,gpu-node04

  # Inference v6.0 llama2_70b
  ./mlperf_run.sh \
    --run-id infer_v60_001 \
    --suite inference \
    --version v6.0 \
    --gpu-type H100 \
    --hosts gpu-node03,gpu-node04

  # Stop multiple hosts
  ./mlperf_run.sh \
    --stop \
    --run-id train_v41_001 \
    --suite training \
    --version v4.1 \
    --hosts gpu-node03,gpu-node04

Required:
  --run-id
  --suite training|inference
  --version v4.1|v5.1|v6.0
  --gpu-type <GPU_TYPE>     required for run, not required for stop
  --host <hostname>         repeatable
  or
  --hosts host1,host2

Optional:
  --benchmark <benchmark>
  --docker-image <image>
  --mlperf-root /opt/poc-platform
  --data-root /opt/poc-platform/data
  --log-root <path>
  --config <path>
  --dry-run
  --stop

Default data root:
  /opt/poc-platform/data

Multi-node Training RDMA:
  Set MLPERF_NODE_MODE=multi and GPUS_PER_NODE=<N>.
  The script auto-detects NCCL_IB_HCA and NCCL_SOCKET_IFNAME per host.
  MASTER_ADDR is auto-selected from rank-0 compute netdev when possible.
  Set NCCL_IB_HCA/NCCL_SOCKET_IFNAME/MASTER_ADDR only to override auto-detection.
EOU
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MODE="run"
RUN_ID=""
SUITE=""
VERSION=""
GPU_TYPE=""
BENCHMARK=""
HOSTS=()
DOCKER_IMAGE=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
LOG_ROOT=""
CONFIG_PATH=""
DRY_RUN="false"

add_hosts() {
  local raw="$1"
  local h

  IFS=',' read -ra parts <<< "$raw"
  for h in "${parts[@]}"; do
    h="$(echo "$h" | xargs)"
    [[ -n "$h" ]] || continue
    [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid hostname: $h"
    HOSTS+=("$h")
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop)
      MODE="stop"
      shift
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --suite)
      SUITE="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --gpu-type)
      GPU_TYPE="${2:-}"
      shift 2
      ;;
    --benchmark)
      BENCHMARK="${2:-}"
      shift 2
      ;;
    --host)
      add_hosts "${2:-}"
      shift 2
      ;;
    --hosts)
      add_hosts "${2:-}"
      shift 2
      ;;
    --docker-image)
      DOCKER_IMAGE="${2:-}"
      shift 2
      ;;
    --mlperf-root)
      MLPERF_ROOT="${2:-}"
      shift 2
      ;;
    --data-root)
      DATA_ROOT="${2:-}"
      shift 2
      ;;
    --log-root)
      LOG_ROOT="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$RUN_ID" ]] || die "--run-id is required"
[[ -n "$SUITE" ]] || die "--suite is required"
[[ -n "$VERSION" ]] || die "--version is required"
[[ "${#HOSTS[@]}" -gt 0 ]] || die "--host or --hosts is required"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid run-id: $RUN_ID"
[[ "$MLPERF_ROOT" == /* ]] || die "--mlperf-root must be absolute"
[[ "$DATA_ROOT" == /* ]] || die "--data-root must be absolute"

if [[ "$MODE" == "run" && -z "$GPU_TYPE" ]]; then
  die "--gpu-type is required for run mode"
fi

case "$SUITE" in
  training|inference) ;;
  *) die "Invalid --suite: $SUITE" ;;
esac

case "$VERSION" in
  v4.1|4.1) VERSION="v4.1" ;;
  v5.1|5.1) VERSION="v5.1" ;;
  v6.0|6.0) VERSION="v6.0" ;;
  *) die "Invalid --version: $VERSION" ;;
esac

TARGET_SCRIPT=""

case "${SUITE}:${VERSION}" in
  training:v4.1)
    TARGET_SCRIPT="${SCRIPT_DIR}/mlperf_train_v41.sh"
    if [[ -z "$BENCHMARK" ]]; then
      BENCHMARK="llama2_70b_lora"
    fi
    ;;
  training:v5.1)
    TARGET_SCRIPT="${SCRIPT_DIR}/mlperf_train_v51.sh"
    if [[ -z "$BENCHMARK" ]]; then
      BENCHMARK="llama2_70b_lora"
    fi
    ;;
  inference:v5.1)
    TARGET_SCRIPT="${SCRIPT_DIR}/mlperf_infer_v51.sh"
    if [[ -z "$BENCHMARK" ]]; then
      BENCHMARK="llama2_70b"
    fi
    ;;
  inference:v6.0)
    TARGET_SCRIPT="${SCRIPT_DIR}/mlperf_infer_v60.sh"
    if [[ -z "$BENCHMARK" ]]; then
      BENCHMARK="llama2_70b"
    fi
    ;;
  *)
    die "Unsupported suite/version combination: ${SUITE}/${VERSION}"
    ;;
esac

[[ -x "$TARGET_SCRIPT" ]] || die "Target script is not executable: $TARGET_SCRIPT"

BASE_ARGS=(
  --run-id "$RUN_ID"
  --gpu-type "$GPU_TYPE"
  --benchmark "$BENCHMARK"
  --mlperf-root "$MLPERF_ROOT"
  --data-root "$DATA_ROOT"
)

if [[ -n "$DOCKER_IMAGE" ]]; then
  BASE_ARGS+=(--docker-image "$DOCKER_IMAGE")
fi

if [[ -n "$LOG_ROOT" ]]; then
  BASE_ARGS+=(--log-root "$LOG_ROOT")
fi

if [[ -n "$CONFIG_PATH" ]]; then
  BASE_ARGS+=(--config "$CONFIG_PATH")
fi

if [[ "$DRY_RUN" == "true" ]]; then
  BASE_ARGS+=(--dry-run)
fi

if [[ "$MODE" == "stop" ]]; then
  BASE_ARGS=(--stop --run-id "$RUN_ID")

  if [[ -n "$GPU_TYPE" ]]; then
    BASE_ARGS+=(--gpu-type "$GPU_TYPE")
  fi

  BASE_ARGS+=(--benchmark "$BENCHMARK")
  BASE_ARGS+=(--mlperf-root "$MLPERF_ROOT")
  BASE_ARGS+=(--data-root "$DATA_ROOT")

  if [[ -n "$LOG_ROOT" ]]; then
    BASE_ARGS+=(--log-root "$LOG_ROOT")
  fi
fi

STATUS_DIR="/tmp/mlperf_run_${RUN_ID}_$$_$(date +%s)"
mkdir -p "$STATUS_DIR"

echo "[PHASE] dispatch"
echo "[INFO] suite=${SUITE}"
echo "[INFO] version=${VERSION}"
echo "[INFO] benchmark=${BENCHMARK}"
echo "[INFO] target_script=${TARGET_SCRIPT}"
echo "[INFO] hosts=${HOSTS[*]}"
echo "[INFO] data_root=${DATA_ROOT}"
echo "[INFO] status_dir=${STATUS_DIR}"

MLPERF_FORWARD_ENV_NAMES=(
  MLPERF_MAX_STEPS MLPERF_LIMIT_VAL_BATCHES MLPERF_VAL_CHECK_INTERVAL MLPERF_EXTRA_OVERRIDES
  GPUS_PER_NODE NUM_GPUS MLPERF_NUM_GPUS TP PP CP MBS MINIBS GBS MAX_SEQLEN SEQ_LENGTH MAX_STEPS LIMIT_VAL_BATCHES VAL_CHECK_INTERVAL
  TENSOR_MODEL_PARALLEL PIPELINE_MODEL_PARALLEL CONTEXT_PARALLEL MICRO_BATCH_SIZE GLOBAL_BATCH_SIZE
  FP8 FP8_HYBRID GPU_ARCH NCCL_DEBUG NCCL_IB_HCA NCCL_SOCKET_IFNAME NCCL_IB_DISABLE TRAINER_PRECISION MLPERF_TRAINER_PRECISION MLPERF_RUN_CMD
  MLPERF_INFER_SCENARIO MLPERF_INFER_CONFIG_VER MLPERF_INFER_TEST_MODE MLPERF_INFER_CORE_TYPE
  MLPERF_INFER_TP_SIZE MLPERF_INFER_GPU_BATCH_SIZE MLPERF_INFER_OFFLINE_QPS
  MLPERF_INFER_MIN_DURATION_MS MLPERF_INFER_MIN_QUERY_COUNT MLPERF_INFER_ACCURACY_TARGET
  MLPERF_INFER_PREBUILD MLPERF_INFER_PREPROCESS MLPERF_INFER_BUILD MLPERF_INFER_BUILD_ENV
  MLPERF_INFER_GENERATE_ENGINES MLPERF_INFER_RUN_SERVER MLPERF_INFER_RUN_HARNESS
  MLPERF_INFER_SERVER_WAIT_SEC MLPERF_RUN_ARGS_EXTRA MLPERF_CUDA_VISIBLE_DEVICES MLPERF_CUDA_VISIBLE_DEVICES_BY_HOST MLPERF_NODE_MODE
  MLPERF_BASE_MODEL_DIR MLPERF_PREPROCESSED_DIR MLPERF_ENGINE_DIR MLPERF_QUANT_MODEL_DIR
)
_seen_env=0
for _env_name in "${MLPERF_FORWARD_ENV_NAMES[@]}"; do
  if [[ -n "${!_env_name:-}" ]]; then
    if [[ "$_seen_env" == "0" ]]; then
      echo "[INFO] mlperf_run received advanced env:"
      _seen_env=1
    fi
    printf '[INFO]   %s=%q\n' "$_env_name" "${!_env_name}"
  fi
done
unset _env_name _seen_env

if [[ "$MODE" == "run" && "$DRY_RUN" != "true" ]]; then
  cm_ensure_docker_hosts "${HOSTS[@]}"
fi

# Bare-metal MLPerf Training multi-node mode. The wrapper starts one rank per
# host and auto-detects the RDMA HCA / IP netdev nearest to the selected GPUs.
# Explicit NCCL_IB_HCA, NCCL_SOCKET_IFNAME, or MASTER_ADDR values override auto
# detection. Auto-detection is per host, so NIC numbering does not need to match
# across different servers.
if [[ "$MODE" == "run" && "$SUITE" == "training" && "${MLPERF_NODE_MODE:-single}" == "multi" ]]; then
  [[ "${#HOSTS[@]}" -ge 2 ]] || die "MLPERF_NODE_MODE=multi requires at least two hosts"
  MASTER_PORT_VALUE="${MASTER_PORT:-29500}"
  NNODES="${#HOSTS[@]}"
  GPUS_PER_NODE="${GPUS_PER_NODE:-${NUM_GPUS:-${MLPERF_NUM_GPUS:-}}}"
  [[ -n "$GPUS_PER_NODE" ]] || die "multi-node training requires GPUS_PER_NODE/NUM_GPUS/MLPERF_NUM_GPUS as GPUs per node"
  [[ "$GPUS_PER_NODE" =~ ^[0-9]+$ && "$GPUS_PER_NODE" -ge 1 ]] || die "GPUS_PER_NODE must be a positive integer: $GPUS_PER_NODE"
  WORLD_SIZE_GPUS="$(( GPUS_PER_NODE * NNODES ))"

  visible_for_host() {
    local target="$1" spec key val
    IFS=';' read -ra specs <<< "${MLPERF_CUDA_VISIBLE_DEVICES_BY_HOST:-}"
    for spec in "${specs[@]}"; do
      [[ "$spec" == *=* ]] || continue
      key="${spec%%=*}"; val="${spec#*=}"
      if [[ "$key" == "$target" ]]; then printf '%s' "$val"; return 0; fi
    done
    printf '%s' "${MLPERF_CUDA_VISIBLE_DEVICES:-}"
  }

  default_gpu_csv() {
    local count="$1" out="" i
    for ((i=0; i<count; i++)); do
      [[ -z "$out" ]] && out="$i" || out="${out},${i}"
    done
    printf '%s' "$out"
  }

  # Output: HCA_CSV|IFNAME_CSV|FIRST_IP
  # - HCA_CSV: closest NIC(s) selected from nvidia-smi topo -m using
  #   PIX -> PXB -> PHB -> NODE -> SYS priority, ordered by selected GPU list.
  # - IFNAME_CSV: ibdev2netdev-mapped interfaces that are UP and have a global IP.
  # - FIRST_IP: first address on IFNAME_CSV; suitable as rank-0 MASTER_ADDR.
  detect_rdma_binding() {
    local target="$1" gpu_csv="$2"
    cm_remote_bash "$target" "$gpu_csv" <<'RDMA_PROBE'
set -Eeuo pipefail
gpus_csv="$1"
command -v nvidia-smi >/dev/null 2>&1 || { printf '||\n'; exit 0; }
topo="$(LC_ALL=C nvidia-smi topo -m 2>/dev/null || true)"
[[ -n "$topo" ]] || { printf '||\n'; exit 0; }

hcas="$(awk -v gpus="$gpus_csv" '
function rank(v) {
  return v=="PIX" ? 0 : v=="PXB" ? 1 : v=="PHB" ? 2 : v=="NODE" ? 3 : v=="SYS" ? 4 : 99
}
BEGIN {
  n=split(gpus, wanted, ",")
  for (i=1; i<=n; i++) {
    g=wanted[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", g)
    order[i]=g; need[g]=1
  }
}
/^[[:space:]]*GPU[0-9]+[[:space:]]/ && !header_done {
  # The real GPU row also matches this regex, so header is detected separately below.
}
{
  if (!header_done) {
    has_gpu=0; has_nic=0
    for (i=1; i<=NF; i++) {
      if ($i ~ /^GPU[0-9]+$/) has_gpu=1
      if ($i ~ /^NIC[0-9]+$/) has_nic=1
    }
    if (has_gpu && has_nic && (($1=="GPU0" && $2 ~ /^GPU[0-9]+$/) || $0 ~ /^[[:space:]]+GPU[0-9]+/)) {
      for (i=1; i<=NF; i++) if ($i ~ /^NIC[0-9]+$/) { nic_name[++nnic]=$i; nic_col[nnic]=i }
      header_done=1
      next
    }
  }
  if ($1 ~ /^GPU[0-9]+$/) {
    gpu=substr($1,4)
    if (!(gpu in need)) next
    best=""; best_rank=999; best_num=999999
    for (j=1; j<=nnic; j++) {
      # Header columns include the row label implicitly; GPU rows begin with GPUk,
      # so the matrix cell corresponding to header field i is row field i+1.
      value=$(nic_col[j]+1)
      r=rank(value)
      num=nic_name[j]; sub(/^NIC/, "", num); num+=0
      if (r < best_rank || (r == best_rank && num < best_num)) {
        best=nic_name[j]; best_rank=r; best_num=num
      }
    }
    if (best != "") best_for_gpu[gpu]=best
  }
  if ($1 ~ /^NIC[0-9]+:$/) {
    key=$1; sub(/:$/, "", key); legend[key]=$2
  }
}
END {
  first=1
  for (i=1; i<=n; i++) {
    g=order[i]; nic=best_for_gpu[g]
    if (nic=="") continue
    dev=(nic in legend ? legend[nic] : nic)
    if (!(dev in emitted)) {
      printf "%s%s", (first?"":","), dev
      emitted[dev]=1; first=0
    }
  }
}' <<< "$topo")"

[[ -n "$hcas" ]] || { printf '||\n'; exit 0; }

ifnames=""
first_ip=""
if command -v ibdev2netdev >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
  map_txt="$(ibdev2netdev 2>/dev/null || true)"
  IFS=',' read -ra hca_arr <<< "$hcas"
  for hca in "${hca_arr[@]}"; do
    # Prefer an Up port when a multi-port HCA exposes more than one netdev.
    netdev="$(awk -v h="$hca" '$1==h && /==>/ && $0 ~ /\(Up\)/ {for(i=1;i<=NF;i++) if($i=="==>"){print $(i+1); exit}}' <<< "$map_txt")"
    [[ -n "$netdev" ]] || netdev="$(awk -v h="$hca" '$1==h && /==>/ {for(i=1;i<=NF;i++) if($i=="==>"){print $(i+1); exit}}' <<< "$map_txt")"
    [[ -n "$netdev" ]] || continue
    ip link show dev "$netdev" 2>/dev/null | grep -q 'state UP' || continue
    addr="$(ip -o -4 addr show dev "$netdev" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')"
    if [[ -z "$addr" ]]; then
      addr="$(ip -o -6 addr show dev "$netdev" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')"
    fi
    [[ -n "$addr" ]] || continue
    case ",$ifnames," in *,"$netdev",*) ;; *) [[ -z "$ifnames" ]] && ifnames="$netdev" || ifnames="${ifnames},${netdev}" ;; esac
    [[ -n "$first_ip" ]] || first_ip="$addr"
  done
fi
printf '%s|%s|%s\n' "$hcas" "$ifnames" "$first_ip"
RDMA_PROBE
  }

  declare -a HOST_VIS HOST_HCA HOST_IFNAME HOST_IP
  echo "[PHASE] detect_rdma_topology"
  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    vis="$(visible_for_host "$host")"
    [[ -n "$vis" ]] || vis="$(default_gpu_csv "$GPUS_PER_NODE")"
    HOST_VIS[$i]="$vis"

    detected="$(detect_rdma_binding "$host" "$vis" 2>/dev/null || true)"
    IFS='|' read -r auto_hca auto_ifname auto_ip <<< "$detected"
    HOST_HCA[$i]="${NCCL_IB_HCA:-$auto_hca}"
    HOST_IFNAME[$i]="${NCCL_SOCKET_IFNAME:-$auto_ifname}"
    HOST_IP[$i]="$auto_ip"

    echo "[INFO] host=${host} selected_gpus=${vis}"
    if [[ -n "${HOST_HCA[$i]}" ]]; then
      echo "[INFO] host=${host} NCCL_IB_HCA=${HOST_HCA[$i]}"
    else
      echo "[WARN] host=${host} no GPU-adjacent RDMA HCA detected; NCCL_IB_HCA will not be forced"
    fi
    if [[ -n "${HOST_IFNAME[$i]}" ]]; then
      echo "[INFO] host=${host} NCCL_SOCKET_IFNAME=${HOST_IFNAME[$i]}"
    else
      echo "[WARN] host=${host} no mapped UP netdev with a global IP; NCCL_SOCKET_IFNAME will not be forced"
    fi
  done

  if [[ -n "${MASTER_ADDR:-}" ]]; then
    MASTER_HOST="$MASTER_ADDR"
    echo "[INFO] MASTER_ADDR explicitly set: ${MASTER_HOST}"
  elif [[ -n "${HOST_IP[0]:-}" ]]; then
    MASTER_HOST="${HOST_IP[0]}"
    echo "[INFO] MASTER_ADDR auto-selected from ${HOSTS[0]} compute netdev: ${MASTER_HOST}"
  else
    MASTER_HOST="${HOSTS[0]}"
    echo "[WARN] compute-net IP unavailable on rank 0; MASTER_ADDR falls back to host identifier: ${MASTER_HOST}"
  fi

  echo "[PHASE] dispatch_multinode"
  echo "[INFO] node_mode=multi nnodes=${NNODES} gpus_per_node=${GPUS_PER_NODE} world_size_gpus=${WORLD_SIZE_GPUS} master=${MASTER_HOST}:${MASTER_PORT_VALUE}"

  rank=0
  for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    (
      set +e
      vis="${HOST_VIS[$i]}"
      export MLPERF_NODE_MODE="multi"
      export MLPERF_TRAIN_NNODES="$NNODES"
      export MLPERF_NODE_RANK="$rank"
      export MLPERF_WORLD_SIZE="$WORLD_SIZE_GPUS"
      export WORLD_SIZE_GPUS="$WORLD_SIZE_GPUS"
      export NUM_GPUS="$GPUS_PER_NODE"
      export MLPERF_NUM_GPUS="$GPUS_PER_NODE"
      export MASTER_ADDR="$MASTER_HOST"
      export MASTER_PORT="$MASTER_PORT_VALUE"
      export MLPERF_CUDA_VISIBLE_DEVICES="$vis"
      if [[ -n "${HOST_HCA[$i]}" ]]; then
        export NCCL_IB_HCA="${HOST_HCA[$i]}"
        export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
      fi
      if [[ -n "${HOST_IFNAME[$i]}" ]]; then
        export NCCL_SOCKET_IFNAME="${HOST_IFNAME[$i]}"
      fi
      "$TARGET_SCRIPT" "${BASE_ARGS[@]}" --host "$host" 2>&1 | sed -u "s/^/[${host}] /"
      rc="${PIPESTATUS[0]}"
      echo "$rc" > "${STATUS_DIR}/${host}.status"
      exit "$rc"
    ) &
    echo "[INFO] started host=${host} rank=${rank} pid=$!"
    rank=$((rank+1))
  done

  wait || true
  FINAL_STATUS=0
  echo "[PHASE] collect"
  for host in "${HOSTS[@]}"; do
    if [[ -f "${STATUS_DIR}/${host}.status" ]]; then rc="$(cat "${STATUS_DIR}/${host}.status")"; else rc=99; fi
    echo "[INFO] host=${host} exit_code=${rc}"
    [[ "$rc" != "0" ]] && FINAL_STATUS=1
  done
  echo "[PHASE] done"
  exit "$FINAL_STATUS"
fi

for host in "${HOSTS[@]}"; do
  (
    set +e
    "$TARGET_SCRIPT" "${BASE_ARGS[@]}" --host "$host" 2>&1 | sed -u "s/^/[${host}] /"
    rc="${PIPESTATUS[0]}"
    echo "$rc" > "${STATUS_DIR}/${host}.status"
    exit "$rc"
  ) &
  echo "[INFO] started host=${host} pid=$!"
done

wait || true

FINAL_STATUS=0

echo "[PHASE] collect"
for host in "${HOSTS[@]}"; do
  if [[ -f "${STATUS_DIR}/${host}.status" ]]; then
    rc="$(cat "${STATUS_DIR}/${host}.status")"
  else
    rc=99
  fi

  echo "[INFO] host=${host} exit_code=${rc}"

  if [[ "$rc" != "0" ]]; then
    FINAL_STATUS=1
  fi
done

echo "[PHASE] done"
exit "$FINAL_STATUS"
