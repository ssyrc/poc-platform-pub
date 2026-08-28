#!/usr/bin/env bash
# scripts/lib_ssh.sh
# -----------------
# SSH options for reaching hosts that sit behind bastions.
#
# One platform can manage clusters on different networks: some hosts it reaches
# directly, others only through a chain of jump hosts. So the jump is scoped by
# host pattern rather than applied globally -- setting it for the B300 subnet
# must not break the hosts that were always reachable directly.
#
# Configured in .env:
#
#   # chain, in order, exactly as ssh -J takes it
#   MLPERF_SSH_JUMP=root@bastion1,root@bastion2
#   # which hosts it applies to; glob patterns, comma-separated.
#   # omit to apply the jump to every host.
#   MLPERF_SSH_JUMP_HOSTS=10.0.0.*,10.0.1.*
#   # anything else to pass to ssh, e.g. a key or a longer timeout
#   MLPERF_SSH_OPTS=-o ConnectTimeout=20 -i /root/.ssh/b300_key
#
# ssh takes the first value it is given for an option, and these are placed
# ahead of the callers' own flags, so MLPERF_SSH_OPTS can override
# ConnectTimeout or BatchMode rather than only adding to them.

# ssh_jump_applies <host> -- 0 when the configured jump covers this host.
ssh_jump_applies() {
  local h="$1" pat
  [[ -n "${MLPERF_SSH_JUMP:-}" ]] || return 1
  local pats="${MLPERF_SSH_JUMP_HOSTS:-}"
  [[ -n "$pats" ]] || return 0   # no patterns configured: every host
  local -a _p
  IFS=',' read -ra _p <<< "$pats"
  for pat in "${_p[@]}"; do
    pat="${pat//[[:space:]]/}"
    [[ -n "$pat" ]] || continue
    # glob, not regex -- deliberately unquoted on the right
    # shellcheck disable=SC2053
    [[ "$h" == $pat ]] && return 0
  done
  return 1
}

# ssh_opts_for <out_array_name> <host> -- fills the array with the options to
# put before ssh's other arguments. Empty when nothing is configured.
ssh_opts_for() {
  local -n __ssh_out="$1"
  local h="$2"
  __ssh_out=()

  if ssh_jump_applies "$h"; then
    __ssh_out+=(-J "${MLPERF_SSH_JUMP}")
  fi
  if [[ -n "${MLPERF_SSH_OPTS:-}" ]]; then
    local -a _extra
    read -ra _extra <<< "${MLPERF_SSH_OPTS}"
    __ssh_out+=(${_extra[@]+"${_extra[@]}"})
  fi
}

# Print the resolved routing for a host, once, for the run log.
ssh_describe_route() {
  local h="$1"
  if ssh_jump_applies "$h"; then
    echo "[INFO] ssh ${h} via ${MLPERF_SSH_JUMP}"
  fi
}
