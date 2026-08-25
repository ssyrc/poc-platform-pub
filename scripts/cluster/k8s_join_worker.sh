#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/cluster/k8s_join_worker.sh
# ----------------------------------
# Join a worker node to THIS control-plane (the host running the platform
# backend, or wherever kubeadm/kubectl is configured).
#
# Flow:
#   1) On the master, mint a fresh join command:
#        kubeadm token create --print-join-command
#   2) SSH into the target worker and run that join command with sudo.
#   3) Verify the node appears via `kubectl get nodes`.
#
# The target must be reachable over passwordless SSH from the master and have
# kubeadm/kubelet/containerd already installed (Warewulf image should bake
# these in).  Run this script as a user that can run kubeadm on the master and
# sudo on the worker.
#
# Usage:
#   k8s_join_worker.sh --target 10.0.0.21 [--ssh-user root] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

TARGET=""
SSH_USER="${K8S_SSH_USER:-root}"
KUBECTL="${KUBECTL_BIN:-kubectl}"
KUBEADM="${KUBEADM_BIN:-kubeadm}"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   TARGET="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN="true"; shift ;;
    -h|--help)  echo "usage: $0 --target <host|ip> [--ssh-user user] [--dry-run]"; exit 0 ;;
    *) cm_die "unknown argument: $1" ;;
  esac
done

[[ -n "$TARGET" ]] || cm_die "--target (worker hostname or IP) is required"
cm_validate_host "$TARGET"

cm_phase preflight
command -v "$KUBEADM"  >/dev/null 2>&1 || cm_die "kubeadm not found on master (set KUBEADM_BIN)"
command -v "$KUBECTL"  >/dev/null 2>&1 || cm_warn "kubectl not found on master; will skip post-join verification"
command -v ssh         >/dev/null 2>&1 || cm_die "ssh not found on master"

cm_inf "target=${TARGET} ssh_user=${SSH_USER}"

cm_phase mint_token
# kubeadm prints e.g.:
#   kubeadm join 10.0.0.1:6443 --token abc.def --discovery-token-ca-cert-hash sha256:...
if [[ "$DRY_RUN" == "true" ]]; then
  JOIN_CMD="kubeadm join 203.0.113.1:6443 --token dryrun.0000000000000000 --discovery-token-ca-cert-hash sha256:dryrun"
  cm_inf "[dry-run] using placeholder join command"
else
  JOIN_CMD="$("$KUBEADM" token create --print-join-command 2>/dev/null)" \
    || cm_die "failed to create kubeadm join token on master"
fi
[[ "$JOIN_CMD" == kubeadm\ join* ]] || cm_die "unexpected join command from kubeadm: ${JOIN_CMD:0:80}"
cm_inf "join command minted (token redacted)"

cm_phase join
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
REMOTE="sudo ${JOIN_CMD} --cri-socket unix:///run/containerd/containerd.sock"

if [[ "$DRY_RUN" == "true" ]]; then
  cm_inf "[dry-run] would run on ${TARGET}: ${REMOTE//--token */--token <redacted>}"
  RC=0
else
  cm_inf "running kubeadm join on ${TARGET} over ssh ..."
  set +e
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET}" "$REMOTE" 2>&1
  RC=$?
  set -e
fi

cm_phase verify
NODE_FOUND="unknown"
if [[ "$RC" == "0" && "$DRY_RUN" != "true" ]] && command -v "$KUBECTL" >/dev/null 2>&1; then
  # Worker registers under its own hostname; give kubelet a moment.
  for _ in 1 2 3 4 5 6; do
    if "$KUBECTL" get nodes -o name 2>/dev/null | grep -qiE "/(${TARGET%%.*}|${TARGET})$"; then
      NODE_FOUND="yes"; break
    fi
    sleep 5
  done
  [[ "$NODE_FOUND" == "yes" ]] || NODE_FOUND="not-yet-visible"
fi

cm_phase done
cm_emit_json_line K8S_JOIN_RESULT_JSON \
  status "$([[ "$RC" == "0" ]] && echo success || echo failed)" \
  target "$TARGET" \
  exit_code "$RC" \
  node_found "$NODE_FOUND"

exit "$RC"
