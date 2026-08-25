#!/usr/bin/env bash
# start_platform.sh
# -----------------
# Entry point for the POC GPU bench platform.
#
# What it does:
#   1) Detects Python >= 3.9
#   2) Sanity-checks required MLPerf scripts and optional vLLM/PD scripts
#   3) Creates a venv at ./.venv (idempotent)
#   4) Installs requirements.txt from local wheelhouse for air-gapped env
#   5) Exports MLPERF_* env vars consumed by backend
#   6) Launches uvicorn serving backend.app:app on PORT (default 8089)
#
# Usage:
#   ./start_platform.sh
#   PORT=9000 ./start_platform.sh
#   MLPERF_PYTHON=python3.11 ./start_platform.sh
#   SKIP_PIP_INSTALL=1 ./start_platform.sh
#   WHEELHOUSE=/abs/path ./start_platform.sh
#   MLPERF_SCRIPTS_DIR=/abs/path ./start_platform.sh
#   POC_PLATFORM_ROOT=/data/poc-platform ./start_platform.sh
#
# Stop with Ctrl-C. There's no daemon mode by design - run it under tmux/systemd
# if you want it persistent.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load site-specific configuration without committing secrets.
ENV_FILE="${POC_PLATFORM_ENV_FILE:-${SCRIPT_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# --- configuration ---------------------------------------------------------
PORT="${PORT:-8089}"
HOST_BIND="${HOST_BIND:-0.0.0.0}"

PY_MIN_MAJOR=3
PY_MIN_MINOR=9

export MLPERF_SCRIPTS_DIR="${MLPERF_SCRIPTS_DIR:-${SCRIPT_DIR}/scripts}"
# Default layout keeps runtime assets under the configured platform root.
POC_PLATFORM_ROOT="${POC_PLATFORM_ROOT:-${SCRIPT_DIR}}"
export POC_PLATFORM_ROOT
export MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT}}"
export MLPERF_DATA_ROOT="${MLPERF_DATA_ROOT:-${POC_PLATFORM_ROOT}/data}"
export MLPERF_LOG_LEVEL="${MLPERF_LOG_LEVEL:-INFO}"

# v3.5 — Test Cluster Management + llm-d
# Warewulf node-management API (OS provisioning tab). Override if your API
# lives elsewhere or behind a token.
export WW_API_BASE="${WW_API_BASE:-http://127.0.0.1:8897}"
export WW_API_PREFIX="${WW_API_PREFIX:-/api}"
export WW_API_TOKEN="${WW_API_TOKEN:-}"
export WW_AUTH_HEADER="${WW_AUTH_HEADER:-}"
export WW_BASIC_USER="${WW_BASIC_USER:-}"
export WW_BASIC_PASSWORD="${WW_BASIC_PASSWORD:-}"
# kubectl / kubeadm used by the K8s tab (status, node list, worker join).
export KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
export KUBEADM_BIN="${KUBEADM_BIN:-kubeadm}"
export K8S_SSH_USER="${K8S_SSH_USER:-root}"
export K8S_USE_SSH="${K8S_USE_SSH:-auto}"
export K8S_KUBECONFIG="${K8S_KUBECONFIG:-/etc/kubernetes/admin.conf}"
# When the platform is started on the control-plane node as root, kubectl often
# needs /etc/kubernetes/admin.conf.  Do not override an explicit KUBECONFIG.
if [[ -z "${KUBECONFIG:-}" && -f "$K8S_KUBECONFIG" ]]; then
  export KUBECONFIG="$K8S_KUBECONFIG"
fi
# Control-plane node the K8s tab monitors by default + llm-d namespace/proxy.
export K8S_MASTER_NODE="${K8S_MASTER_NODE:-localhost}"
export WW_MANAGER_HOST="${WW_MANAGER_HOST:-${K8S_MASTER_NODE}}"
export LLMD_NAMESPACE="${LLMD_NAMESPACE:-llm-d-quickstart}"
export LLMD_PROXY_URL="${LLMD_PROXY_URL:-http://127.0.0.1:8896}"

# Registry/proxy defaults are intentionally non-sensitive. Site-specific values
# belong in .env, which is ignored by Git.
export DOCKER_HUB_IMAGE_PREFIX="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}"
export DOCKER_HUB_PULL_PREFIX="${DOCKER_HUB_PULL_PREFIX:-docker.io}"
export NVCR_PULL_PREFIX="${NVCR_PULL_PREFIX:-nvcr.io}"

