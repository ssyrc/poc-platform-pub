#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/node_check.sh
# --------------------
# Check a GPU node's host-side prerequisites and report every problem at once.
#
# preflight.sh checks the management side -- data roots, image tars, the repo
# layout. This checks the other half: what a GPU node itself has to provide
# before a container can train on it.
#
# The split that matters, and the one that trips people up: almost nothing in
# the software stack comes from the node. The image carries CUDA, NCCL, HPC-X,
# UCX, cuDNN and PyTorch. The node contributes the kernel side only -- the
# NVIDIA driver, the InfiniBand kernel drivers and their device nodes, and the
# daemons that manage NVSwitch. Installing CUDA or NCCL on the node does not
# change what runs inside the container.
#
# Usage:
#   node_check.sh                     # check this machine
#   node_check.sh --host 192.0.2.41   # check a remote node over ssh
#   node_check.sh --host 192.0.2.41 --image <repo:tag>
#
# Options:
#   --host <host|ip>   node to check (default: localhost)
#   --image <ref>      also verify the container can see GPUs and IB through
#                      this image. Skipped if not given.
#
# Exit: 0 all required checks passed, 1 something required is missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST="localhost"
IMAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)  HOST="${2:?--host needs a value}"; shift 2 ;;
    --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
    -h|--help) sed -n '4,29p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host: $HOST"

# The whole check runs on the node in one hop; the local side only prints.
# Escaped so the remote shell expands it, not this one.
cm_remote_bash "$HOST" <<REMOTE
set -uo pipefail

IMAGE="${IMAGE}"

FAIL=0
WARN=0
GREEN=\$'\033[32m'; RED=\$'\033[31m'; YELLOW=\$'\033[33m'; DIM=\$'\033[2m'; RESET=\$'\033[0m'

ok()   { printf '  %sOK  %s %s\n' "\$GREEN" "\$RESET" "\$1"; }
bad()  { printf '  %sMISS%s %s\n' "\$RED" "\$RESET" "\$1"; FAIL=\$((FAIL+1)); }
warn() { printf '  %sWARN%s %s\n' "\$YELLOW" "\$RESET" "\$1"; WARN=\$((WARN+1)); }
note() { printf '       %s%s%s\n' "\$DIM" "\$1" "\$RESET"; }
head_() { printf '\n\033[1m[%s]\033[0m\n' "\$1"; }

printf '\n\033[1mNode check: %s\033[0m\n' "\$(hostname -f 2>/dev/null || hostname)"

# ---------------------------------------------------------------- driver ----
head_ "NVIDIA driver"
if command -v nvidia-smi >/dev/null 2>&1; then
  drv="\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  gpu="\$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  cnt="\$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
  cc="\$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)"
  if [[ -n "\$drv" ]]; then
    ok "driver \${drv} -- \${cnt} x \${gpu} (compute capability \${cc})"
    # Blackwell datacenter parts need an r580 or newer driver for CUDA 13
    # images; the containers here are CUDA 13.0.
    major="\${drv%%.*}"
    if [[ "\$cc" == 10.* || "\$cc" == 12.* ]] && (( major < 580 )); then
      bad "driver \${drv} is older than r580; CUDA 13 images need r580+"
    fi
  else
    bad "nvidia-smi present but returned nothing"
  fi
else
  bad "nvidia-smi not found -- NVIDIA driver not installed"
fi

# ---------------------------------------------------------------- docker ----
head_ "Docker + GPU runtime"
if ! command -v docker >/dev/null 2>&1; then
  bad "docker not found"
elif ! docker info >/dev/null 2>&1; then
  bad "docker present but the daemon is not reachable (permission, or not running)"
else
  ok "docker \$(docker --version 2>/dev/null | awk '{print \$3}' | tr -d ,)"
  # nvidia-container-toolkit is what injects the driver libraries into a
  # container. Without it --gpus fails even though the driver is fine.
  if docker run --rm --gpus all ubuntu:22.04 true >/dev/null 2>&1 \
     || docker run --rm --gpus all "\${IMAGE:-ubuntu:22.04}" true >/dev/null 2>&1; then
    ok "nvidia-container-toolkit -- 'docker run --gpus all' works"
  else
    if command -v nvidia-ctk >/dev/null 2>&1; then
      warn "nvidia-ctk present but '--gpus all' failed (no local test image?)"
      note "retry with --image <a tag this node already has>"
    else
      bad "nvidia-container-toolkit missing -- 'docker run --gpus all' will fail"
      note "install nvidia-container-toolkit, then: nvidia-ctk runtime configure --runtime=docker && systemctl restart docker"
    fi
  fi
fi

# ------------------------------------------------------------- nvswitch -----
head_ "NVSwitch / fabric"
nvswitch_present=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -q 2>/dev/null | grep -qi "fabric"; then
  nvswitch_present=1
