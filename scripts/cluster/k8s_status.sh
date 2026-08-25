#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/cluster/k8s_status.sh
# -----------------------------
# Human-readable control-plane + node summary for the K8s tab.  The backend
# normally reads kubectl JSON directly (see backend/cluster.py), but this
# script is handy for manual checks and as a fallback.
#
# Usage: k8s_status.sh

KUBECTL="${KUBECTL_BIN:-kubectl}"

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  echo "[ERROR] kubectl not found (set KUBECTL_BIN)" >&2
  exit 127
fi

echo "[PHASE] control-plane"
"$KUBECTL" version -o json 2>/dev/null \
  | grep -E '"gitVersion"' | head -2 || echo "[WARN] could not read version"

echo "[PHASE] healthz"
"$KUBECTL" get --raw /healthz 2>/dev/null || echo "[WARN] healthz unavailable"
echo

echo "[PHASE] nodes"
"$KUBECTL" get nodes -o wide 2>/dev/null || echo "[WARN] could not list nodes"
