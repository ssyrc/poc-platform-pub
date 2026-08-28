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
  local __ssh_h="$1" __ssh_pat
  [[ -n "$(ssh_jump_chain)" ]] || return 1
  # A network selection covers the whole run; patterns only scope the
  # lower-level MLPERF_SSH_JUMP.
  [[ -n "${MLPERF_SSH_JUMP:-}" ]] || return 0
  local __ssh_pats="${MLPERF_SSH_JUMP_HOSTS:-}"
  [[ -n "$__ssh_pats" ]] || return 0   # no patterns configured: every host
  local -a __ssh_p
  IFS=',' read -ra __ssh_p <<< "$__ssh_pats"
  for __ssh_pat in "${__ssh_p[@]}"; do
    __ssh_pat="${__ssh_pat//[[:space:]]/}"
    [[ -n "$__ssh_pat" ]] || continue
    # glob, not regex -- deliberately unquoted on the right
    # shellcheck disable=SC2053
    [[ "$__ssh_h" == $__ssh_pat ]] && return 0
  done
  return 1
}

# ssh_opts_for <out_array_name> <host> -- fills the array with the options to
# put before ssh's other arguments. Empty when nothing is configured.
# Every local here is __ssh_-prefixed on purpose: __ssh_out is a nameref to the
# caller's array, and a local sharing that array's name would shadow it, so the
# appends after the shadowing declaration would silently go nowhere.
ssh_opts_for() {
  local -n __ssh_out="$1"
  local __ssh_h="$2"
  __ssh_out=()

  local __ssh_chain; __ssh_chain="$(ssh_jump_chain)"
  if [[ -n "$__ssh_chain" ]] && ssh_jump_applies "$__ssh_h"; then
    __ssh_out+=(-J "$__ssh_chain")
  fi

  # Per-network options first, then the global ones; ssh keeps the first value
  # it sees for an option, so a network can pin something the global set would
  # otherwise decide.
  local __ssh_netopts_var __ssh_netopts="" __ssh_o
  if [[ -n "${MLPERF_NETWORK:-}" ]]; then
    __ssh_netopts_var="$(_ssh_net_var "${MLPERF_NETWORK}" SSH_OPTS)"
    __ssh_netopts="${!__ssh_netopts_var:-}"
  fi
  for __ssh_o in "$__ssh_netopts" "${MLPERF_SSH_OPTS:-}"; do
    [[ -n "$__ssh_o" ]] || continue
    local -a __ssh_extra
    read -ra __ssh_extra <<< "$__ssh_o"
    __ssh_out+=(${__ssh_extra[@]+"${__ssh_extra[@]}"})
  done
}

# Print the resolved routing for a host, once, for the run log.
ssh_describe_route() {
  local __ssh_h="$1"
  local __ssh_chain; __ssh_chain="$(ssh_jump_chain)"
  if [[ -n "$__ssh_chain" ]] && ssh_jump_applies "$__ssh_h"; then
    echo "[INFO] ssh ${__ssh_h} via ${__ssh_chain}${MLPERF_NETWORK:+ (network: ${MLPERF_NETWORK})}"
  else
    echo "[INFO] ssh ${__ssh_h} direct${MLPERF_NETWORK:+ (network: ${MLPERF_NETWORK})}"
  fi
}
