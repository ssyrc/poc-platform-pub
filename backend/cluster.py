"""
cluster.py
----------
Backend support for the "Test Cluster Management" tab.

Two concerns live here:

  1) OS provisioning (Warewulf v4.6.5)
     The user runs a Warewulf-based node-management API on a separate host
     (configured by ``WW_API_BASE``).  The browser cannot call it directly
     (CORS + mixed-content + it may live on an isolated provisioning network),
     so the platform proxies a small, well-defined set of endpoints through
     FastAPI.  Everything is thin pass-through: we never invent semantics, we
     only forward the request and return the upstream JSON/text + status.

     Known upstream surface (configurable via env, see WW_* below):
         GET  /api/nodes                         list nodes
         POST /api/nodes                         add node (fallback shape)
         POST /api/nodes/{node_id}               add node (preferred shape)
         GET  /api/nodes/{node_id}               node detail
         POST /api/nodes/{node_id}/power         power action body {"action": "on|off|cycle|reset"}
         POST /api/nodes/{node_id}/provision     (re)provision / rebuild overlay

  2) Kubernetes cluster (k8s)
     The master node is wherever this backend runs (or wherever kubectl is
     configured to point).  We shell out to ``kubectl`` for status / node
     listing, and to ``scripts/cluster/k8s_join_worker.sh`` to join a new
     worker.  All of these are best-effort: if kubectl is missing we return a
     structured "unavailable" payload instead of raising, so the UI degrades
     gracefully instead of throwing 500s.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
import shutil
import base64
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

log = logging.getLogger("cluster")


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Warewulf node-management API. Site-specific endpoints belong in .env.
WW_API_BASE = os.environ.get("WW_API_BASE", "http://127.0.0.1:8897").rstrip("/")
WW_API_PREFIX = os.environ.get("WW_API_PREFIX", "/api").rstrip("/")
WW_TIMEOUT = float(os.environ.get("WW_API_TIMEOUT", "12"))
WW_TOKEN = os.environ.get("WW_API_TOKEN", "")  # optional bearer token
WW_AUTH_HEADER = os.environ.get("WW_AUTH_HEADER", "")  # optional raw Authorization header
WW_BASIC_USER = os.environ.get("WW_BASIC_USER", "")
WW_BASIC_PASSWORD = os.environ.get("WW_BASIC_PASSWORD", "")

# Warewulf manager host. Full-form node additions run `wwctl node add` here via SSH.
WW_MANAGER_HOST = os.environ.get("WW_MANAGER_HOST", os.environ.get("K8S_MASTER_NODE", "localhost"))
WW_MANAGER_SSH_USER = os.environ.get("WW_MANAGER_SSH_USER", os.environ.get("K8S_SSH_USER", "root"))
WWCTL_BIN = os.environ.get("WWCTL_BIN", "wwctl")
WW_NODE_SSH_USER = os.environ.get("WW_NODE_SSH_USER", os.environ.get("K8S_SSH_USER", "root"))

POWER_ACTIONS = ("on", "off", "cycle", "reset")

# kubectl + join script
KUBECTL = os.environ.get("KUBECTL_BIN", "kubectl")
# Control-plane node this dashboard monitors by default.
K8S_MASTER_NODE = os.environ.get("K8S_MASTER_NODE", "localhost")
K8S_SSH_USER = os.environ.get("K8S_SSH_USER", "root")
K8S_USE_SSH = os.environ.get("K8S_USE_SSH", "auto")  # auto|1|0
K8S_KUBECONFIG = os.environ.get("K8S_KUBECONFIG", "/etc/kubernetes/admin.conf")
K8S_REMOTE_SHELL = os.environ.get("K8S_REMOTE_SHELL", "bash")
# Default llm-d namespace (quickstart deploys into llm-d-quickstart).
LLMD_NAMESPACE = os.environ.get("LLMD_NAMESPACE", "llm-d-quickstart")
SCRIPTS_DIR = os.environ.get(
    "MLPERF_SCRIPTS_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")),
)
K8S_JOIN_SCRIPT = os.path.join(SCRIPTS_DIR, "cluster", "k8s_join_worker.sh")
K8S_STATUS_SCRIPT = os.path.join(SCRIPTS_DIR, "cluster", "k8s_status.sh")


# ---------------------------------------------------------------------------
# Warewulf proxy (stdlib urllib, run off the event loop via to_thread)
# ---------------------------------------------------------------------------


def _ww_url(path: str, query: Optional[Dict[str, Any]] = None) -> str:
    path = "/" + path.lstrip("/")
    url = f"{WW_API_BASE}{WW_API_PREFIX}{path}"
    if query:
        clean = {k: v for k, v in query.items() if v not in (None, "")}
        if clean:
            url = f"{url}?{urllib.parse.urlencode(clean)}"
    return url


def _ww_request_blocking(
    method: str,
    path: str,
    query: Optional[Dict[str, Any]] = None,
    body: Optional[Dict[str, Any]] = None,
) -> Tuple[int, Any]:
    url = _ww_url(path, query)
    data = None
    headers = {"Accept": "application/json"}
    if WW_AUTH_HEADER:
        headers["Authorization"] = WW_AUTH_HEADER
    elif WW_TOKEN:
        headers["Authorization"] = f"Bearer {WW_TOKEN}"
    elif WW_BASIC_USER:
        raw_basic = f"{WW_BASIC_USER}:{WW_BASIC_PASSWORD}".encode("utf-8")
        headers["Authorization"] = "Basic " + base64.b64encode(raw_basic).decode("ascii")
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=WW_TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            status = resp.getcode() or 200
            return status, _maybe_json(raw)
    except urllib.error.HTTPError as e:
        raw = ""
        try:
            raw = e.read().decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
        payload = _maybe_json(raw)
        if not isinstance(payload, dict):
            payload = {"raw": payload}
        payload.setdefault("error", "warewulf_http_error")
        payload.setdefault("status", e.code)
        payload.setdefault("url", url)
        if e.code == 401:
            payload.setdefault("detail", "HTTP 401 Unauthorized. Set WW_API_TOKEN, WW_AUTH_HEADER, or WW_BASIC_USER/WW_BASIC_PASSWORD for this Warewulf API.")
        return e.code, payload
    except urllib.error.URLError as e:
        return 502, {"error": "warewulf_unreachable", "detail": str(e.reason), "url": url}
    except Exception as e:  # noqa: BLE001
        return 502, {"error": "warewulf_request_failed", "detail": str(e), "url": url}


def _maybe_json(raw: str) -> Any:
    raw = raw.strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw}


async def ww_request(
    method: str,
    path: str,
    query: Optional[Dict[str, Any]] = None,
    body: Optional[Dict[str, Any]] = None,
) -> Tuple[int, Any]:
    return await asyncio.to_thread(_ww_request_blocking, method, path, query, body)


async def ww_list_nodes() -> Tuple[int, Any]:
    # User's Warewulf API exposes /api/nodes/ with a trailing slash.
    # Try the exact form first, then fall back to the no-slash variant.
    status, payload = await ww_request("GET", "/nodes/")
    if status in (404, 405):
        status, payload = await ww_request("GET", "/nodes")
    return status, payload


async def ww_node_detail(node_id: str) -> Tuple[int, Any]:
    return await ww_request("GET", f"/nodes/{urllib.parse.quote(node_id)}")


async def ww_add_node(hostname: str) -> Tuple[int, Any]:
    """Add a Warewulf node through the provisioning API.

    The provisioning API is user-owned and has evolved over the project.  The
    preferred shape is POST /api/nodes/{hostname}.  If that endpoint is not
    implemented by the upstream service yet, fall back to POST /api/nodes with
    a small JSON body.  This keeps the UI usable while the provisioning API is
    finalized.
    """
    h = (hostname or "").strip()
    if not h:
        return 400, {"error": "bad_hostname", "detail": "hostname is required"}
    body = {"hostname": h}
    status, payload = await ww_request("POST", f"/nodes/{urllib.parse.quote(h)}", body=body)
    if status in (404, 405):
        status, payload = await ww_request("POST", "/nodes", body=body)
    return status, payload


async def ww_node_power(node_id: str, action: str) -> Tuple[int, Any]:
    action = (action or "").lower()
    if action not in POWER_ACTIONS:
        return 400, {"error": "bad_action", "detail": f"action must be one of {POWER_ACTIONS}"}
    # User's current API shape: POST /api/nodes/{hostname}/power body {action}
    status, payload = await ww_request(
        "POST", f"/nodes/{urllib.parse.quote(node_id)}/power", body={"action": action}
    )
    # Backward-compatible fallback for older proxy implementations.
    if status in (404, 405):
        status, payload = await ww_request(
            "GET", f"/nodes/{urllib.parse.quote(node_id)}/power", query={"action": action}
        )
    return status, payload


async def ww_node_provision(node_id: str, body: Optional[Dict[str, Any]] = None) -> Tuple[int, Any]:
    return await ww_request(
        "POST", f"/nodes/{urllib.parse.quote(node_id)}/provision", body=body or {}
    )


def _extract_ww_ip(node_id: str, detail: Any) -> str:
    """Best-effort production IP extraction from a Warewulf node document."""
    doc = detail
    if isinstance(detail, dict) and node_id in detail and isinstance(detail[node_id], dict):
        doc = detail[node_id]
    if not isinstance(doc, dict):
        return node_id
    for key in ("ipaddr", "ip", "address"):
        if doc.get(key):
            return str(doc[key])
    netdevs = doc.get("network devices") or doc.get("network_devices") or doc.get("NetDevs") or {}
    if isinstance(netdevs, dict):
        primary = doc.get("primary network") or doc.get("primary_network")
        ordered = []
        if primary and primary in netdevs:
            ordered.append((primary, netdevs[primary]))
        ordered.extend((k, v) for k, v in netdevs.items() if k != primary)
        for _, dev in ordered:
            if isinstance(dev, dict):
                for key in ("ipaddr", "Ipaddr", "ip", "address"):
                    if dev.get(key):
                        return str(dev[key])
    return node_id


async def ww_node_boot_status(node_id: str, ssh_user: Optional[str] = None) -> Dict[str, Any]:
    """Check whether a provisioned node has booted far enough for network/SSH."""
    node_id = (node_id or "").strip()
    if not node_id:
        return {"ok": False, "error": "node_id is required"}

    detail_status, detail = await ww_node_detail(node_id)
    target = _extract_ww_ip(node_id, detail if 200 <= detail_status < 300 else {})

    ping_cmd = ["ping", "-c", "1", "-W", "1", target]
    ping_rc, ping_out, ping_err = await _run(ping_cmd, timeout=3)
    ping_ok = ping_rc == 0

    user = (ssh_user or os.environ.get("WW_SSH_USER") or os.environ.get("K8S_SSH_USER") or "root").strip()
    ssh_cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=3",
        "-o", "StrictHostKeyChecking=no",
        f"{user}@{target}",
        "echo booted",
    ]
    ssh_rc, ssh_out, ssh_err = await _run(ssh_cmd, timeout=6)
    ssh_ok = ssh_rc == 0

    state = "boot_complete" if ssh_ok else ("network_up" if ping_ok else "unreachable")
    return {
        "ok": True,
        "node": node_id,
        "target": target,
        "state": state,
        "boot_complete": ssh_ok,
        "network_reachable": ping_ok,
        "ssh_ok": ssh_ok,
        "ssh_user": user,
        "detail_status": detail_status,
        "ping_error": (ping_err or ping_out).strip()[-500:],
        "ssh_error": (ssh_err or ssh_out).strip()[-500:],
    }


def ww_meta() -> Dict[str, Any]:
    return {
        "base": WW_API_BASE,
        "prefix": WW_API_PREFIX,
        "power_actions": list(POWER_ACTIONS),
        "auth": bool(WW_AUTH_HEADER or WW_TOKEN or WW_BASIC_USER),
        "auth_mode": "header" if WW_AUTH_HEADER else ("bearer" if WW_TOKEN else ("basic" if WW_BASIC_USER else "none")),
        "manager_host": WW_MANAGER_HOST,
        "manager_ip": os.environ.get("K8S_MASTER_IP", ""),
        "manager_ssh_user": WW_MANAGER_SSH_USER,
        "default_gateway": os.environ.get("CLUSTER_DEFAULT_GATEWAY", ""),
        "default_netmask": os.environ.get("CLUSTER_DEFAULT_NETMASK", "255.255.255.0"),
        "default_mtu": os.environ.get("CLUSTER_DEFAULT_MTU", "9000"),
        "default_primarynet": os.environ.get("CLUSTER_DEFAULT_PRIMARYNET", "eth"),
    }


def _ssh_dest(host: str, user: Optional[str] = None) -> str:
    host = (host or "").strip()
    user = (user or "").strip()
    if "@" in host or not user:
        return host
    return f"{user}@{host}"


async def ssh_status(target: str, ssh_user: Optional[str] = None) -> Dict[str, Any]:
    """Low-cost SSH readiness probe for the cluster monitoring table."""
    target = (target or "").strip()
    if not target:
        return {"ok": False, "ssh_ok": False, "error": "target is required"}
    user = (ssh_user or WW_NODE_SSH_USER or "root").strip()
    cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=3",
        "-o", "StrictHostKeyChecking=no",
        _ssh_dest(target, user),
        "true",
    ]
    rc, out, err = await _run(cmd, timeout=5)
    return {
        "ok": True,
        "target": target,
        "ssh_user": user,
        "ssh_ok": rc == 0,
        "returncode": rc,
        "error": (err or out).strip()[-500:],
    }


async def ww_add_node_cli(spec: Dict[str, Any]) -> Tuple[int, Any]:
    """Run `wwctl node add ...` on the Warewulf manager via SSH."""
    spec = spec or {}
    clean = {k: ("" if v is None else str(v).strip()) for k, v in spec.items()}
    required = [
        "hostname", "profile", "netname", "netdev", "type", "hwaddr",
        "ipaddr", "netmask", "gateway", "mtu", "primarynet", "ipmiaddr",
    ]
    missing = [k for k in required if not clean.get(k)]
    if missing:
        return 400, {"error": "missing_required_fields", "missing": missing}

    tokens = [
        WWCTL_BIN, "node", "add", clean["hostname"],
        "--profile", clean["profile"],
        "--netname", clean["netname"],
        "--netdev", clean["netdev"],
        "--type", clean["type"],
        "--hwaddr", clean["hwaddr"],
        "--ipaddr", clean["ipaddr"],
        "--netmask", clean["netmask"],
        "--gateway", clean["gateway"],
        "--mtu", clean["mtu"],
        "--primarynet", clean["primarynet"],
        "--ipmiaddr", clean["ipmiaddr"],
    ]
    remote_cmd = " ".join(shlex.quote(t) for t in tokens)
    ssh_cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "StrictHostKeyChecking=no",
        _ssh_dest(WW_MANAGER_HOST, WW_MANAGER_SSH_USER),
        remote_cmd,
    ]
    rc, out, err = await _run(ssh_cmd, timeout=60)
    payload = {
        "ok": rc == 0,
        "manager": WW_MANAGER_HOST,
        "ssh_user": WW_MANAGER_SSH_USER,
        "command": remote_cmd,
        "returncode": rc,
        "stdout": out.strip(),
        "stderr": err.strip(),
    }
    if rc != 0:
        payload["error"] = "wwctl_node_add_failed"
        payload["detail"] = (err or out).strip() or f"wwctl exited with {rc}"
    return (200 if rc == 0 else 500), payload


# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------


async def _run(cmd: List[str], timeout: float = 25.0) -> Tuple[int, str, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )
    except FileNotFoundError as e:
        return 127, "", f"command not found: {cmd[0]} ({e})"
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        return 124, "", f"timeout after {timeout}s"
    return (
        proc.returncode if proc.returncode is not None else -1,
        out.decode("utf-8", errors="replace"),
        err.decode("utf-8", errors="replace"),
    )


def _is_local_host(name: str) -> bool:
    if not name:
        return True
    local = {"localhost", "127.0.0.1"}
    for cmd in (["hostname", "-s"], ["hostname", "-f"], ["hostname"]):
        try:
            out = os.popen(" ".join(cmd)).read().strip()
            if out:
                local.add(out)
        except Exception:  # noqa: BLE001
            pass
    return name in local


def _kubectl_via_ssh() -> bool:
    mode = (K8S_USE_SSH or "auto").lower()
    if mode in ("1", "true", "yes", "on"):
        return True
    if mode in ("0", "false", "no", "off"):
        return False
    return bool(K8S_MASTER_NODE) and not _is_local_host(K8S_MASTER_NODE)


def _kubectl_target() -> str:
    return f"{K8S_SSH_USER}@{K8S_MASTER_NODE}" if K8S_SSH_USER else K8S_MASTER_NODE


def _remote_kubectl_script(args: List[str]) -> str:
    quoted_args = " ".join(shlex.quote(str(a)) for a in args)
    kubeconfig = shlex.quote(K8S_KUBECONFIG)
    kubectl_name = shlex.quote(KUBECTL)
    # Non-interactive SSH sessions often do not source profile files. Search
    # common kubectl locations and then run with an explicit KUBECONFIG.
    return (
        "set -e; "
        f"export KUBECONFIG={kubeconfig}; "
        f"K={kubectl_name}; "
        "if ! command -v \"$K\" >/dev/null 2>&1; then "
        "  for c in kubectl /usr/bin/kubectl /usr/local/bin/kubectl /usr/sbin/kubectl; do "
        "    if command -v \"$c\" >/dev/null 2>&1; then K=\"$c\"; break; fi; "
        "    if [ -x \"$c\" ]; then K=\"$c\"; break; fi; "
        "  done; "
        "fi; "
        "command -v \"$K\" >/dev/null 2>&1 || { echo 'kubectl not found on remote PATH' >&2; exit 127; }; "
        f"exec \"$K\" {quoted_args}"
    )


def _kubectl_cmd(args: List[str]) -> List[str]:
    if _kubectl_via_ssh():
        return [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=no",
            _kubectl_target(),
            _remote_kubectl_script(args),
        ]
    return [KUBECTL, *args]


def _kubectl_available() -> bool:
    if _kubectl_via_ssh():
        return shutil.which("ssh") is not None
    return shutil.which(KUBECTL) is not None


async def k8s_status() -> Dict[str, Any]:
    """Cluster-level health: control plane reachability + component versions."""
    if not _kubectl_available():
        return {"available": False, "reason": f"ssh unavailable locally" if _kubectl_via_ssh() else f"kubectl unavailable on local PATH", "master_node": K8S_MASTER_NODE, "via": "ssh" if _kubectl_via_ssh() else "local"}

    rc, out, err = await _run(_kubectl_cmd(["version", "-o", "json"]), timeout=12)
    version: Dict[str, Any] = {}
    reachable = rc == 0
    if rc == 0:
        try:
            version = json.loads(out)
        except json.JSONDecodeError:
            version = {}

    # component statuses (best effort; deprecated on newer clusters)
    healthy = None
    rc2, out2, _ = await _run(
        _kubectl_cmd(["get", "--raw", "/healthz"]), timeout=8
    )
    if rc2 == 0:
        healthy = out2.strip() == "ok"

    return {
        "available": True,
        "reachable": reachable,
        "healthz": healthy,
        "master_node": K8S_MASTER_NODE,
        "llmd_namespace": LLMD_NAMESPACE,
        "via": "ssh" if _kubectl_via_ssh() else "local",
        "target": _kubectl_target() if _kubectl_via_ssh() else "local",
        "kubeconfig": K8S_KUBECONFIG if _kubectl_via_ssh() else os.environ.get("KUBECONFIG", ""),
        "server_version": (version.get("serverVersion") or {}).get("gitVersion"),
        "client_version": (version.get("clientVersion") or {}).get("gitVersion"),
        "error": err.strip() if rc != 0 else "",
    }


def _node_role(labels: Dict[str, str]) -> str:
    for k in labels:
        if k.startswith("node-role.kubernetes.io/control-plane") or k.startswith(
            "node-role.kubernetes.io/master"
        ):
            return "control-plane"
    return "worker"


def _gpu_capacity(status: Dict[str, Any]) -> Optional[str]:
    cap = (status or {}).get("capacity") or {}
    for key in ("nvidia.com/gpu", "amd.com/gpu"):
        if key in cap:
            return f"{cap[key]} x {key.split('/')[0]}"
    return None


async def k8s_nodes() -> Dict[str, Any]:
    """Return parsed node list (name, role, status, k8s version, gpu, internal IP)."""
    if not _kubectl_available():
        return {"available": False, "reason": f"kubectl unavailable on {K8S_MASTER_NODE} via {'ssh' if _kubectl_via_ssh() else 'local PATH'}", "master_node": K8S_MASTER_NODE, "master_ip": os.environ.get("K8S_MASTER_IP", ""), "nodes": []}

    rc, out, err = await _run(_kubectl_cmd(["get", "nodes", "-o", "json"]), timeout=15)
    if rc != 0:
        return {"available": True, "reachable": False, "error": err.strip(), "master_node": K8S_MASTER_NODE, "master_ip": os.environ.get("K8S_MASTER_IP", ""), "nodes": []}

    try:
        doc = json.loads(out)
    except json.JSONDecodeError as e:
        return {"available": True, "reachable": False, "error": str(e), "master_node": K8S_MASTER_NODE, "master_ip": os.environ.get("K8S_MASTER_IP", ""), "nodes": []}

    nodes: List[Dict[str, Any]] = []
    for item in doc.get("items", []):
        meta = item.get("metadata", {}) or {}
        status = item.get("status", {}) or {}
        labels = meta.get("labels", {}) or {}
        node_info = status.get("nodeInfo", {}) or {}

        ready = "Unknown"
        for cond in status.get("conditions", []) or []:
            if cond.get("type") == "Ready":
                ready = "Ready" if cond.get("status") == "True" else "NotReady"

        addrs = status.get("addresses", []) or []
        internal_ip = next(
            (a.get("address") for a in addrs if a.get("type") == "InternalIP"), None
        )

        nodes.append(
            {
                "name": meta.get("name"),
                "role": _node_role(labels),
                "status": ready,
                "kubelet_version": node_info.get("kubeletVersion"),
                "os_image": node_info.get("osImage"),
                "kernel": node_info.get("kernelVersion"),
                "container_runtime": node_info.get("containerRuntimeVersion"),
                "internal_ip": internal_ip,
                "gpu": _gpu_capacity(status),
                "schedulable": not item.get("spec", {}).get("unschedulable", False),
            }
        )

    nodes.sort(key=lambda n: (n["role"] != "control-plane", n.get("name") or ""))
    return {"available": True, "reachable": True, "master_node": K8S_MASTER_NODE, "master_ip": os.environ.get("K8S_MASTER_IP", ""), "nodes": nodes}


def _pod_role(name: str, labels: Dict[str, str]) -> str:
    """Best-effort prefill/decode/epp classification for llm-d pods."""
    blob = (name + " " + " ".join(f"{k}={v}" for k, v in (labels or {}).items())).lower()
    if "decode" in blob:
        return "decode"
    if "prefill" in blob:
        return "prefill"
    if "epp" in blob or "gateway" in blob or "scheduler" in blob:
        return "epp"
    return "other"


async def k8s_pods(namespace: Optional[str] = None) -> Dict[str, Any]:
    """List pods (all namespaces, or one). Returns name/ns/node/status/ip/ready/restarts/role."""
    if not _kubectl_available():
        return {"available": False, "reason": f"kubectl unavailable on {K8S_MASTER_NODE} via {'ssh' if _kubectl_via_ssh() else 'local PATH'}", "pods": []}

    args = ["get", "pods", "-o", "json"]
    args += ["-n", namespace] if namespace else ["-A"]
    rc, out, err = await _run(_kubectl_cmd(args), timeout=15)
    if rc != 0:
        return {"available": True, "reachable": False, "error": err.strip(), "pods": []}
    try:
        doc = json.loads(out)
    except json.JSONDecodeError as e:
        return {"available": True, "reachable": False, "error": str(e), "pods": []}

    pods: List[Dict[str, Any]] = []
    for item in doc.get("items", []):
        meta = item.get("metadata", {}) or {}
        spec = item.get("spec", {}) or {}
        status = item.get("status", {}) or {}
        cs = status.get("containerStatuses", []) or []
        ready_n = sum(1 for c in cs if c.get("ready"))
        restarts = sum(int(c.get("restartCount", 0)) for c in cs)

        containers = []
        for c in cs:
            state_doc = c.get("state") or {}
            state = next(iter(state_doc.keys()), "unknown") if state_doc else "unknown"
            reason = ""
            if isinstance(state_doc.get(state), dict):
                reason = state_doc[state].get("reason") or state_doc[state].get("message") or ""
            containers.append({
                "name": c.get("name"),
                "image": c.get("image"),
                "ready": bool(c.get("ready")),
                "restarts": int(c.get("restartCount", 0)),
                "state": state,
                "reason": reason,
            })

        pods.append(
            {
                "name": meta.get("name"),
                "namespace": meta.get("namespace"),
                "node": spec.get("nodeName"),
                "phase": status.get("phase"),
                "ip": status.get("podIP"),
                "host_ip": status.get("hostIP"),
                "qos": status.get("qosClass"),
                "ready": f"{ready_n}/{len(cs)}" if cs else "0/0",
                "restarts": restarts,
                "role": _pod_role(meta.get("name") or "", meta.get("labels") or {}),
                "containers": containers,
                "age": meta.get("creationTimestamp"),
            }
        )
    pods.sort(key=lambda p: (p.get("namespace") or "", p.get("name") or ""))
    return {"available": True, "reachable": True, "pods": pods}


async def k8s_services(namespace: Optional[str] = None) -> Dict[str, Any]:
    """List Kubernetes services across all namespaces or one namespace."""
    if not _kubectl_available():
        return {"available": False, "reason": f"kubectl unavailable on {K8S_MASTER_NODE} via {'ssh' if _kubectl_via_ssh() else 'local PATH'}", "services": []}

    args = ["get", "svc", "-o", "json"]
    args += ["-n", namespace] if namespace else ["-A"]
    rc, out, err = await _run(_kubectl_cmd(args), timeout=15)
    if rc != 0:
        return {"available": True, "reachable": False, "error": err.strip(), "services": []}
    try:
        doc = json.loads(out)
    except json.JSONDecodeError as e:
        return {"available": True, "reachable": False, "error": str(e), "services": []}

    services: List[Dict[str, Any]] = []
    for item in doc.get("items", []) or []:
        meta = item.get("metadata", {}) or {}
        spec = item.get("spec", {}) or {}
        ports = []
        for p in spec.get("ports", []) or []:
            parts = []
            if p.get("port") is not None:
                parts.append(str(p.get("port")))
            if p.get("protocol"):
                parts.append(str(p.get("protocol")))
            if p.get("targetPort") is not None:
                parts.append(f"target:{p.get('targetPort')}")
            if p.get("nodePort") is not None:
                parts.append(f"node:{p.get('nodePort')}")
            ports.append("/".join(parts))
        services.append({
            "name": meta.get("name"),
            "namespace": meta.get("namespace"),
            "type": spec.get("type"),
            "cluster_ip": spec.get("clusterIP"),
            "external_ip": ",".join(spec.get("externalIPs") or []) or "<none>",
            "ports": ", ".join(ports),
            "selector": spec.get("selector") or {},
            "age": meta.get("creationTimestamp"),
        })
    services.sort(key=lambda x: (x.get("namespace") or "", x.get("name") or ""))
    return {"available": True, "reachable": True, "services": services}


async def k8s_workloads(namespace: Optional[str] = None) -> Dict[str, Any]:
    """List high-level workloads to show the currently running controller processes."""
    if not _kubectl_available():
        return {"available": False, "reason": f"kubectl unavailable on {K8S_MASTER_NODE} via {'ssh' if _kubectl_via_ssh() else 'local PATH'}", "workloads": []}

    args = ["get", "deploy,sts,ds", "-o", "json"]
    args += ["-n", namespace] if namespace else ["-A"]
    rc, out, err = await _run(_kubectl_cmd(args), timeout=15)
    if rc != 0:
        return {"available": True, "reachable": False, "error": err.strip(), "workloads": []}
    try:
        doc = json.loads(out)
    except json.JSONDecodeError as e:
        return {"available": True, "reachable": False, "error": str(e), "workloads": []}

    workloads: List[Dict[str, Any]] = []
    for item in doc.get("items", []) or []:
        meta = item.get("metadata", {}) or {}
        status = item.get("status", {}) or {}
        kind = item.get("kind") or ""
        desired = status.get("replicas") or status.get("desiredNumberScheduled") or 0
        ready = status.get("readyReplicas") or status.get("numberReady") or 0
        available = status.get("availableReplicas") or status.get("numberAvailable") or ready
        workloads.append({
            "kind": kind,
            "name": meta.get("name"),
            "namespace": meta.get("namespace"),
            "desired": desired,
            "ready": ready,
            "available": available,
            "age": meta.get("creationTimestamp"),
        })
    workloads.sort(key=lambda x: (x.get("namespace") or "", x.get("kind") or "", x.get("name") or ""))
    return {"available": True, "reachable": True, "workloads": workloads}


async def k8s_llmd_endpoints(namespace: Optional[str] = None) -> Dict[str, Any]:
    """Resolve benchmarkable llm-d endpoints in a namespace:

      - decode / prefill pod IPs (port 8000)  -> direct, EPP-bypass
      - the EPP / inference-gateway service    -> routed path
    The UI uses this to pre-fill bench targets and the GPU-monitor host list.
    """
    ns = namespace or LLMD_NAMESPACE
    pods_doc = await k8s_pods(ns)
    pods = pods_doc.get("pods", [])
    decode = [{"pod": p["name"], "ip": p["ip"], "node": p["node"], "url": f"http://{p['ip']}:8000"}
              for p in pods if p["role"] == "decode" and p.get("ip")]
    prefill = [{"pod": p["name"], "ip": p["ip"], "node": p["node"], "url": f"http://{p['ip']}:8000"}
               for p in pods if p["role"] == "prefill" and p.get("ip")]

    services: List[Dict[str, Any]] = []
    if _kubectl_available():
        rc, out, _ = await _run(_kubectl_cmd(["get", "svc", "-n", ns, "-o", "json"]), timeout=12)
        if rc == 0:
            try:
                for s in json.loads(out).get("items", []):
                    m = s.get("metadata", {}) or {}
                    sp = s.get("spec", {}) or {}
                    ports = [p.get("port") for p in sp.get("ports", []) or []]
                    name = m.get("name") or ""
                    is_epp = "epp" in name.lower() or "gateway" in name.lower() or "inference" in name.lower()
                    services.append({
                        "name": name, "cluster_ip": sp.get("clusterIP"),
                        "ports": ports, "epp": is_epp,
                        "url": f"http://{sp.get('clusterIP')}:{ports[0]}" if sp.get("clusterIP") and ports else None,
                    })
            except json.JSONDecodeError:
                pass

    nodes = sorted({p["node"] for p in (decode + prefill) if p.get("node")})
    return {
        "namespace": ns,
        "decode": decode,
        "prefill": prefill,
        "services": services,
        "epp_service": next((s for s in services if s.get("epp")), None),
        "worker_nodes": nodes,
    }


async def k8s_join_worker(
    target: str, ssh_user: Optional[str] = None
) -> Dict[str, Any]:
    """Join a worker node to this control-plane via the join helper script.

    ``target`` is an IP or hostname reachable over SSH from the master.  The
    script generates a fresh `kubeadm token create --print-join-command` on the
    master, then runs it on the target over SSH.
    """
    if not target or not target.strip():
        return {"ok": False, "error": "target (hostname or IP) is required"}
    if not os.path.isfile(K8S_JOIN_SCRIPT):
        return {"ok": False, "error": f"join script missing: {K8S_JOIN_SCRIPT}"}

    cmd = ["bash", K8S_JOIN_SCRIPT, "--target", target.strip()]
    if ssh_user and ssh_user.strip():
        cmd += ["--ssh-user", ssh_user.strip()]

    rc, out, err = await _run(cmd, timeout=300)
    return {
        "ok": rc == 0,
        "exit_code": rc,
        "target": target.strip(),
        "stdout": out[-8000:],
        "stderr": err[-4000:],
    }
