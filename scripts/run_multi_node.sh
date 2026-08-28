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
#
# Options:
#   --hosts a,b,c        hostnames or IPs, comma-separated. Order sets rank:
#                        the first entry is rank 0 and hosts MASTER_ADDR.
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

die() { echo "[ERROR] $*" >&2; exit 1; }

HOSTS_RAW=""
VERSION="v5.1"
BENCHMARK="llama2_70b_lora"
GPU_TYPE=""
GPUS=""
MASTER_PORT_ARG=""
RUN_ID=""
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)       HOSTS_RAW="${2:?}"; shift 2 ;;
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

[[ -n "$HOSTS_RAW" ]] || die "--hosts is required (comma-separated hostnames or IPs)"

HOSTS=()
IFS=',' read -ra _parts <<< "$HOSTS_RAW"
for h in "${_parts[@]}"; do
  h="$(echo "$h" | xargs)"
  [[ -n "$h" ]] || continue
  # Same character set mlperf_run.sh accepts; IPv4 passes as-is.
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host: $h"
  HOSTS+=("$h")
done

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

# Every host has to be able to obtain the image. Without this the run starts,
# the hosts that have it get as far as launching a container, and the one that
# does not dies with "Docker image missing and fallback-load/pull failed" --
# after the others are already up. Check first and name the host.
#
# Only what this wrapper actually knows is checked: the image when --docker-image
# was given, and the tar when MLPERF_TRAIN_IMAGE_TAR was. Picking the default
# image is the launcher's job and depends on gpu type and benchmark, so it is
# not second-guessed here.
USER_IMAGE=""
for i in "${!PASSTHRU[@]}"; do
  if [[ "${PASSTHRU[$i]}" == "--docker-image" ]]; then
    USER_IMAGE="${PASSTHRU[$((i+1))]:-}"
    break
  fi
done

if [[ -n "$USER_IMAGE" || -n "${MLPERF_TRAIN_IMAGE_TAR:-}" ]]; then
  echo "[INFO] checking image availability on ${NNODES} host(s)"
  image_fail=0
  for h in "${HOSTS[@]}"; do
    verdict="$(cm_remote_bash "$h" <<CHECK || true
img="${USER_IMAGE}"
tar="${MLPERF_TRAIN_IMAGE_TAR:-}"
dirs="${POC_PLATFORM_DOCKERIMG_DIRS:-}"

if [[ -n "\$img" ]] && docker image inspect "\$img" >/dev/null 2>&1; then
  echo "loaded"; exit 0
fi
if [[ -n "\$tar" && -r "\$tar" ]]; then
  echo "tar:\$tar"; exit 0
fi
if [[ -n "\$tar" && -n "\$dirs" ]]; then
  base="\$(basename "\$tar")"
  IFS=':' read -ra dd <<< "\$dirs"
  for d in "\${dd[@]}"; do
    [[ -n "\$d" && -r "\${d}/\${base}" ]] && { echo "tar:\${d}/\${base}"; exit 0; }
  done
fi
echo "MISSING"
CHECK
)"
    verdict="$(echo "$verdict" | tail -1 | tr -d '\r')"
    case "$verdict" in
      loaded)  echo "  ${h}: image already loaded" ;;
      tar:*)   echo "  ${h}: will load from ${verdict#tar:}" ;;
      *)       echo "  ${h}: [MISSING] no image and no readable tar" >&2; image_fail=1 ;;
    esac
  done
  if (( image_fail )); then
    echo >&2
    echo "[ERROR] at least one host cannot obtain the image; not starting the run." >&2
    echo "[ERROR] on each host marked MISSING, either:" >&2
    echo "[ERROR]   ssh <host> \"docker load -i ${MLPERF_TRAIN_IMAGE_TAR:-<tar>}\"" >&2
    echo "[ERROR]   or make the tar readable there and set POC_PLATFORM_DOCKERIMG_DIRS" >&2
    exit 24
  fi
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