# Air-gapped Python package settings.
# venv is kept inside the platform folder; wheelhouse defaults to the parent
# poc-platform/files directory, with fallback candidates for portability.
VENV="${VENV:-${SCRIPT_DIR}/.venv}"
if [[ -z "${WHEELHOUSE:-}" ]]; then
  for cand in \
    "${POC_PLATFORM_ROOT}/files" \
    "${SCRIPT_DIR}/files" \
    "${SCRIPT_DIR}/../files"; do
    if [[ -d "$cand" ]]; then
      WHEELHOUSE="$cand"
      break
    fi
  done
  WHEELHOUSE="${WHEELHOUSE:-${POC_PLATFORM_ROOT}/files}"
fi
SKIP_PIP_INSTALL="${SKIP_PIP_INSTALL:-0}"

# --- helpers ---------------------------------------------------------------
err() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m[OK]\033[0m    %s\n'  "$*"; }
inf() { printf '\033[36m[INFO]\033[0m  %s\n'  "$*"; }
warn(){ printf '\033[33m[WARN]\033[0m  %s\n'  "$*"; }

py_version_ok() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || return 1
  "$bin" -c "
import sys
sys.exit(0 if sys.version_info[:2] >= ($PY_MIN_MAJOR, $PY_MIN_MINOR) else 1)
" 2>/dev/null
}

py_version_str() {
  "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null
}

print_python_help() {
  cat >&2 <<EOF

  Python >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR} required.
  Try one of:
    1) ls /usr/bin/python3.* /usr/local/bin/python3.* 2>/dev/null
       MLPERF_PYTHON=/usr/bin/python3.11 ./start_platform.sh
    2) module avail python
       module load python-3.13.0
       ./start_platform.sh
    3) conda create -n bench python=3.11 -y
       conda activate bench
       MLPERF_PYTHON=\$(which python) ./start_platform.sh
EOF
}

# --- step 0.5: environment module ------------------------------------------
# 이 host의 /apps/python 툴체인은 environment-modules의 module이 로드된 셸에서만
# venv/pip 생성이 온전히 끝난다. 없으면 bin/activate가 빠진 반쪽 venv가 조용히
# 만들어진다. systemd의 ExecStart=/usr/bin/env bash ... 는 로그인/인터랙티브
# 셸이 아니라 ~/.bashrc 나 /etc/profile.d/modules.sh 를 자동으로 읽지 않으므로
# 여기서 modules init을 직접 source한다.
# MLPERF_ENV_MODULE="" 로 끄거나 다른 module명을 지정할 수 있다.
MLPERF_ENV_MODULE="${MLPERF_ENV_MODULE-python-3.13.0}"

if [[ -n "$MLPERF_ENV_MODULE" ]]; then
  if ! command -v module >/dev/null 2>&1; then
    for init in /usr/share/Modules/init/bash /usr/share/lmod/lmod/init/bash /etc/profile.d/modules.sh; do
      if [[ -r "$init" ]]; then
        # shellcheck disable=SC1090
        source "$init" || true
        break
      fi
    done
  fi
  if command -v module >/dev/null 2>&1; then
    if module load "$MLPERF_ENV_MODULE" 2>/dev/null; then
      ok "module loaded: $MLPERF_ENV_MODULE"
    else
      warn "module load failed (continuing): $MLPERF_ENV_MODULE"
    fi
  else
    # module 시스템이 없는 로컬 개발 머신에서도 그냥 진행한다.
    inf "environment-modules not available; skipping module load"
  fi
fi

# --- step 1: detect Python -------------------------------------------------
inf "platform dir:  $SCRIPT_DIR"
inf "poc root:      $POC_PLATFORM_ROOT"
inf "scripts dir:   $MLPERF_SCRIPTS_DIR"
inf "runtime root:  $MLPERF_ROOT"
inf "data root:     $MLPERF_DATA_ROOT"
inf "venv:          $VENV"
inf "wheelhouse:    $WHEELHOUSE"

PYTHON_BIN=""

