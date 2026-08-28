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
# With two or more hosts it becomes the multi-node version of the same check:
# one distributed job across the hosts, so the all-reduce actually crosses the
# network. That exercises the inter-node path -- IB, the NIC binding, the
# rendezvous -- without NeMo on top of it.
#
# Usage:
#   nccl_probe.sh --host 192.0.2.41 --image <repo:tag>
#   nccl_probe.sh --host 192.0.2.41 --image <repo:tag> --gpus 2
#   nccl_probe.sh --hosts 192.0.2.41,192.0.2.42 --image <repo:tag>
#   nccl_probe.sh --hosts-file hostfile --image <repo:tag>
#   NCCL_MNNVL_ENABLE=0 nccl_probe.sh --host ... --image ...
#
# Options:
#   --host <host|ip>   single target (default: localhost)
#   --hosts a,b,c      several targets, one distributed job. Order sets rank:
#                      the first entry is rank 0 and hosts the rendezvous.
#   --hosts-file <p>   one host per line; '#' comments and blanks ignored.
#                      Defaults to MLPERF_HOSTFILE when no host flag is given.
#   --image <ref>      container image to run in (required)
#   --gpus <N>         ranks per node (default: all GPUs on the first host)
#   --master-addr <ip> rendezvous address (default: the first host)
#   --master-port <p>  rendezvous port (default: 29500)
#
# Multi-node needs the rendezvous port reachable between nodes, and every host
# needs the image present. NCCL picks its own interface unless NCCL_IB_HCA and
# NCCL_SOCKET_IFNAME are set, and both are forwarded if you set them.
#
# Any of these that are set in the environment are passed into the container:
#   NCCL_DEBUG NCCL_DEBUG_SUBSYS NCCL_MNNVL_ENABLE NCCL_CUMEM_ENABLE
#   NCCL_NVLS_ENABLE NCCL_NET_PLUGIN NCCL_TUNER_PLUGIN NCCL_NET
#   NCCL_COLLNET_ENABLE NCCL_P2P_DISABLE NCCL_SHM_DISABLE NCCL_IB_DISABLE
#   NCCL_IB_HCA NCCL_SOCKET_IFNAME NCCL_SOCKET_FAMILY NCCL_IB_GID_INDEX
#   NCCL_IB_TIMEOUT NCCL_IB_RETRY_CNT NCCL_IB_TC NCCL_IB_SL
#   NCCL_IB_QPS_PER_CONNECTION NCCL_DMABUF_ENABLE NCCL_NET_GDR_LEVEL
#   NCCL_NET_GDR_READ UCX_HANDLE_ERRORS UCX_ERROR_SIGNALS
#   PYTHONFAULTHANDLER TORCH_SHOW_CPP_STACKTRACES CUDA_LAUNCH_BLOCKING

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_hosts.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST_SPECS=()
IMAGE=""
GPUS=""
MASTER_ADDR_ARG=""
MASTER_PORT="${MASTER_PORT:-29500}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--hosts) HOST_SPECS+=("lit:${2:?}"); shift 2 ;;
    --hosts-file)   HOST_SPECS+=("file:${2:?}"); shift 2 ;;
    --image)        IMAGE="${2:?}"; shift 2 ;;
    --gpus)         GPUS="${2:?}"; shift 2 ;;
    --master-addr)  MASTER_ADDR_ARG="${2:?}"; shift 2 ;;
    --master-port)  MASTER_PORT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '4,45p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "${#HOST_SPECS[@]}" -eq 0 && -n "${MLPERF_HOSTFILE:-}" ]]; then
  HOST_SPECS+=("file:${MLPERF_HOSTFILE}")
  echo "[INFO] using MLPERF_HOSTFILE=${MLPERF_HOSTFILE}"
fi
[[ "${#HOST_SPECS[@]}" -gt 0 ]] || HOST_SPECS=("lit:localhost")

hosts_expand HOSTS "${HOST_SPECS[@]}" || exit 64
[[ "${#HOSTS[@]}" -ge 1 ]] || die "no hosts given"
[[ -n "$IMAGE" ]] || die "--image is required"

NNODES="${#HOSTS[@]}"
MASTER_ADDR="${MASTER_ADDR_ARG:-${HOSTS[0]}}"

