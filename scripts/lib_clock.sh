#!/usr/bin/env bash
# scripts/lib_clock.sh
# -------------------
# Refuse to start a distributed job on hosts whose clocks disagree.
#
# Reported, never enforced. Skew was measured at 65s on a cluster whose
# all-reduce completes normally, so it is not on its own a reason to refuse a
# run -- blocking on it would stop configurations that work today.
#
# It is still worth printing. torchrun's c10d rendezvous has each node stamp
# its own heartbeats with its own wall clock and every other node judge those
# stamps against its own, so large skew is a plausible contributor to a node
# being dropped even though it is demonstrably not sufficient to cause it.
#
# Usage:
#   source lib_clock.sh
#   clock_check_hosts host1 host2 ...     # non-zero when skew is fatal
#
# Requires cm_remote_bash from common.sh.

# Skew worth mentioning. Nothing here fails a run.
CLOCK_SKEW_WARN="${CLOCK_SKEW_WARN:-5}"

# clock_check_hosts <host>... -- always returns 0.
clock_check_hosts() {
  local hosts=("$@")
  [[ "${#hosts[@]}" -ge 2 ]] || return 0

  local tmp; tmp="$(mktemp -d)"
  local i h
  for i in "${!hosts[@]}"; do
    ( cm_remote_bash "${hosts[$i]}" <<<'date +%s' 2>/dev/null | tail -1 | tr -dc '0-9' > "${tmp}/${i}" ) &
  done
  wait

  local min="" max="" min_h="" max_h="" v missing=0
  for i in "${!hosts[@]}"; do
    v="$(cat "${tmp}/${i}" 2>/dev/null)"
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then missing=1; continue; fi
    if [[ -z "$min" || "$v" -lt "$min" ]]; then min="$v"; min_h="${hosts[$i]}"; fi
    if [[ -z "$max" || "$v" -gt "$max" ]]; then max="$v"; max_h="${hosts[$i]}"; fi
  done
  rm -rf "$tmp"

  [[ -z "$min" ]] && return 0
  local skew=$(( max - min ))
  if (( skew >= CLOCK_SKEW_WARN )); then
    echo "[WARN] clocks differ by ${skew}s across hosts (${min_h} .. ${max_h})" >&2
    echo "[WARN] not fatal -- runs succeed at this skew -- but worth fixing:" >&2
    echo "[WARN]   chronyc makestep   on the hosts that are out" >&2
  else
    echo "[INFO] clocks agree across ${#hosts[@]} host(s) (max skew ${skew}s)"
  fi
  return 0
}
