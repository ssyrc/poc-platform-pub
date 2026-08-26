#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/nccl_probe.sh
# --------------------
# Runs nccl_probe.py in the training container on a target host: NCCL init
# plus one all-reduce, and nothing else.
#
# The training runs crash during NCCL communicator setup, but a training run
# also loads NeMo, Megatron, TransformerEngine and Lightning, so the crash
# could belong to any of them. This loads none of them, and finishes in about
# half a minute instead of five.
#
# Container flags match what mlperf_train_v51.sh uses (--ipc=host,
# --network=host, memlock/stack ulimits, IB device passthrough), so a pass
# here really does mean the training run's environment is not at fault.
#
# Usage:
#   nccl_probe.sh --host 192.0.2.41 --image <repo:tag>
#   nccl_probe.sh --host 192.0.2.41 --image <repo:tag> --gpus 2
#   NCCL_MNNVL_ENABLE=0 nccl_probe.sh --host ... --image ...
#
# Options:
#   --host <host|ip>   target (default: localhost)
#   --image <ref>      container image to run in (required)
#   --gpus <N>         ranks to start (default: all GPUs on the target)
#
# Any of these that are set in the environment are passed into the container:
#   NCCL_DEBUG NCCL_DEBUG_SUBSYS NCCL_MNNVL_ENABLE NCCL_CUMEM_ENABLE
#   NCCL_NVLS_ENABLE NCCL_NET_PLUGIN NCCL_TUNER_PLUGIN NCCL_NET
#   NCCL_COLLNET_ENABLE NCCL_P2P_DISABLE NCCL_SHM_DISABLE NCCL_IB_DISABLE
#   NCCL_IB_HCA NCCL_SOCKET_IFNAME UCX_HANDLE_ERRORS UCX_ERROR_SIGNALS
#   PYTHONFAULTHANDLER TORCH_SHOW_CPP_STACKTRACES CUDA_LAUNCH_BLOCKING

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST="localhost"
IMAGE=""
GPUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)  HOST="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --gpus)  GPUS="${2:?}"; shift 2 ;;
    -h|--help) sed -n '4,32p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host: $HOST"
[[ -n "$IMAGE" ]] || die "--image is required"

PASS_ENV=(
  NCCL_DEBUG NCCL_DEBUG_SUBSYS
  NCCL_MNNVL_ENABLE NCCL_CUMEM_ENABLE NCCL_NVLS_ENABLE
  NCCL_NET_PLUGIN NCCL_TUNER_PLUGIN NCCL_NET NCCL_COLLNET_ENABLE
  NCCL_P2P_DISABLE NCCL_SHM_DISABLE NCCL_IB_DISABLE
  NCCL_IB_HCA NCCL_SOCKET_IFNAME
  UCX_HANDLE_ERRORS UCX_ERROR_SIGNALS
  PYTHONFAULTHANDLER TORCH_SHOW_CPP_STACKTRACES CUDA_LAUNCH_BLOCKING
)

# UCX_ERROR_SIGNALS= (deliberately empty) has to survive, so test with -v
# rather than -n: an empty value is still a value worth forwarding.
DOCKER_ENV_ARGS=""
FORWARDED=()
for v in "${PASS_ENV[@]}"; do
  if [[ -v "$v" ]]; then
    DOCKER_ENV_ARGS+=" -e ${v}=$(printf '%q' "${!v}")"
    FORWARDED+=("${v}=${!v}")
  fi
done

echo "[INFO] host=${HOST} image=${IMAGE} gpus=${GPUS:-<all>}"
if [[ "${#FORWARDED[@]}" -gt 0 ]]; then
  echo "[INFO] env into container: ${FORWARDED[*]}"
else
  echo "[INFO] env into container: <none>"
fi

PROBE_B64="$(base64 -w0 < "${SCRIPT_DIR}/nccl_probe.py")"

cm_remote_bash "$HOST" <<REMOTE
set -Eeuo pipefail

gpus="${GPUS}"
if [[ -z "\$gpus" ]]; then
  gpus="\$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
fi
[[ "\$gpus" =~ ^[0-9]+\$ && "\$gpus" -ge 1 ]] || { echo "[ERROR] no GPUs detected on ${HOST}" >&2; exit 1; }
echo "[REMOTE] nproc_per_node=\$gpus"

work="\$(mktemp -d)"
trap 'rm -rf "\$work"' EXIT
printf '%s' '${PROBE_B64}' | base64 -d > "\$work/nccl_probe.py"

ib_args=""
if compgen -G "/dev/infiniband/*" >/dev/null 2>&1; then
  for dev in /dev/infiniband/*; do ib_args="\$ib_args --device \$dev"; done
fi

set -x
docker run --rm \
  --gpus all \
  --network=host \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  \$ib_args \
  -v "\$work:/probe:ro" \
  ${DOCKER_ENV_ARGS} \
  "${IMAGE}" \
  torchrun --standalone --nproc_per_node="\$gpus" /probe/nccl_probe.py
REMOTE
