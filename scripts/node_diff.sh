#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/node_diff.sh
# -------------------
# Collect the same facts from every node and show only what differs.
#
# When most of a cluster works and a few nodes do not, the question is not
# "what does this node look like" -- node_check.sh answers that -- but "what is
# different about the ones that fail". Printing eight full reports and reading
# them side by side is the slow way to find out.
#
# Facts that agree everywhere are collapsed to one line. Facts that disagree
# are broken out by value, with the hosts holding each, so an odd node out is
# the thing the eye lands on.
#
# Usage:
#   node_diff.sh --hosts a,b,c
#   node_diff.sh --hosts-file hostfile
#
# Read-only: it changes nothing on any node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib_hosts.sh"

die() { echo "[ERROR] $*" >&2; exit 1; }

HOST_SPECS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--hosts) HOST_SPECS+=("lit:${2:?--hosts needs a value}"); shift 2 ;;
    --hosts-file)   HOST_SPECS+=("file:${2:?--hosts-file needs a value}"); shift 2 ;;
    -h|--help)      sed -n '4,22p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
if [[ "${#HOST_SPECS[@]}" -eq 0 && -n "${MLPERF_HOSTFILE:-}" ]]; then
  HOST_SPECS+=("file:${MLPERF_HOSTFILE}")
fi
[[ "${#HOST_SPECS[@]}" -gt 0 ]] || die "--hosts or --hosts-file is required"
hosts_expand HOSTS "${HOST_SPECS[@]}" || exit 64

# One probe, emitting key=value. Anything that varies legitimately per host
# (addresses, serial numbers) is deliberately left out; this is for finding
# configuration drift, not inventory.
PROBE=$(cat <<'FACTS'
set -uo pipefail
emit() { printf '%s=%s\n' "$1" "${2:-<none>}"; }
trim() { tr -d '\r' | sed 's/^ *//;s/ *$//' | head -1; }

emit kernel            "$(uname -r)"
emit os                "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

if command -v nvidia-smi >/dev/null 2>&1; then
  emit driver          "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | trim)"
  emit gpu_count       "$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)"
  emit gpu_model       "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | trim)"
  emit compute_cap     "$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | trim)"
  emit ecc_errors      "$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null | paste -sd, - )"
  emit gpu_persistence "$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | sort -u | paste -sd, -)"
  emit gpu_busy        "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)"
  emit fabric_state    "$(nvidia-smi -q 2>/dev/null | grep -iA4 'fabric' | grep -i 'state' | trim | awk -F: '{print $2}' | trim)"
else
  emit driver "<no nvidia-smi>"
fi

emit fabricmanager     "$(systemctl is-active nvidia-fabricmanager 2>/dev/null)"
emit imex              "$(systemctl is-active nvidia-imex 2>/dev/null)"
emit peermem           "$(lsmod 2>/dev/null | grep -qE '^nvidia_peermem' && echo loaded || echo not-loaded)"
emit nv_uvm            "$(lsmod 2>/dev/null | grep -qE '^nvidia_uvm' && echo loaded || echo not-loaded)"

emit ofed              "$(ofed_info -s 2>/dev/null | trim)"
emit ib_devices        "$(ls /dev/infiniband/uverbs* 2>/dev/null | wc -l)"
if command -v ibstat >/dev/null 2>&1; then
  emit ib_active       "$(ibstat 2>/dev/null | grep -c 'State: Active')"
  emit ib_rate         "$(ibstat 2>/dev/null | grep -oE 'Rate: [0-9]+' | sort -u | paste -sd, -)"
fi

# ACS redirect bits are what break GPUDirect RDMA.
if command -v setpci >/dev/null 2>&1 && command -v lspci >/dev/null 2>&1; then
  n=0
  while read -r bdf _; do
    v="$(setpci -s "$bdf" ECAP_ACS+0x6.w 2>/dev/null)" || continue
    [[ -n "$v" ]] && (( 16#$v & 0x0C )) && n=$((n+1))
  done < <(lspci -D 2>/dev/null)
  emit acs_redirecting "$n"
fi

emit docker            "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d , )"
emit docker_ok         "$(docker info >/dev/null 2>&1 && echo yes || echo no)"
emit nvidia_ctk        "$(command -v nvidia-ctk >/dev/null 2>&1 && echo yes || echo no)"
emit docker_root_free  "$(df -h "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" 2>/dev/null | awk 'NR==2{print $4}')"

emit memlock           "$(ulimit -l 2>/dev/null)"
emit cpus              "$(nproc 2>/dev/null)"
emit mem_gb            "$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)"
# Clock skew breaks distributed handshakes in ways that look like network faults.
emit epoch             "$(date +%s)"
FACTS
)

echo
echo "Collecting from ${#HOSTS[@]} host(s) ..."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for i in "${!HOSTS[@]}"; do
  ( printf '%s' "$PROBE" | cm_remote_bash "${HOSTS[$i]}" > "${TMP}/${i}" 2>/dev/null || true ) &
done
wait

# Keys in the order the probe emits them, taken from whichever host answered.
mapfile -t KEYS < <(for i in "${!HOSTS[@]}"; do
  [[ -s "${TMP}/${i}" ]] && { sed 's/=.*//' "${TMP}/${i}"; break; }
done)
[[ "${#KEYS[@]}" -gt 0 ]] || die "no host returned any facts"

value_of() { sed -n "s/^$2=//p" "${TMP}/$1" | head -1; }

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
same=0; diff=0

echo
printf '%sDIFFERENCES%s\n' "$BOLD" "$RESET"
echo "===================================================================="
for k in "${KEYS[@]}"; do
  declare -A groups=()
  for i in "${!HOSTS[@]}"; do
    v="$(value_of "$i" "$k")"; [[ -n "$v" ]] || v="<missing>"
    groups["$v"]="${groups["$v"]:-}${groups["$v"]:+ }${HOSTS[$i]}"
  done
  if [[ "${#groups[@]}" -le 1 ]]; then
    same=$((same+1)); unset groups; continue
  fi
  # epoch never matches exactly; report the spread instead of listing it.
  if [[ "$k" == "epoch" ]]; then
    mn=""; mx=""
    for i in "${!HOSTS[@]}"; do
      v="$(value_of "$i" epoch)"; [[ "$v" =~ ^[0-9]+$ ]] || continue
      [[ -z "$mn" || "$v" -lt "$mn" ]] && mn="$v"
      [[ -z "$mx" || "$v" -gt "$mx" ]] && mx="$v"
    done
    if [[ -n "$mn" && $(( mx - mn )) -gt 5 ]]; then
      printf '  %s%-18s%s clock skew %ss across hosts\n' "$RED" "clock" "$RESET" "$(( mx - mn ))"
      diff=$((diff+1))
    else
      same=$((same+1))
    fi
    unset groups; continue
  fi
  diff=$((diff+1))
  printf '  %s%-18s%s\n' "$RED" "$k" "$RESET"
  for v in "${!groups[@]}"; do
    printf '      %-28s %s%s%s\n' "$v" "$DIM" "${groups[$v]}" "$RESET"
  done
  unset groups
done
[[ "$diff" -eq 0 ]] && printf '  %snone -- every collected fact agrees across all hosts%s\n' "$GREEN" "$RESET"
echo "===================================================================="
printf '  %d fact(s) differ, %d agree\n\n' "$diff" "$same"