if [[ -n "${MLPERF_PYTHON:-}" ]]; then
  if py_version_ok "$MLPERF_PYTHON"; then
    PYTHON_BIN="$MLPERF_PYTHON"
  else
    if command -v "$MLPERF_PYTHON" >/dev/null 2>&1; then
      err "MLPERF_PYTHON=$MLPERF_PYTHON too old: $(py_version_str "$MLPERF_PYTHON")"
    else
      err "MLPERF_PYTHON=$MLPERF_PYTHON not found"
    fi
    print_python_help
    exit 1
  fi
fi

if [[ -z "$PYTHON_BIN" ]]; then
  for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3 python; do
    if py_version_ok "$cand"; then
      PYTHON_BIN="$cand"
      break
    fi
  done
fi

if [[ -z "$PYTHON_BIN" ]]; then
  err "no Python >= ${PY_MIN_MAJOR}.${PY_MIN_MINOR} on PATH"

  for cand in python python3 python3.6 python3.7 python3.8 python3.9 python3.10 python3.11 python3.12 python3.13; do
    if command -v "$cand" >/dev/null 2>&1; then
      v="$(py_version_str "$cand" || echo '?')"
      printf '    - %-14s -> %s (version %s)\n' "$cand" "$(command -v "$cand")" "$v" >&2
    fi
  done

  print_python_help
  exit 1
fi

inf "python: $(py_version_str "$PYTHON_BIN") ($PYTHON_BIN)"

if ! "$PYTHON_BIN" -c 'import venv' 2>/dev/null; then
  err "$PYTHON_BIN missing 'venv' module"
  exit 1
fi

# --- step 2: sanity checks -------------------------------------------------
# Required: existing 5 MLPerf scripts.
REQUIRED_MLPERF=(
  mlperf_run.sh
  mlperf_train_v41.sh
  mlperf_train_v51.sh
  mlperf_infer_v51.sh
  mlperf_infer_v60.sh
)

# Optional v2 tabs / dispatchers.
OPTIONAL=(
  common.sh
  vllm/vllm_run.sh
  vllm/vllm_bench.sh
  pd/pd_run.sh
  pd/pd_serve_vllm.sh
  llmd/llmd_run.sh
  llmd/llmd_serve.sh
  cluster/k8s_join_worker.sh
  cluster/k8s_status.sh
  training/train_k8s.sh
)

missing=0

for s in "${REQUIRED_MLPERF[@]}"; do
  if [[ ! -f "${MLPERF_SCRIPTS_DIR}/${s}" ]]; then
    err "missing required mlperf script: ${MLPERF_SCRIPTS_DIR}/${s}"
    missing=1
  fi
done

if [[ "$missing" -eq 1 ]]; then
  err "place the 5 mlperf scripts under \$MLPERF_SCRIPTS_DIR or override the path."
  exit 1
fi

ok "5 mlperf scripts found"

# Soft check optional scripts.
for s in "${OPTIONAL[@]}"; do
  if [[ ! -f "${MLPERF_SCRIPTS_DIR}/${s}" ]]; then
    warn "optional script missing: ${MLPERF_SCRIPTS_DIR}/${s} (tab will fail at runtime if used)"
  fi
done

