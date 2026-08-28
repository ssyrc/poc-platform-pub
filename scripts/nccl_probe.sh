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
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_image_prep.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_clock.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST_SPECS=()
IMAGE=""
GPUS=""
MASTER_ADDR_ARG=""
MASTER_PORT="${MASTER_PORT:-29500}"
# How long a node may take to join, applied to both rendezvous knobs.
#
# c10d has two, and only setting one is why a node kept timing out at exactly
# 60000ms after this was raised to 600: `timeout` bounds the rendezvous
# barrier, while `read_timeout` bounds each read on the store socket and
# defaults to 60s on its own. A node slower than that has its store read cut
# short no matter how wide the barrier is, and reports a socket timeout --
# which reads as a network fault rather than a slow start.
#
# Containers on a cold node can take minutes, so this is generous by default
# and can be lowered when a fast answer matters more.
PROBE_RDZV_TIMEOUT="${PROBE_RDZV_TIMEOUT:-600}"

# Without --rdzv-id every run shares the id "none" on the same endpoint, so a
# leftover agent or a concurrent run is not separated from this one. Unique per
# invocation, so nothing else can be joined by mistake.
PROBE_RDZV_ID="probe_$$_$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--hosts) HOST_SPECS+=("lit:${2:?--host needs a value}"); shift 2 ;;
    --hosts-file)   HOST_SPECS+=("file:${2:?--hosts-file needs a value}"); shift 2 ;;
    --image)        IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --gpus)         GPUS="${2:?--gpus needs a value}"; shift 2 ;;
    --master-addr)  MASTER_ADDR_ARG="${2:?--master-addr needs a value}"; shift 2 ;;
    --master-port)  MASTER_PORT="${2:?--master-port needs a value}"; shift 2 ;;
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

# Ask the first host what it has: the GPU count (torchrun needs the same
# --nproc_per_node on every node or the ranks disagree about the world size)
# and the model, which decides the B300 default below.
_probe_out="$(cm_remote_bash "${HOSTS[0]}" <<'P' || true
command -v nvidia-smi >/dev/null 2>&1 || { printf '|0\n'; exit 0; }
printf '%s|%s\n' \
  "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" \
  "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
