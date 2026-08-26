#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/run_single_node.sh
# -------------------------
# Single-node MLPerf run. Thin wrapper over mlperf_run.sh that fills in the
# run id, GPU type and GPU count from the target host so a normal run is one
# short command.
#
# "Single node" here means MLPERF_NODE_MODE is left unset, which is the
# default. Passing several hosts in this mode does NOT make one distributed
# job — mlperf_run.sh fans out an independent run per host. Use
# run_multi_node.sh for a single job spanning hosts.
#
# Usage:
#   run_single_node.sh --host 192.0.2.41
#   run_single_node.sh --host gpu-node03 --suite inference --version v6.0
#   run_single_node.sh --host 192.0.2.41 --gpus 4 --dry-run
#
# Options:
#   --host <host|ip>     target (default: localhost)
#   --suite              training | inference        (default: training)
#   --version            v4.1 | v5.1 | v6.0          (default: v5.1)
#   --benchmark          default: llama2_70b_lora for training, llama2_70b for inference
#   --gpu-type           default: detected on the target
#   --gpus <N>           GPUs to use (default: all detected on the target)
#   --run-id <id>        default: <suite><version>_single_<timestamp>
#   --dry-run            validate and print the command, do not run
#   anything else is passed straight through to mlperf_run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST="localhost"
SUITE="training"
VERSION="v5.1"
BENCHMARK=""
GPU_TYPE=""
GPUS=""
RUN_ID=""
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)      HOST="${2:?}"; shift 2 ;;
    --suite)     SUITE="${2:?}"; shift 2 ;;
    --version)   VERSION="${2:?}"; shift 2 ;;
    --benchmark) BENCHMARK="${2:?}"; shift 2 ;;
    --gpu-type)  GPU_TYPE="${2:?}"; shift 2 ;;
    --gpus)      GPUS="${2:?}"; shift 2 ;;
    --run-id)    RUN_ID="${2:?}"; shift 2 ;;
    -h|--help)   sed -n '4,30p' "$0"; exit 0 ;;
    *)           PASSTHRU+=("$1"); shift ;;
  esac
done

[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host: $HOST"

# Probe the target the same way the launchers do, so the values we pass match
# what the run will actually see.
probe() { cm_remote_bash "$HOST" <<'P'
command -v nvidia-smi >/dev/null 2>&1 || { printf '|0\n'; exit 0; }
name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
count="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
printf '%s|%s\n' "$name" "$count"
P
}

if [[ -z "$GPU_TYPE" || -z "$GPUS" ]]; then
  probe_out="$(probe || true)"
  gpu_name="${probe_out%%|*}"
  gpu_count="${probe_out##*|}"
  [[ "$gpu_count" =~ ^[0-9]+$ ]] || gpu_count=0

  if [[ -z "$GPU_TYPE" ]]; then
    case "$(printf '%s' "$gpu_name" | tr '[:lower:]' '[:upper:]')" in
      *GH200*)          GPU_TYPE="GH200" ;;
      *B300*)           GPU_TYPE="B300" ;;
      *B200*)           GPU_TYPE="B200" ;;
      *H200*|*H100*)    GPU_TYPE="H100" ;;
      *A100*)           GPU_TYPE="A100" ;;
      *V100*)           GPU_TYPE="V100" ;;
      *"RTX PRO 6000"*) GPU_TYPE="RTX_PRO_6000" ;;
      *) die "could not detect GPU type on ${HOST} (saw '${gpu_name}') — pass --gpu-type" ;;
    esac
  fi
  [[ -z "$GPUS" ]] && GPUS="$gpu_count"
fi

[[ "$GPUS" =~ ^[0-9]+$ && "$GPUS" -ge 1 ]] || die "--gpus must be a positive integer: $GPUS"

if [[ -z "$BENCHMARK" ]]; then
  case "$SUITE" in
    training)  BENCHMARK="llama2_70b_lora" ;;
    inference) BENCHMARK="llama2_70b" ;;
    *) die "--suite must be training or inference: $SUITE" ;;
  esac
fi

RUN_ID="${RUN_ID:-${SUITE}${VERSION//./}_single_$(date +%Y%m%d_%H%M%S)}"

echo "[INFO] mode=single host=${HOST} gpu_type=${GPU_TYPE} gpus=${GPUS}"
echo "[INFO] suite=${SUITE} version=${VERSION} benchmark=${BENCHMARK} run_id=${RUN_ID}"

# NUM_GPUS is how the launchers learn the per-host GPU count in single mode.
export NUM_GPUS="$GPUS"
export MLPERF_NUM_GPUS="$GPUS"

exec "${SCRIPT_DIR}/mlperf_run.sh" \
  --run-id "$RUN_ID" \
  --suite "$SUITE" \
  --version "$VERSION" \
  --benchmark "$BENCHMARK" \
  --gpu-type "$GPU_TYPE" \
  --hosts "$HOST" \
  ${PASSTHRU[@]+"${PASSTHRU[@]}"}
