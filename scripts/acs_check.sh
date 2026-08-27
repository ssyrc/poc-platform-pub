#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/acs_check.sh
# -------------------
# Report PCIe ACS state on a node, and print the commands that would turn it
# off. Read-only: it never changes PCIe configuration itself.
#
# Why this matters for multi-node training. ACS forces peer-to-peer PCIe
# transactions between devices under the same switch to be redirected up to
# the root complex instead of going device to device. GPUDirect RDMA depends
# on exactly that direct path: the HCA DMAs into the GPU's BAR using a bus
# address handed to it at memory-registration time. Redirected upstream and
# put through the IOMMU, that address no longer resolves to GPU memory, and
# the HCA completes the send with
#
#   status=4  (IBV_WC_LOC_PROT_ERR)  -- local protection error
#
# It shows up only on the inter-node path. GPU-to-GPU inside a node goes over
# NVLink and never touches PCIe peer-to-peer or the NIC; ib_write_bw with its
# default host memory is not peer-to-peer either; and TCP staging copies
# through host memory. All of those keep working while IB fails.
#
# Usage:
#   acs_check.sh                     # this machine
#   acs_check.sh --host 192.0.2.41   # a remote node over ssh
#
# Exit: 0 if no ACS redirection is active, 1 if any was found.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST="localhost"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    -h|--help) sed -n '4,29p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid host: $HOST"

cm_remote_bash "$HOST" <<'REMOTE'
set -uo pipefail

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

printf '\n%sACS check: %s%s\n' "$BOLD" "$(hostname -f 2>/dev/null || hostname)" "$RESET"

command -v setpci >/dev/null 2>&1 || { echo "  setpci not found -- install pciutils" >&2; exit 2; }
command -v lspci  >/dev/null 2>&1 || { echo "  lspci not found -- install pciutils" >&2; exit 2; }
[[ "$(id -u)" == "0" ]] || printf '  %s(not root -- reads may fail)%s\n' "$DIM" "$RESET"

# ACS Control register sits at +0x06 in the ACS extended capability. Bits:
#   0 SrcValid  1 TransBlk  2 P2P Req Redirect  3 P2P Cmpl Redirect
#   4 Upstream Forwarding  5 P2P Egress Control  6 Direct Translated P2P
# Bits 2 and 3 are the ones that break GPUDirect RDMA; the rest are reported
# for completeness because the usual remedy clears the register outright.
REDIRECT_MASK=$((0x0C))

ACTIVE=0
CHECKED=0
FIXES=()

printf '\n  %-14s %-6s %s\n' "BDF" "ACSCtl" "device"
printf '  %s\n' "------------------------------------------------------------------"

while read -r bdf rest; do
  val="$(setpci -s "$bdf" ECAP_ACS+0x6.w 2>/dev/null)" || continue
  [[ -n "$val" ]] || continue
  CHECKED=$((CHECKED+1))
  dec=$((16#$val))
  name="$(lspci -s "$bdf" 2>/dev/null | cut -d' ' -f2- | cut -c1-46)"
  if (( dec & REDIRECT_MASK )); then
    printf '  %s%-14s %-6s %s%s\n' "$RED" "$bdf" "$val" "$name" "$RESET"
    ACTIVE=$((ACTIVE+1))
    FIXES+=("setpci -s ${bdf} ECAP_ACS+0x6.w=0000")
  elif (( dec != 0 )); then
    printf '  %s%-14s %-6s %s%s\n' "$YELLOW" "$bdf" "$val" "$name" "$RESET"
  else
    printf '  %s%-14s %-6s %s%s\n' "$GREEN" "$bdf" "$val" "$name" "$RESET"
  fi
done < <(lspci -D 2>/dev/null)

printf '\n  checked: %d with an ACS capability\n' "$CHECKED"

if (( ACTIVE == 0 )); then
  printf '  %sno P2P redirection active -- ACS is not blocking GPUDirect RDMA%s\n\n' "$GREEN" "$RESET"
  exit 0
fi

printf '  %s%d bridge(s) redirecting peer-to-peer traffic%s\n\n' "$RED" "$ACTIVE" "$RESET"
printf '%s  To clear it until the next reboot (run as root):%s\n\n' "$BOLD" "$RESET"
printf '    %s\n' "${FIXES[@]}"
cat <<'EOS'

  Read this before running it:

    - It does not persist. A reboot restores ACS, so the durable fix is the
      BIOS setting (often "ACS Enable" or under the IOMMU section), or a
      systemd unit that reapplies it at boot.
    - It weakens PCIe isolation between devices. That matters if this host
      passes devices through to VMs or otherwise relies on IOMMU groups for
      separation. On a dedicated bare-metal training node it is the normal
      configuration.
    - Re-run the NCCL probe afterwards to confirm the IB path recovers before
      making the change permanent.
EOS
exit 1
REMOTE