P
)"
_probe_out="$(printf '%s' "$_probe_out" | tail -1 | tr -d '\r')"
GPU_NAME="${_probe_out%%|*}"
if [[ -z "$GPUS" ]]; then
  GPUS="$(printf '%s' "${_probe_out##*|}" | tr -dc '0-9')"
  [[ -n "$GPUS" && "$GPUS" != "0" ]] || die "could not detect GPU count on ${HOSTS[0]} -- pass --gpus"
  echo "[INFO] gpus_per_node=${GPUS} (detected on ${HOSTS[0]}: ${GPU_NAME:-unknown})"
fi

# Same default mlperf_train_v51.sh applies inside the container: on B300 the
# HPC-X plugin this image injects segfaults in ncclCommInitRankConfig. Without
# it here, the probe fails where a real run would have succeeded -- and the
# crash looks like a fabric fault rather than a missing setting.
if [[ -z "${NCCL_NET_PLUGIN:-}" && "$(printf '%s' "$GPU_NAME" | tr '[:lower:]' '[:upper:]')" == *B300* ]]; then
  export NCCL_NET_PLUGIN="none"
  echo "[INFO] B300 detected: NCCL_NET_PLUGIN=none (HPC-X plugin crashes ncclCommInitRankConfig)"
fi

# The probe compares what joined against what was asked for; only this side
# knows the latter.
export PROBE_EXPECTED_WORLD=$(( GPUS * NNODES ))
export PROBE_EXPECTED_HOSTS="$(IFS=,; echo "${HOSTS[*]}")"

PASS_ENV=(
  PROBE_EXPECTED_WORLD PROBE_EXPECTED_HOSTS
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
  echo "[INFO] rendezvous=${MASTER_ADDR}:${MASTER_PORT} (rank 0 = ${HOSTS[0]}), join window ${PROBE_RDZV_TIMEOUT}s"
else
  echo "[INFO] mode=single host=${HOSTS[0]} gpus=${GPUS:-<all>}"
fi
echo "[INFO] image=${IMAGE}"
if [[ "${#FORWARDED[@]}" -gt 0 ]]; then
  echo "[INFO] env into container: ${FORWARDED[*]}"
else
  echo "[INFO] env into container: <none>"
fi

clock_check_hosts "${HOSTS[@]}"

# A container left behind by an earlier run still holds the rendezvous port,
# and joiners reach that one instead. Nothing above this point would notice:
# the port answers, so reachability passes.
if (( NNODES > 1 )); then
  stale=0
  for h in "${HOSTS[@]}"; do
    out="$(cm_remote_bash "$h" "$MASTER_PORT" <<'STALE' 2>/dev/null
port="$1"
listener="$(ss -ltnp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {print $NF; exit}')"
running="$(docker ps --format '{{.Names}}' 2>/dev/null | head -5 | paste -sd, -)"
printf '%s|%s
' "${listener:-none}" "${running:-none}"
STALE
)"
    out="$(printf '%s' "$out" | tail -1 | tr -d '\r')"
    listener="${out%%|*}"; running="${out#*|}"
    if [[ "$listener" != "none" ]]; then
      echo "  ${h}: [STALE] something already listens on ${MASTER_PORT}: ${listener}" >&2
      stale=1
    fi
    if [[ "$running" != "none" ]]; then
      echo "  ${h}: containers running: ${running}" >&2
    fi
  done
  if (( stale )); then
    echo >&2
    echo "[ERROR] the rendezvous port is already in use on a host above." >&2
    echo "[ERROR] Joiners would reach that listener instead of this run's." >&2
    echo "[ERROR] Clear it, or pass --master-port with a free port." >&2
    exit 64
  fi
fi

# A node that cannot reach the rendezvous address never joins, and the symptom
# is a short world with nothing said about which node or why. Check it here,
# where the answer is one line per host.
#
# The distinction that matters is refused vs timed out. Nothing is listening on
# the endpoint yet, so a refused connection is the good case: the packet got
# there and came back. A timeout means it never arrived -- routing, a firewall,
# or a different segment.
if (( NNODES > 1 )); then
  echo "[INFO] checking ${MASTER_ADDR}:${MASTER_PORT} is reachable from every host"
  rdzv_bad=0
  for h in "${HOSTS[@]}"; do
    out="$(cm_remote_bash "$h" "$MASTER_ADDR" "$MASTER_PORT" <<'REACH' 2>/dev/null
target="$1"; port="$2"
route="$(ip route get "$target" 2>/dev/null | head -1 | sed 's/  */ /g')"
timeout 5 bash -c "exec 3<>/dev/tcp/${target}/${port}" 2>/dev/null
rc=$?
case "$rc" in
  0)   verdict="listening" ;;   # something already bound; routable either way
  124) verdict="TIMEOUT" ;;     # never got there
  *)   verdict="refused" ;;     # got there, nothing listening yet -- expected
esac
printf '%s|%s\n' "$verdict" "${route:-no route}"
REACH
)"
    out="$(printf '%s' "$out" | tail -1 | tr -d '\r')"
    verdict="${out%%|*}"; route="${out#*|}"
    case "$verdict" in
      refused|listening) printf '  %-20s ok (%s)  via %s\n' "$h" "$verdict" "$route" ;;
      *)                 printf '  %-20s [FAIL] %s  via %s\n' "$h" "$verdict" "$route" >&2; rdzv_bad=1 ;;
    esac
  done
  if (( rdzv_bad )); then
    echo >&2
    echo "[ERROR] some hosts cannot reach ${MASTER_ADDR}:${MASTER_PORT}." >&2
    echo "[ERROR] Those are the ones that will be missing from the world." >&2
    echo "[ERROR] Compare the 'via' routes above: a host that leaves by a" >&2
    echo "[ERROR] different interface than the others is on another segment." >&2
    echo "[ERROR] Set --master-addr to an address every host shares, or open" >&2
    echo "[ERROR] port ${MASTER_PORT} between them." >&2
    exit 64
  fi
fi

# A host whose docker run fails never joins, and the others then sit in the
# rendezvous until rank 0 gives up -- reported as RendezvousTimeoutError and
# broken pipes, naming nobody. Load the image everywhere first.
image_prep_hosts "$IMAGE" "${MLPERF_TRAIN_IMAGE_TAR:-}" "${HOSTS[@]}" || exit 24

PROBE_B64="$(base64 -w0 < "${SCRIPT_DIR}/nccl_probe.py")"

