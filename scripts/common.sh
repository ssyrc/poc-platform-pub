#!/usr/bin/env bash
# scripts/common/common.sh
# ------------------------
# Shared bash helpers used by vllm/ and pd/ scripts.
# Sourced by each dispatcher / runner. Designed to be safe to source under
# `set -Eeuo pipefail`.
#
# Conventions:
#   * Functions use snake_case.
#   * Functions never read flags from argv; callers pass values explicitly.
#   * emit_summary() writes a single line of the form
#       BENCH_RESULT_JSON={"status":"...","run_id":"...","host":"...", ...}
#     The platform's runner.py captures this line to finalize the host status.
#   * Each new script type uses a unique JSON prefix:
#       MLPerf_RESULT_JSON=  -> mlperf_*.sh
#       VLLM_BENCH_RESULT_JSON=  -> vllm_run.sh / vllm_bench.sh
#       PD_BENCH_RESULT_JSON=  -> pd_run.sh / pd_serve_*
#     (The runner picks up any of these via a generic _SUMMARY_LINE regex.)

# ---------- local environment ----------

COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_PROJECT_DIR="$(cd "${COMMON_SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${COMMON_SCRIPT_DIR}/lib_ssh.sh"
ENV_FILE="${POC_PLATFORM_ENV_FILE:-${COMMON_PROJECT_DIR}/.env}"
if [[ -f "$ENV_FILE" && "${POC_PLATFORM_ENV_LOADED:-0}" != "1" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  export POC_PLATFORM_ENV_LOADED=1
fi

# ---------- printing helpers ----------

cm_die()   { echo "[ERROR] $*" >&2; exit 1; }
cm_inf()   { echo "[INFO] $*"; }
cm_warn()  { echo "[WARN] $*"; }
cm_phase() { echo "[PHASE] $*"; }
cm_err()   { echo "[ERROR] $*"; }

# ---------- json helpers ----------

cm_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# Build a JSON string out of pairs. Usage:
#   cm_emit_json_line VLLM_BENCH_RESULT_JSON \
#       status success run_id "$RUN_ID" host "$HOST" ...
# Values are always JSON-escaped as strings unless they look like a number.
cm_emit_json_line() {
  local prefix="$1"; shift
  local -a parts=()
  while [[ $# -ge 2 ]]; do
    local key="$1"
    local val="$2"
    shift 2
    if [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      parts+=("\"${key}\":${val}")
    else
      parts+=("\"${key}\":\"$(cm_json_escape "$val")\"")
    fi
  done
  local body
  body="$(IFS=,; echo "${parts[*]}")"
  printf '%s={%s}\n' "$prefix" "$body"
}

# ---------- host helpers ----------

cm_local_short() { hostname -s 2>/dev/null || hostname; }
cm_local_fqdn()  { hostname -f 2>/dev/null || hostname; }

cm_is_local_host() {
  local h="$1"
  local s f
  s="$(cm_local_short)"
  f="$(cm_local_fqdn)"
  [[ "$h" == "localhost" || "$h" == "127.0.0.1" || "$h" == "$s" || "$h" == "$f" ]]
}

# Runs `bash -s -- <args>` either locally or via SSH on $1.
# Stdin must be the bash script.
cm_remote_bash() {
  local h="$1"; shift
  if cm_is_local_host "$h"; then
    bash -s -- "$@"
  else
    local -a _sopt; ssh_opts_for _sopt "$h"
    ssh ${_sopt[@]+"${_sopt[@]}"} -o BatchMode=yes -o ConnectTimeout=8 "$h" bash -s -- "$@"
  fi
}



# ---------- Docker bootstrap helper ----------
# Bare-metal tests use Docker directly on target hosts. Site-specific registry,
# proxy, RPM path, and credentials are supplied through .env and sent to the
# target over the SSH stdin stream (not embedded in the repository).
cm_ensure_docker_host() {
  local h="$1"
  cm_validate_host "$h"
  cm_inf "checking Docker on ${h}"

  {
    printf 'DOCKER_RPM_DIR=%q\n' "${DOCKER_RPM_DIR:-}"
    printf 'DOCKER_REGISTRY=%q\n' "${DOCKER_REGISTRY:-}"
    printf 'DOCKER_USERNAME=%q\n' "${DOCKER_USERNAME:-}"
    printf 'DOCKER_PASSWORD=%q\n' "${DOCKER_PASSWORD:-}"
    printf 'DOCKER_HTTP_PROXY=%q\n' "${DOCKER_HTTP_PROXY:-}"
    printf 'DOCKER_HTTPS_PROXY=%q\n' "${DOCKER_HTTPS_PROXY:-}"
    printf 'DOCKER_INSECURE_REGISTRIES=%q\n' "${DOCKER_INSECURE_REGISTRIES:-}"
    cat <<'DOCKER_BOOTSTRAP'
set -Eeuo pipefail

write_docker_config() {
  mkdir -p /etc/docker /etc/systemd/system/docker.service.d

  local -a registries=()
  local raw reg first=1
  IFS=',' read -ra registries <<< "${DOCKER_INSECURE_REGISTRIES:-}"
  {
    echo '{'
    echo '  "exec-opts": ["native.cgroupdriver=systemd"],'
    echo '  "insecure-registries": ['
    for raw in "${registries[@]}"; do
      reg="${raw#${raw%%[![:space:]]*}}"
      reg="${reg%${reg##*[![:space:]]}}"
      [[ -n "$reg" ]] || continue
      [[ "$first" == "1" ]] || echo ','
      printf '    "%s"' "$reg"
      first=0
    done
    [[ "$first" == "1" ]] || echo
    echo '  ],'
    echo '  "log-driver": "json-file",'
    echo '  "log-opts": {"max-size": "100m"},'
    echo '  "runtimes": {'
    echo '    "nvidia": {"args": [], "path": "nvidia-container-runtime"}'
    echo '  },'
    echo '  "storage-driver": "overlay2"'
    echo '}'
  } > /etc/docker/daemon.json

  if [[ -n "${DOCKER_HTTP_PROXY:-}" || -n "${DOCKER_HTTPS_PROXY:-}" ]]; then
    {
      echo '[Service]'
      [[ -z "${DOCKER_HTTP_PROXY:-}" ]] || printf 'Environment="HTTP_PROXY=%s"\n' "$DOCKER_HTTP_PROXY"
      [[ -z "${DOCKER_HTTPS_PROXY:-}" ]] || printf 'Environment="HTTPS_PROXY=%s"\n' "$DOCKER_HTTPS_PROXY"
    } > /etc/systemd/system/docker.service.d/http-proxy.conf
  else
    rm -f /etc/systemd/system/docker.service.d/http-proxy.conf 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/docker.service.d/override.conf 2>/dev/null || true
}

installed_now=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "[INFO] docker already available"
else
  if [[ "${EUID:-$(id -u)}" != "0" ]]; then
    echo "[ERROR] docker is unavailable and this user cannot install/configure Docker; run as root or pre-install Docker" >&2
    exit 20
  fi
  [[ -n "${DOCKER_RPM_DIR:-}" && -d "$DOCKER_RPM_DIR" ]] || {
    echo "[ERROR] Docker is unavailable and DOCKER_RPM_DIR is not configured or missing" >&2
    exit 20
  }
  echo "[INFO] docker unavailable; installing Docker from configured offline RPM bundle"
  cd "$DOCKER_RPM_DIR"
  dnf install -y --disablerepo='*' --disableplugin=subscription-manager --nogpgcheck ./*.rpm
  installed_now=1
fi

if [[ "${EUID:-$(id -u)}" == "0" ]]; then
  write_docker_config
  systemctl daemon-reload
  systemctl enable --now docker
  systemctl restart docker
elif [[ "$installed_now" == "1" ]]; then
  echo "[ERROR] Docker was installed but service configuration requires root" >&2
  exit 20
fi

if ! docker info >/dev/null 2>&1; then
  echo "[ERROR] docker service is not ready after installation/configuration" >&2
  exit 20
fi

if [[ -n "${DOCKER_REGISTRY:-}" && -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
  printf '%s\n' "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USERNAME" --password-stdin >/dev/null
  echo "[INFO] docker login ok: ${DOCKER_REGISTRY}"
elif [[ -n "${DOCKER_REGISTRY:-}" ]]; then
  echo "[WARN] DOCKER_REGISTRY is set but credentials are incomplete; skipping docker login"
fi
DOCKER_BOOTSTRAP
  } | if cm_is_local_host "$h"; then
    bash -s
  else
    local -a _sopt; ssh_opts_for _sopt "$h"
    ssh ${_sopt[@]+"${_sopt[@]}"} -o BatchMode=yes -o ConnectTimeout=8 "$h" bash -s
  fi
}

cm_ensure_docker_hosts() {
  local h key
  declare -A _seen=()
  for h in "$@"; do
    [[ -n "${h:-}" ]] || continue
    key="$h"
    [[ -z "${_seen[$key]:-}" ]] || continue
    _seen[$key]=1
    cm_ensure_docker_host "$h"
  done
}

# ---------- kubectl helper ----------
# By default the platform observes/controls Kubernetes from the control-plane
# node.  This lets the web backend run on another BMT/proxy host while kubectl
# still executes on the configured Kubernetes control-plane node.
cm_kubectl_via_ssh() {
  local mode="${K8S_USE_SSH:-auto}"
  case "$mode" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac
  local master="${K8S_MASTER_NODE:-localhost}"
  [[ -n "$master" ]] && ! cm_is_local_host "$master"
}

cm_kubectl_target() {
  local master="${K8S_MASTER_NODE:-localhost}"
  local user="${K8S_SSH_USER:-root}"
  if [[ -n "$user" ]]; then printf '%s@%s' "$user" "$master"; else printf '%s' "$master"; fi
}

cm_remote_kubectl_script() {
  local k="${KUBECTL_BIN:-kubectl}"
  local kubeconfig="${K8S_KUBECONFIG:-/etc/kubernetes/admin.conf}"
  local args=""
  printf -v args '%q ' "$@"
  cat <<EOF
set -e
export KUBECONFIG=$(printf '%q' "$kubeconfig")
K=$(printf '%q' "$k")
if ! command -v "\$K" >/dev/null 2>&1; then
  for c in kubectl /usr/bin/kubectl /usr/local/bin/kubectl /usr/sbin/kubectl; do
    if command -v "\$c" >/dev/null 2>&1; then K="\$c"; break; fi
    if [ -x "\$c" ]; then K="\$c"; break; fi
  done
fi
command -v "\$K" >/dev/null 2>&1 || { echo 'kubectl not found on remote PATH' >&2; exit 127; }
exec "\$K" ${args}
EOF
}

cm_kubectl_available() {
  if cm_kubectl_via_ssh; then
    command -v ssh >/dev/null 2>&1 || return 1
    local -a _sopt; ssh_opts_for _sopt "$(cm_kubectl_target)"
    ssh ${_sopt[@]+"${_sopt[@]}"} -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$(cm_kubectl_target)" "$(cm_remote_kubectl_script version --client=true)" >/dev/null 2>&1
  else
    local k="${KUBECTL_BIN:-kubectl}"
    command -v "$k" >/dev/null 2>&1
  fi
}

cm_kubectl() {
  local k="${KUBECTL_BIN:-kubectl}"
  if cm_kubectl_via_ssh; then
    local -a _sopt; ssh_opts_for _sopt "$(cm_kubectl_target)"
    ssh ${_sopt[@]+"${_sopt[@]}"} -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$(cm_kubectl_target)" "$(cm_remote_kubectl_script "$@")"
  else
    export KUBECONFIG="${K8S_KUBECONFIG:-${KUBECONFIG:-}}"
    "$k" "$@"
  fi
}

# ---------- safe id helper ----------

cm_safe_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

# ---------- host validation ----------

cm_validate_host() {
  local h="$1"
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || cm_die "Invalid hostname: $h"
}

cm_validate_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || cm_die "Invalid run-id: $1"
}

# ---------- gpu helpers (run on the target host's bash) ----------

cm_gpu_count_local() {
  local n
  n="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | wc -l | awk '{print $1}')"
  [[ -n "$n" && "$n" != "0" ]] || return 1
  printf '%s' "$n"
}

cm_cuda_devices_local() {
  local n="$1" out="" i
  for ((i=0; i<n; i++)); do
    [[ -z "$out" ]] && out="$i" || out="${out},${i}"
  done
  printf '%s' "$out"
}