chmod +x "${MLPERF_SCRIPTS_DIR}"/mlperf_*.sh 2>/dev/null || true
chmod +x "${MLPERF_SCRIPTS_DIR}"/vllm/*.sh 2>/dev/null || true
chmod +x "${MLPERF_SCRIPTS_DIR}"/pd/*.sh 2>/dev/null || true
chmod +x "${MLPERF_SCRIPTS_DIR}"/llmd/*.sh 2>/dev/null || true
chmod +x "${MLPERF_SCRIPTS_DIR}"/cluster/*.sh 2>/dev/null || true
chmod +x "${MLPERF_SCRIPTS_DIR}"/training/*.sh 2>/dev/null || true

if command -v nvidia-smi >/dev/null 2>&1; then
  inf "local nvidia-smi present"
else
  warn "no local nvidia-smi - GPU monitoring will use SSH"
fi

# --- step 3: venv ----------------------------------------------------------
# Match v1.0 behavior:
#   - venv path: ./.venv
#   - idempotent creation
#   - recreate only if existing venv Python is too old
RECREATE=0

# 폴더는 있는데 bin/python 이 없거나 실행 불가하거나 bin/activate 가 빠진
# 반쪽 venv도 반드시 잡아내야 한다. 예전 조건(-d && -x)은 그런 경우 아예 false가
# 되어 RECREATE도 안 켜지고 재생성도 건너뛴 채 깨진 venv로 그대로 진행했다.
if [[ -d "$VENV" ]]; then
  if [[ ! -x "$VENV/bin/python" ]]; then
    warn "existing venv has no usable python; recreating: $VENV"
    RECREATE=1
  elif [[ ! -f "$VENV/bin/activate" ]]; then
    warn "existing venv is missing bin/activate; recreating: $VENV"
    RECREATE=1
  elif ! py_version_ok "$VENV/bin/python"; then
    warn "existing venv uses old Python ($(py_version_str "$VENV/bin/python")); recreating: $VENV"
    RECREATE=1
  else
    inf "using existing venv at $VENV"
  fi
fi

if [[ "$RECREATE" -eq 1 ]]; then
  rm -rf "$VENV"
fi

if [[ ! -d "$VENV" ]]; then
  inf "creating venv at $VENV"
  "$PYTHON_BIN" -m venv "$VENV"
fi

if [[ ! -x "${VENV}/bin/python" ]]; then
  err "venv python not found: ${VENV}/bin/python"
  exit 1
fi

if [[ ! -f "${VENV}/bin/activate" ]]; then
  err "venv is incomplete (no bin/activate): ${VENV}"
  err "the Python toolchain likely needs its environment module loaded first"
  err "try: module load ${MLPERF_ENV_MODULE:-python-3.13.0} && rm -rf ${VENV} && $0"
  exit 1
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"

inf "venv python: $(python -c 'import sys; print(sys.executable)')"

if [[ "$SKIP_PIP_INSTALL" == "1" ]]; then
  inf "skipping dependency installation because SKIP_PIP_INSTALL=1"
else
  if [[ ! -d "$WHEELHOUSE" ]]; then
    err "wheelhouse not found: $WHEELHOUSE"
    err "This script is configured for air-gapped install."
    err "Expected wheelhouse candidates include: ${POC_PLATFORM_ROOT}/files or ${SCRIPT_DIR}/files"
    err "Prepare wheel files there, or run with WHEELHOUSE=/abs/path, or SKIP_PIP_INSTALL=1 if deps are already installed."
    exit 1
  fi

  if [[ ! -f "${SCRIPT_DIR}/backend/requirements.txt" ]]; then
    err "requirements file not found: ${SCRIPT_DIR}/backend/requirements.txt"
    exit 1
  fi

  inf "installing dependencies from local wheelhouse"

  # PIP_CONFIG_FILE=/dev/null prevents user/global pip config from injecting
  # unexpected index-url or find-links.
  PIP_CONFIG_FILE=/dev/null python -m pip install \
    --no-index \
    --find-links "$WHEELHOUSE" \
    -r "${SCRIPT_DIR}/backend/requirements.txt"

  ok "dependencies ready"
fi

# --- step 3.5: import check ------------------------------------------------
inf "checking backend deps"

python - <<'PY'
import fastapi
import uvicorn
import pydantic
import sse_starlette

print("[OK]    import check passed")
print(f"[INFO]  fastapi={fastapi.__version__}")
print(f"[INFO]  uvicorn={uvicorn.__version__}")
print(f"[INFO]  pydantic={pydantic.__version__}")
PY

# --- step 4: launch --------------------------------------------------------
inf "starting uvicorn on http://${HOST_BIND}:${PORT}"
echo
printf '\033[35m'
cat <<'BANNER'
   ___  ___  __  __    ___  ____  _  _  ___  _ _
  / __|| _ \|  \/  |  | _ )| ___|| \| |/ __|| || |
 | (_ ||  _/| |\/| |  | _ \| _|  | .` | (__ | __ |
  \___||_|  |_|  |_|  |___/|___| |_|\_|\___||_||_|
BANNER
printf '\033[0m'
echo
ok "platform up at: http://localhost:${PORT}"
echo

RELOAD_FLAG=()
if [[ "${MLPERF_RELOAD:-0}" == "1" ]]; then
  RELOAD_FLAG=(--reload)
  warn "auto-reload enabled (MLPERF_RELOAD=1)"
fi

exec python -m uvicorn backend.app:app \
  --host "$HOST_BIND" \
  --port "$PORT" \
  "${RELOAD_FLAG[@]}"
