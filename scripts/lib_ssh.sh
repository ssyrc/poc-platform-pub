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
# A run targets one network, so the network is the thing chosen -- in the UI or
# on the command line -- and the chain behind it is configured once, here:
#
#   MLPERF_NETWORK=h_hpc                # which network this run targets
#   MLPERF_NET_S_SC_JUMP=              # empty: reached directly
#   MLPERF_NET_H_HPC_JUMP=root@bastion1,root@bastion2
#   MLPERF_NET_H_HPC_SSH_OPTS=-o ConnectTimeout=20
#
# The id is upper-cased and non-alphanumerics become underscores, so a network
# id of "s_ddz" reads MLPERF_NET_S_DDZ_JUMP.
#
# Selecting a network applies its chain to every host in the run, which is what
# a network means. The lower-level pair stays available for the case a network
# id does not cover -- one platform reaching two networks in a single run:
#
#   MLPERF_SSH_JUMP=root@a,root@b
#   MLPERF_SSH_JUMP_HOSTS=10.0.0.*,10.0.1.*   # patterns; omit for all
#
# MLPERF_SSH_JUMP wins over the network lookup, so it can override a selection.
#
# ssh takes the first value it is given for an option, and these are placed
# ahead of the callers' own flags, so MLPERF_SSH_OPTS can override
# ConnectTimeout or BatchMode rather than only adding to them.

# _ssh_net_var <network-id> <suffix> -- the .env variable name for a network.
_ssh_net_var() {
  local id="${1^^}"
  printf 'MLPERF_NET_%s_%s' "${id//[^A-Z0-9]/_}" "$2"
}

# ssh_jump_chain -- the chain in effect, empty when hosts are reached directly.
# An explicit MLPERF_SSH_JUMP overrides the selected network.
ssh_jump_chain() {
  if [[ -n "${MLPERF_SSH_JUMP:-}" ]]; then
    printf '%s' "${MLPERF_SSH_JUMP}"
    return 0
  fi
  local v
  if [[ -n "${MLPERF_NETWORK:-}" ]]; then
    v="$(_ssh_net_var "${MLPERF_NETWORK}" JUMP)"
    printf '%s' "${!v:-}"
  fi
}

# ssh_jump_applies <host> -- 0 when the chain in effect covers this host.
ssh_jump_applies() {
  local h="$1" pat
  [[ -n "$(ssh_jump_chain)" ]] || return 1
  # A network selection covers the whole run; patterns only scope the
  # lower-level MLPERF_SSH_JUMP.
  [[ -n "${MLPERF_SSH_JUMP:-}" ]] || return 0
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

  local chain; chain="$(ssh_jump_chain)"
  if [[ -n "$chain" ]] && ssh_jump_applies "$h"; then
    __ssh_out+=(-J "$chain")
  fi

  # Per-network options first, then the global ones; ssh keeps the first value
  # it sees for an option, so a network can pin something the global set would
  # otherwise decide.
  local netopts_var netopts="" o
  if [[ -n "${MLPERF_NETWORK:-}" ]]; then
    netopts_var="$(_ssh_net_var "${MLPERF_NETWORK}" SSH_OPTS)"
    netopts="${!netopts_var:-}"
  fi
  for o in "$netopts" "${MLPERF_SSH_OPTS:-}"; do
    [[ -n "$o" ]] || continue
    local -a _extra
    read -ra _extra <<< "$o"
    __ssh_out+=(${_extra[@]+"${_extra[@]}"})
  done
}

# Print the resolved routing for a host, once, for the run log.
ssh_describe_route() {
  local h="$1"
  local chain; chain="$(ssh_jump_chain)"
  if [[ -n "$chain" ]] && ssh_jump_applies "$h"; then
    echo "[INFO] ssh ${h} via ${chain}${MLPERF_NETWORK:+ (network: ${MLPERF_NETWORK})}"
  else
    echo "[INFO] ssh ${h} direct${MLPERF_NETWORK:+ (network: ${MLPERF_NETWORK})}"
  fi
}