PASS_ENV=(
  NCCL_DEBUG NCCL_DEBUG_SUBSYS
  NCCL_MNNVL_ENABLE NCCL_CUMEM_ENABLE NCCL_NVLS_ENABLE
  NCCL_NET_PLUGIN NCCL_TUNER_PLUGIN NCCL_NET NCCL_COLLNET_ENABLE
  NCCL_P2P_DISABLE NCCL_SHM_DISABLE NCCL_IB_DISABLE
  NCCL_IB_HCA NCCL_SOCKET_IFNAME NCCL_SOCKET_FAMILY
  NCCL_IB_GID_INDEX NCCL_IB_TIMEOUT NCCL_IB_RETRY_CNT
  NCCL_IB_TC NCCL_IB_SL NCCL_IB_QPS_PER_CONNECTION
  NCCL_DMABUF_ENABLE NCCL_NET_GDR_LEVEL NCCL_NET_GDR_READ
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

if (( NNODES > 1 )); then
  echo "[INFO] mode=multi nnodes=${NNODES} hosts=${HOSTS[*]} gpus_per_node=${GPUS:-<all>}"
  echo "[INFO] rendezvous=${MASTER_ADDR}:${MASTER_PORT} (rank 0 = ${HOSTS[0]})"
else
  echo "[INFO] mode=single host=${HOSTS[0]} gpus=${GPUS:-<all>}"
fi
echo "[INFO] image=${IMAGE}"
if [[ "${#FORWARDED[@]}" -gt 0 ]]; then
  echo "[INFO] env into container: ${FORWARDED[*]}"
else
  echo "[INFO] env into container: <none>"
fi

PROBE_B64="$(base64 -w0 < "${SCRIPT_DIR}/nccl_probe.py")"

# GPUs per node is decided once, on the first host, and used for every node --
# torchrun needs the same --nproc_per_node everywhere or the world size the
# ranks agree on will not match.
if [[ -z "$GPUS" ]] && (( NNODES > 1 )); then
  GPUS="$(cm_remote_bash "${HOSTS[0]}" <<<'nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l' || true)"
  GPUS="$(echo "$GPUS" | tr -dc '0-9')"
  [[ -n "$GPUS" && "$GPUS" != "0" ]] || die "could not detect GPU count on ${HOSTS[0]} -- pass --gpus"
  echo "[INFO] gpus_per_node=${GPUS} (detected on ${HOSTS[0]})"
fi

# One node: torchrun --standalone, no rendezvous, exactly as before.
# Several: each host runs its own torchrun with its node_rank, all meeting at
# the same c10d endpoint. Same flags mlperf_train_v51.sh uses.
emit_remote() {
  local node_rank="$1" launch
  if (( NNODES > 1 )); then
    launch="torchrun --nnodes=${NNODES} --node_rank=${node_rank} --nproc_per_node=\"\$gpus\" --rdzv_backend=c10d --rdzv_endpoint=${MASTER_ADDR}:${MASTER_PORT}"
  else
    launch="torchrun --standalone --nnodes=1 --nproc_per_node=\"\$gpus\""
  fi
  cat <<REMOTE
set -Eeuo pipefail

gpus="${GPUS}"
if [[ -z "\$gpus" ]]; then
  gpus="\$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
fi
[[ "\$gpus" =~ ^[0-9]+\$ && "\$gpus" -ge 1 ]] || { echo "[ERROR] no GPUs detected" >&2; exit 1; }
echo "[REMOTE] node_rank=${node_rank} nproc_per_node=\$gpus"

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
  ${launch} /probe/nccl_probe.py
REMOTE
}

if (( NNODES == 1 )); then
  emit_remote 0 | cm_remote_bash "${HOSTS[0]}"
  exit $?
fi

# Every node has to be up for the rendezvous to complete, so they start
# together and we wait for all of them. Output is prefixed per host, since
# interleaved multi-node logs are otherwise unreadable.
PIDS=()
STATUS_DIR="$(mktemp -d)"
trap 'rm -rf "$STATUS_DIR"' EXIT

for i in "${!HOSTS[@]}"; do
  h="${HOSTS[$i]}"
  (
    emit_remote "$i" | cm_remote_bash "$h" 2>&1 | sed "s/^/[${h}] /"
    echo "${PIPESTATUS[1]}" > "${STATUS_DIR}/${i}"
  ) &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do wait "$pid" || true; done

RC=0
echo
echo "[INFO] per-host result:"
for i in "${!HOSTS[@]}"; do
  st="$(cat "${STATUS_DIR}/${i}" 2>/dev/null || echo "?")"
  printf '  rank %-3s %-20s exit=%s\n' "$i" "${HOSTS[$i]}" "$st"
  [[ "$st" == "0" ]] || RC=1
done

if (( RC == 0 )); then
  echo "[INFO] multi-node NCCL OK across ${NNODES} nodes"
else
  echo "[INFO] at least one node failed -- see its output above" >&2
fi
exit "$RC"
