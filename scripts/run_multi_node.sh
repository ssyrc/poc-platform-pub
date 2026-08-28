#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/run_multi_node.sh
# ------------------------
# Multi-node MLPerf Training run: one distributed job spanning every host, one
# rank per host.
#
# The distinction that matters: mlperf_run.sh only builds a distributed job
# when MLPERF_NODE_MODE=multi is exported. Without it the same --hosts list
# starts an independent single-node run per host, which looks similar in the
# logs and produces per-host results instead of one job. This wrapper sets that
# variable, so it cannot be forgotten, and refuses to run with fewer than two
# hosts.
#
# RDMA binding is automatic. For each host, mlperf_run.sh parses
# `nvidia-smi topo -m` for the GPUs that host will use and picks the closest
# NIC by PIX > PXB > PHB > NODE > SYS affinity, converts it to an HCA name for
# NCCL_IB_HCA, maps it through `ibdev2netdev` to a netdev for
# NCCL_SOCKET_IFNAME (only interfaces that are UP with a global IP), and takes
# rank 0's compute-net IP as MASTER_ADDR. Detection runs per host, so NIC
# numbering does not have to match across servers. Setting NCCL_IB_HCA,
# NCCL_SOCKET_IFNAME or MASTER_ADDR yourself overrides the corresponding step.
#
# Usage:
#   run_multi_node.sh --hosts 192.0.2.41,192.0.2.42
#   run_multi_node.sh --hosts 192.0.2.41,192.0.2.42 --gpus 8 --dry-run
#   run_multi_node.sh --hosts node1,node2,node3 --version v4.1
#   run_multi_node.sh --hosts-file hostfile
#
# Options:
#   --hosts a,b,c        hostnames or IPs, comma-separated. Order sets rank:
#                        the first entry is rank 0 and hosts MASTER_ADDR.
#   --hosts-file <path>  one host per line; '#' comments and blank lines are
#                        ignored. Repeatable, and combinable with --hosts --
#                        they expand in the order given. Defaults to
#                        MLPERF_HOSTFILE when neither flag is passed.
#   --version            v4.1 | v5.1                  (default: v5.1)
#   --benchmark          default: llama2_70b_lora
#   --gpu-type           default: detected on the first host
#   --gpus <N>           GPUs PER NODE (default: detected on the first host).
#                        Every host must supply this many; world size is
#                        gpus x hosts.
#   --master-port <p>    default: 29500
#   --run-id <id>        default: train<version>_multi_<timestamp>
#   --dry-run            validate and print the command, do not run
#   anything else is passed straight through to mlperf_run.sh
#
# Inference has no multi-node mode here — mlperf_run.sh only branches on
# MLPERF_NODE_MODE for --suite training.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_train_params.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_hosts.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_image_prep.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST_SPECS=()
VERSION="v5.1"
BENCHMARK="llama2_70b_lora"
GPU_TYPE=""
GPUS=""
MASTER_PORT_ARG=""
RUN_ID=""
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)       HOST_SPECS+=("lit:${2:?}"); shift 2 ;;
    --hosts-file)  HOST_SPECS+=("file:${2:?}"); shift 2 ;;
    --version)     VERSION="${2:?}"; shift 2 ;;
    --benchmark)   BENCHMARK="${2:?}"; shift 2 ;;
    --gpu-type)    GPU_TYPE="${2:?}"; shift 2 ;;
    --gpus)        GPUS="${2:?}"; shift 2 ;;
    --master-port) MASTER_PORT_ARG="${2:?}"; shift 2 ;;
    --run-id)      RUN_ID="${2:?}"; shift 2 ;;
    -h|--help)     sed -n '4,44p' "$0"; train_params_help; exit 0 ;;
    *)
      if train_param_try "$1" "${2:-}"; then shift "$TRAIN_PARAM_SHIFT"; continue; fi
      PASSTHRU+=("$1"); shift ;;
  esac
done

# MLPERF_HOSTFILE lets a fixed cluster be described once in .env instead of on
# every command line.
if [[ "${#HOST_SPECS[@]}" -eq 0 && -n "${MLPERF_HOSTFILE:-}" ]]; then
  HOST_SPECS+=("file:${MLPERF_HOSTFILE}")
  echo "[INFO] using MLPERF_HOSTFILE=${MLPERF_HOSTFILE}"