fi
if (( nvswitch_present )); then
  if systemctl is-active --quiet nvidia-fabricmanager 2>/dev/null; then
    ok "nvidia-fabricmanager active"
  else
    bad "nvidia-fabricmanager not active -- required on NVSwitch nodes"
    note "systemctl enable --now nvidia-fabricmanager"
  fi
  state="\$(nvidia-smi -q 2>/dev/null | grep -iA4 'fabric' | grep -i 'state' | head -1 | awk -F: '{print \$2}' | xargs)"
  status="\$(nvidia-smi -q 2>/dev/null | grep -iA4 'fabric' | grep -i 'status' | head -1 | awk -F: '{print \$2}' | xargs)"
  if [[ "\$state" == *ompleted* ]]; then
    ok "fabric state: \${state} / \${status:-?}"
  else
    bad "fabric state: \${state:-unknown} (expected Completed)"
  fi
  # IMEX only matters when NVLink crosses node boundaries (NVL rack scale).
  # On a standalone HGX node it is correctly absent, so this is a note.
  if systemctl is-active --quiet nvidia-imex 2>/dev/null; then
    note "nvidia-imex active (multi-node NVLink domain)"
  else
    note "nvidia-imex inactive -- expected on a standalone node, not a problem"
  fi
else
  note "no NVSwitch fabric reported; skipping fabricmanager checks"
fi

# ----------------------------------------------------------- infiniband -----
head_ "InfiniBand / RDMA"
if [[ -d /dev/infiniband ]] && compgen -G "/dev/infiniband/uverbs*" >/dev/null 2>&1; then
  n="\$(ls /dev/infiniband/uverbs* 2>/dev/null | wc -l)"
  ok "/dev/infiniband present (\${n} uverbs devices)"
else
  bad "/dev/infiniband missing -- IB kernel drivers (MOFED/DOCA-OFED) not loaded"
fi

if command -v ibstat >/dev/null 2>&1; then
  up="\$(ibstat 2>/dev/null | grep -c 'State: Active' || true)"
  tot="\$(ibstat -l 2>/dev/null | wc -l || echo 0)"
  if [[ "\${up:-0}" -gt 0 ]]; then
    ok "IB links active: \${up} of \${tot} HCAs"
  else
    warn "no IB link reported Active (\${tot} HCAs seen)"
  fi
else
  warn "ibstat not found -- install the OFED userspace tools to verify links"
fi

# GPUDirect RDMA. The container prints "peer memory driver not detected" even
# when it is loaded, so trust this check and not that banner.
if lsmod 2>/dev/null | grep -q '^nvidia_peermem'; then
  ok "nvidia_peermem loaded (GPUDirect RDMA)"
elif [[ -d /sys/kernel/mm/memory_peers ]]; then
  ok "peer memory support present"
else
  warn "nvidia_peermem not loaded -- multi-node RDMA will be slower"
  note "modprobe nvidia_peermem  (add to /etc/modules-load.d/ to persist)"
fi

# --------------------------------------------------- what is NOT needed -----
head_ "Host userspace (informational -- the image supplies these)"
for pair in "nvcc:CUDA toolkit" "ompi_info:OpenMPI"; do
  cmd="\${pair%%:*}"; label="\${pair#*:}"
  if command -v "\$cmd" >/dev/null 2>&1; then
    note "\${label} present on the node -- unused by containerised runs"
  fi
done
if [[ -d /opt/hpcx ]]; then
  note "host /opt/hpcx present -- unused by containerised runs; the image has its own"
fi
note "host CUDA / NCCL / HPC-X / UCX versions do not affect what runs in the container"

# ------------------------------------------------------ container check -----
if [[ -n "\$IMAGE" ]]; then
  head_ "Through the image"
  if ! docker image inspect "\$IMAGE" >/dev/null 2>&1; then
    warn "image not present on this node: \$IMAGE"
    note "docker load -i <tar>  or  docker pull \$IMAGE"
  else
    out="\$(docker run --rm --gpus all "\$IMAGE" nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | head -1)"
    if [[ "\$out" == *NVIDIA* || "\$out" == *Tesla* ]]; then
      ok "container sees GPUs: \$out"
    else
      bad "container cannot see GPUs: \$out"
    fi
    ibdev="\$(docker run --rm --gpus all \$(for d in /dev/infiniband/*; do [[ -e "\$d" ]] && printf ' --device %s' "\$d"; done) \
              "\$IMAGE" bash -c 'ibv_devinfo -l 2>/dev/null | head -1' 2>&1 | xargs)"
    if [[ "\$ibdev" =~ ^[0-9]+ ]]; then
      ok "container sees \${ibdev} HCAs with the device passthrough the launchers use"
    else
      warn "container did not enumerate IB devices (\${ibdev:-no output})"
    fi
  fi
fi

# --------------------------------------------------------------- summary ----
printf '\n\033[1m[summary]\033[0m\n'
printf '  missing: %d   warnings: %d\n\n' "\$FAIL" "\$WARN"
if [[ "\$FAIL" -eq 0 ]]; then
  echo "  Node prerequisites satisfied."
else
  echo "  Fix the MISS entries above, then re-run this check."
fi
exit \$(( FAIL > 0 ? 1 : 0 ))
REMOTE