# One node: torchrun --standalone, no rendezvous, exactly as before.
# Several: each host runs its own torchrun with its node_rank, all meeting at
# the same c10d endpoint. Same flags mlperf_train_v51.sh uses.
emit_remote() {
  local node_rank="$1" launch
  if (( NNODES > 1 )); then
    # This is a pre-flight check, not a job worth waiting ten minutes on: cap
    # the join so a node that never arrives is reported in about a minute.
    launch="torchrun --nnodes=${NNODES} --node_rank=${node_rank} --nproc_per_node=\"\$gpus\" --rdzv_backend=c10d --rdzv-id=${PROBE_RDZV_ID} --rdzv_endpoint=${MASTER_ADDR}:${MASTER_PORT} --rdzv-conf=timeout=${PROBE_RDZV_TIMEOUT},read_timeout=${PROBE_RDZV_TIMEOUT}"
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
echo "[REMOTE] node_rank=${node_rank} nproc_per_node=\$gpus starting torchrun at \$(date +%H:%M:%S)"

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
    # set +e, or pipefail would end this subshell the moment the pipeline
    # fails -- losing the exit status of exactly the hosts worth reporting.
    set +e
    emit_remote "$i" | cm_remote_bash "$h" 2>&1 | tee "${STATUS_DIR}/${i}.log" | sed "s/^/[${h}] /"
    echo "${PIPESTATUS[1]}" > "${STATUS_DIR}/${i}"
  ) &
  PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do wait "$pid" || true; done

# Why a host failed, taken from its own output. Ordered most specific first so
# the line shown is the one worth reading.
failure_reason() {
  local f="$1" line
  [[ -r "$f" ]] || { printf 'no output captured'; return; }
  for pat in 'Error response from daemon' 'docker: ' 'CUDA error' \
             'Fatal Python error' '^[A-Za-z_.]*Error: ' 'RendezvousTimeout' \
             'no space left' 'Permission denied' 'NCCL WARN' '\[ERROR\]'; do
    line="$(grep -aoE "${pat}.*" "$f" 2>/dev/null | tail -1)"
    [[ -n "$line" ]] && { printf '%.100s' "$line"; return; }
  done
  line="$(grep -av '^\s*$' "$f" 2>/dev/null | tail -1)"
  printf '%.100s' "${line:-exited without output}"
}

RC=0
echo
echo "===================================================================="
echo "PER-HOST RESULT"
echo "===================================================================="
printf '  %-4s %-20s %-6s %s\n' "rank" "host" "exit" "note"
echo "  ----------------------------------------------------------------"
for i in "${!HOSTS[@]}"; do
  st="$(cat "${STATUS_DIR}/${i}" 2>/dev/null || echo "?")"
  if [[ "$st" == "0" ]]; then
    printf '  %-4s %-20s %-6s %s\n' "$i" "${HOSTS[$i]}" "$st" "ok"
  else
    printf '  %-4s %-20s %-6s %s\n' "$i" "${HOSTS[$i]}" "$st" "$(failure_reason "${STATUS_DIR}/${i}.log")"
    RC=1
  fi
done
echo "  ----------------------------------------------------------------"

# Overall verdict from the probe's own RESULT line. Separate from the per-host
# column above: a host that ran correctly reads ok even when the job is short.
result_line="$(grep -ahoE '\[probe\] RESULT .*' "${STATUS_DIR}"/*.log 2>/dev/null | tail -1 || true)"
if [[ -n "$result_line" ]]; then
  got_world="$(sed -n 's/.*world=\([0-9]*\).*/\1/p' <<< "$result_line")"
  exp_world="$(sed -n 's/.*expected=\([0-9]*\).*/\1/p' <<< "$result_line")"
  got_nodes="$(sed -n 's/.*nodes=\([0-9]*\).*/\1/p' <<< "$result_line")"
  echo "  world formed: ${got_world}/${exp_world} ranks, ${got_nodes}/${NNODES} nodes"
  if [[ -n "$got_world" && -n "$exp_world" && "$got_world" != "$exp_world" ]]; then
    echo "  [FAIL] $(( exp_world - got_world )) rank(s) short -- the hosts above with a" >&2
    echo "         non-zero exit are the ones that did not join" >&2
    RC=1
  fi
elif (( RC == 0 )); then
  echo "  [WARN] no RESULT line found; the probe may not have reached rank 0's report" >&2
  RC=1
fi

if (( RC == 0 )); then
  echo "  all ${NNODES} host(s) OK"
fi
echo "===================================================================="
exit "$RC"