fi
[[ "${#HOST_SPECS[@]}" -gt 0 ]] || die "--hosts or --hosts-file is required"

hosts_expand HOSTS "${HOST_SPECS[@]}" || exit 64

[[ "${#HOSTS[@]}" -ge 2 ]] || die "multi-node needs at least two hosts (got ${#HOSTS[@]}). Use run_single_node.sh for one."

FIRST="${HOSTS[0]}"

if [[ -z "$GPU_TYPE" || -z "$GPUS" ]]; then
  probe_out="$(cm_remote_bash "$FIRST" <<'P' || true
command -v nvidia-smi >/dev/null 2>&1 || { printf '|0\n'; exit 0; }
name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
count="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
printf '%s|%s\n' "$name" "$count"
P
)"
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
      *) die "could not detect GPU type on ${FIRST} (saw '${gpu_name}') — pass --gpu-type" ;;
    esac
  fi
  [[ -z "$GPUS" ]] && GPUS="$gpu_count"
fi

[[ "$GPUS" =~ ^[0-9]+$ && "$GPUS" -ge 1 ]] || die "--gpus (GPUs per node) must be a positive integer: $GPUS"

NNODES="${#HOSTS[@]}"
WORLD=$(( GPUS * NNODES ))
RUN_ID="${RUN_ID:-train${VERSION//./}_multi_$(date +%Y%m%d_%H%M%S)}"

echo "[INFO] mode=multi nnodes=${NNODES} gpus_per_node=${GPUS} world_size_gpus=${WORLD}"
echo "[INFO] rank0=${FIRST} (MASTER_ADDR source) hosts=${HOSTS[*]}"
echo "[INFO] version=${VERSION} benchmark=${BENCHMARK} gpu_type=${GPU_TYPE} run_id=${RUN_ID}"

# Every host must have the image loaded before any host starts a container --
# see lib_image_prep.sh for why checking that a tar exists is not enough.
#
# Only what this wrapper knows is handled: the image when --docker-image was
# given, and the tar when MLPERF_TRAIN_IMAGE_TAR was. Picking the default image
# depends on gpu type and benchmark and stays the launcher's job.
USER_IMAGE=""
for i in "${!PASSTHRU[@]}"; do
  if [[ "${PASSTHRU[$i]}" == "--docker-image" ]]; then
    USER_IMAGE="${PASSTHRU[$((i+1))]:-}"
    break
  fi
done

if [[ -n "$USER_IMAGE" || -n "${MLPERF_TRAIN_IMAGE_TAR:-}" ]]; then
  image_prep_hosts "$USER_IMAGE" "${MLPERF_TRAIN_IMAGE_TAR:-}" "${HOSTS[@]}" || exit 24
fi

# Multi node: world size spans every rank, so TP x PP x CP may exceed one node.
train_params_validate "$WORLD" "$GPUS"
train_params_export
if [[ -n "${NCCL_IB_HCA:-}${NCCL_SOCKET_IFNAME:-}${MASTER_ADDR:-}" ]]; then
  echo "[INFO] RDMA overrides in effect: HCA=${NCCL_IB_HCA:-auto} IFNAME=${NCCL_SOCKET_IFNAME:-auto} MASTER_ADDR=${MASTER_ADDR:-auto}"
else
  echo "[INFO] RDMA binding auto-detected per host (nvidia-smi topo -m + ibdev2netdev)"
fi

# These two are what turn --hosts into one distributed job instead of a
# per-host fan-out; mlperf_run.sh reads them from the environment, not flags.
export MLPERF_NODE_MODE="multi"
export GPUS_PER_NODE="$GPUS"
[[ -n "$MASTER_PORT_ARG" ]] && export MASTER_PORT="$MASTER_PORT_ARG"

exec "${SCRIPT_DIR}/mlperf_run.sh" \
  --run-id "$RUN_ID" \
  --suite training \
  --version "$VERSION" \
  --benchmark "$BENCHMARK" \
  --gpu-type "$GPU_TYPE" \
  --hosts "$(IFS=,; echo "${HOSTS[*]}")" \
  ${PASSTHRU[@]+"${PASSTHRU[@]}"}
