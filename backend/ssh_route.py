"""SSH routing for hosts that sit behind bastions.

The launchers reach a node through the jump chain configured in .env, resolved
by scripts/lib_ssh.sh. Everything the backend does over ssh -- GPU type
detection, live GPU/NIC sampling, topology -- used to ssh straight at the host,
so a node the benchmark could reach was invisible to the monitor. This mirrors
lib_ssh.sh so both sides route the same way from the same configuration.

start_platform.sh sources .env with `set -a`, so the variables below are in the
backend's own environment:

    MLPERF_NET_<ID>_JUMP        chain for the network with that id
    MLPERF_NET_<ID>_SSH_OPTS    extra ssh flags for that network
    MLPERF_SSH_JUMP             lower-level override, wins over the network
    MLPERF_SSH_JUMP_HOSTS       glob patterns scoping MLPERF_SSH_JUMP
    MLPERF_SSH_OPTS             extra ssh flags for every host

Which network a host belongs to is a per-run choice made in the UI, not a
property of the process, so it is remembered per host as runs and detections
name it. MLPERF_NETWORK in .env is the fallback for a host nothing has claimed.
"""

from __future__ import annotations

import fnmatch
import os
import re
import shlex
from typing import Dict, List, Optional

# host -> network id, as named by the run that most recently used the host.
_HOST_NETWORK: Dict[str, str] = {}


def _net_var(network: str, suffix: str) -> str:
    """The .env variable name for a network id, as lib_ssh.sh derives it."""
    ident = re.sub(r"[^A-Z0-9]", "_", network.upper())
    return f"MLPERF_NET_{ident}_{suffix}"


def remember_host_network(host: str, network: Optional[str]) -> None:
    host = (host or "").strip()
    network = (network or "").strip()
    if host and network:
        _HOST_NETWORK[host] = network


def remember_hosts_network(hosts, network: Optional[str]) -> None:
    for h in hosts or []:
        remember_host_network(h, network)


def network_for(host: str, network: Optional[str] = None) -> str:
    """The network id in effect for a host: explicit, then remembered, then .env."""
    if network:
        return network.strip()
    return _HOST_NETWORK.get((host or "").strip()) or os.environ.get("MLPERF_NETWORK", "").strip()


def jump_chain(host: str, network: Optional[str] = None) -> str:
    """The chain in effect, empty when the host is reached directly."""
    explicit = os.environ.get("MLPERF_SSH_JUMP", "").strip()
    if explicit:
        return explicit
    net = network_for(host, network)
    if not net:
        return ""
    return os.environ.get(_net_var(net, "JUMP"), "").strip()


def _jump_applies(host: str, chain: str) -> bool:
    if not chain:
        return False
    # A network selection covers the whole run; patterns only scope the
    # lower-level MLPERF_SSH_JUMP.
    if not os.environ.get("MLPERF_SSH_JUMP", "").strip():
        return True
    pats = os.environ.get("MLPERF_SSH_JUMP_HOSTS", "").strip()
    if not pats:
        return True
    for pat in pats.split(","):
        pat = "".join(pat.split())
        if pat and fnmatch.fnmatch(host, pat):
            return True
    return False


def ssh_options(host: str, network: Optional[str] = None) -> List[str]:
    """ssh flags for reaching this host, to be placed before the caller's own.

    ssh keeps the first value it is given for an option, so a network's
    MLPERF_NET_<ID>_SSH_OPTS can pin something the global set would decide, and
    both can override a caller's ConnectTimeout rather than only adding to it.
    """
    opts: List[str] = []
    chain = jump_chain(host, network)
    if _jump_applies(host, chain):
        opts += ["-J", chain]

    net = network_for(host, network)
    extras = [os.environ.get(_net_var(net, "SSH_OPTS"), "") if net else "",
              os.environ.get("MLPERF_SSH_OPTS", "")]
    for extra in extras:
        if extra.strip():
            opts += shlex.split(extra)
    return opts


def ssh_cmd(host: str, remote: str, *, network: Optional[str] = None,
            connect_timeout: int = 6,
            strict_host_key_checking: str = "accept-new") -> List[str]:
    """A full ssh argv for running one command on a host, routed per .env."""
    return [
        "ssh",
        *ssh_options(host, network),
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={connect_timeout}",
        "-o", f"StrictHostKeyChecking={strict_host_key_checking}",
        host,
        remote,
    ]


def describe(host: str, network: Optional[str] = None) -> str:
    """One line naming the route, for logs -- same wording as lib_ssh.sh."""
    net = network_for(host, network)
    suffix = f" (network: {net})" if net else ""
    chain = jump_chain(host, network)
    if _jump_applies(host, chain):
        return f"ssh {host} via {chain}{suffix}"
    return f"ssh {host} direct{suffix}"
