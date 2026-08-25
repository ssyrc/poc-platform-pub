#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/llmd/llmd_serve.sh
# --------------------------
# Benchmark an ALREADY-DEPLOYED llm-d endpoint with `guidellm`.
#
# llm-d itself is deployed out of band (llm-d quickstart / Helm). This script
# only resolves a target endpoint and drives guidellm against it, matching the
# real workflow on this cluster:
#
#   HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 guidellm benchmark \
#     --target http://10.244.0.10:8000 \
#     --model /models/Qwen3-32B \
#     --processor /pvs/polybench/models/Qwen3-32B \
#     --profile sweep --max-seconds 60 \
#     --data prompt_tokens=256,output_tokens=128
#
# Endpoint resolution (--endpoint-mode):
#   pod     : discover a decode (serve) / prefill+decode (pd) pod IP via kubectl
#             in --namespace and target http://<podIP>:8000  (EPP bypass)
#   service : target the EPP / inference-gateway ClusterIP service in --namespace
#   proxy   : target --proxy-url (e.g. http://127.0.0.1:8896, update101)
#   manual  : target --target verbatim
#
# mode (serve|pd) only changes the default pod role to discover and is recorded
# in the result for the dashboard. Output -> LLMD_BENCH_RESULT_JSON + guidellm.json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

MODE_OP="run"           # run | stop
SERVE_MODE="serve"      # serve | pd
RUN_ID=""
VERSION="v6.0"
GPU_TYPE="H100"
NAMESPACE="${LLMD_NAMESPACE:-llm-d-quickstart}"
ENDPOINT_MODE="pod"     # pod | service | proxy | manual
TARGET=""
PROXY_URL="${LLMD_PROXY_URL:-http://127.0.0.1:8896}"
MODEL="${LLMD_MODEL:-Qwen3-32B}"
PROCESSOR="${LLMD_PROCESSOR:-/models/Qwen3-32B}"
PROFILE="sweep"
MAX_SECONDS="60"
PROMPT_TOKENS="256"
OUTPUT_TOKENS="128"
RATE=""
LEADER=""
HOSTS_CSV=""
BMT_HOST=""
LOG_ROOT=""
MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
EXTRA_ARGS=""
COMMON_EXTRA_ARGS=""
PREFILL_EXTRA_ARGS=""
DECODE_EXTRA_ARGS=""
DRY_RUN="false"
# deploy mode (endpoint-mode=deploy): we spin up a vLLM pod pinned to a node,
# auto-selecting N free GPUs and binding their topology-paired RDMA NICs.
DEPLOY_IMAGE="${LLMD_DEPLOY_IMAGE:-${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/vllm/vllm-openai:latest}"
DEPLOY_IMAGE_TAR="${LLMD_DEPLOY_IMAGE_TAR:-${DATA_ROOT}/dockerimgs/vllm-openai_latest.tar}"
DEPLOY_GPUS=""           # explicit indices "0,1,2,3"; empty = auto
DEPLOY_GPU_COUNT="4"
DEPLOY_NICS=""           # explicit "mlx5_0,mlx5_1"; empty = derive from topology
DEPLOY_NODE=""           # nodeSelector hostname; defaults to leader
MODEL_PATH="${LLMD_MODEL_PATH:-/models/Qwen3-32B}"  # local model dir to mount (e.g. /models/Qwen3-32B)
MAX_MODEL_LEN="4096"
TP=""                    # tensor-parallel-size; default = #GPUs
COMPILEIQ="false"
COMPILEIQ_ACF=""          # reserved; UI-only for now
# Post-deploy validation.  In deploy mode, compare the host GPU UUID/PCI set
# selected before scheduling with the GPU UUID/PCI set visible inside the pod.
BINDING_VERIFY="not_applicable"
GPU_VERIFY="not_applicable"
NIC_VERIFY="not_applicable"
EXPECTED_GPU_UUIDS=""
EXPECTED_GPU_PCIS=""
ACTUAL_GPU_UUIDS=""
ACTUAL_GPU_PCIS=""
ACTUAL_NICS=""
POD_NODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE_OP="stop"; shift ;;
    --mode) SERVE_MODE="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --endpoint-mode) ENDPOINT_MODE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --proxy-url) PROXY_URL="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --processor) PROCESSOR="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --max-seconds) MAX_SECONDS="${2:-}"; shift 2 ;;
    --prompt-tokens) PROMPT_TOKENS="${2:-}"; shift 2 ;;
    --output-tokens) OUTPUT_TOKENS="${2:-}"; shift 2 ;;
    --rate) RATE="${2:-}"; shift 2 ;;
    --leader) LEADER="${2:-}"; shift 2 ;;
    --hosts) HOSTS_CSV="${2:-}"; shift 2 ;;
    --bmt-host) BMT_HOST="${2:-}"; shift 2 ;;
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --extra-args) EXTRA_ARGS="${2:-}"; shift 2 ;;
    --common-extra-args) COMMON_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --prefill-extra-args) PREFILL_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --decode-extra-args) DECODE_EXTRA_ARGS="${2:-}"; shift 2 ;;
    --deploy-image) DEPLOY_IMAGE="${2:-}"; shift 2 ;;
    --deploy-image-tar) DEPLOY_IMAGE_TAR="${2:-}"; shift 2 ;;
    --gpus) DEPLOY_GPUS="${2:-}"; shift 2 ;;
    --gpu-count) DEPLOY_GPU_COUNT="${2:-}"; shift 2 ;;
    --nics) DEPLOY_NICS="${2:-}"; shift 2 ;;
    --deploy-node) DEPLOY_NODE="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="${2:-}"; shift 2 ;;
    --tp) TP="${2:-}"; shift 2 ;;
    --compileiq) COMPILEIQ="true"; shift ;;
    --compileiq-acf) COMPILEIQ_ACF="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) echo "see header"; exit 0 ;;
    *) cm_die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || cm_die "--run-id required"
cm_validate_run_id "$RUN_ID"
case "$SERVE_MODE"   in serve|pd) ;; *) cm_die "--mode must be serve|pd";; esac
case "$ENDPOINT_MODE" in pod|service|proxy|manual|deploy) ;; *) cm_die "--endpoint-mode must be pod|service|proxy|manual|deploy";; esac

KUBECTL="${KUBECTL_BIN:-kubectl}"  # compatibility only; use cm_kubectl wrappers below
RID="$(cm_safe_id "$RUN_ID")"
[[ -n "$LEADER" ]] || LEADER="${HOSTS_CSV%%,*}"

# stop is a no-op for benchmarking an external endpoint (nothing to tear down);
# the platform also sends SIGTERM to this process which ends guidellm.
if [[ "$MODE_OP" == "stop" ]]; then
  cm_phase stop
  cm_emit_json_line LLMD_BENCH_RESULT_JSON status stopped run_id "$RUN_ID" host "$LEADER" mode "$SERVE_MODE"
  exit 0
fi

[[ -n "$MODEL" ]]     || cm_die "--model required (or set LLMD_MODEL)"
[[ -n "$PROCESSOR" ]] || cm_die "--processor required (or set LLMD_PROCESSOR)"

cm_phase config
cm_inf "mode=${SERVE_MODE} version=${VERSION} gpu=${GPU_TYPE} endpoint_mode=${ENDPOINT_MODE}"
cm_inf "run_id=${RUN_ID} namespace=${NAMESPACE} leader=${LEADER}"
cm_inf "model=${MODEL} processor=${PROCESSOR}"
[[ -n "$COMMON_EXTRA_ARGS" ]] && cm_inf "common_extra_args=${COMMON_EXTRA_ARGS}"
[[ -n "$PREFILL_EXTRA_ARGS" ]] && cm_inf "prefill_extra_args=${PREFILL_EXTRA_ARGS} (reserved for future PD deploy)"
[[ -n "$DECODE_EXTRA_ARGS" ]] && cm_inf "decode_extra_args=${DECODE_EXTRA_ARGS} (reserved for future PD deploy)"

# ---------------------------------------------------------------------------
# results dir
# ---------------------------------------------------------------------------
[[ -n "$LOG_ROOT" ]] || LOG_ROOT="${MLPERF_ROOT}/llmd_logs_bench"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_ROOT}/${STAMP}_${SERVE_MODE}_${VERSION}_${RID}"
RESULT_DIR="${LOG_DIR}/results"
mkdir -p "$RESULT_DIR"
cm_inf "log_dir=${LOG_DIR}"
echo "[platform] log_dir=${LOG_DIR}"

# ---------------------------------------------------------------------------
# resolve TARGET
# ---------------------------------------------------------------------------
kready() { cm_kubectl_available; }

resolve_target() {
  case "$ENDPOINT_MODE" in
    manual)
      [[ -n "$TARGET" ]] || cm_die "--target required for endpoint-mode=manual"
      ;;
    proxy)
      [[ -n "$PROXY_URL" ]] || cm_die "--proxy-url required for endpoint-mode=proxy"
      TARGET="$PROXY_URL"
      ;;
    pod)
      [[ -n "$TARGET" ]] && return 0   # caller already pinned a pod IP
      kready || cm_die "kubectl required to discover pod (or pass --target)"
      # pick first running pod of the desired role
      local role="decode"; [[ "$SERVE_MODE" == "pd" ]] && role="decode"  # bench hits decode side
      local ip
      ip="$(cm_kubectl -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
            | awk -v r="$role" 'tolower($1) ~ r && $3=="Running" {print $2; exit}')"
      [[ -n "$ip" ]] || cm_die "no Running '${role}' pod with IP found in ns=${NAMESPACE}"
      TARGET="http://${ip}:8000"
      ;;
    service)
      [[ -n "$TARGET" ]] && return 0
      kready || cm_die "kubectl required to discover service (or pass --target)"
      local svc_ip svc_port
      read -r svc_ip svc_port < <(cm_kubectl -n "$NAMESPACE" get svc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.clusterIP}{" "}{.spec.ports[0].port}{"\n"}{end}' 2>/dev/null \
            | awk 'tolower($1) ~ /epp|gateway|inference/ {print $2, $3; exit}')
      [[ -n "$svc_ip" ]] || cm_die "no EPP/gateway service found in ns=${NAMESPACE}"
      TARGET="http://${svc_ip}:${svc_port}"
      ;;
    deploy)
      # Topology-aware deploy: pick N free GPUs on a node (auto, default 4),
      # derive their bound RDMA NICs, spin up a vLLM pod pinned to that node
      # with NVIDIA_VISIBLE_DEVICES + NCCL_IB_HCA set accordingly, expose a
      # ClusterIP Service, and target it.
      if [[ "$DRY_RUN" != "true" ]]; then
        kready || cm_die "kubectl required for endpoint-mode=deploy"
      fi
      [[ -n "$MODEL_PATH" ]] || cm_die "--model-path required for deploy mode (or set LLMD_MODEL_PATH)"
      local node="${DEPLOY_NODE:-$LEADER}"
      [[ -n "$node" ]] || cm_die "deploy needs a node (--deploy-node or --leader)"

      # GPU selection: explicit --gpus, or auto-discover N free
      local gpus="$DEPLOY_GPUS"
      if [[ -z "$gpus" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          gpus="$(seq -s, 0 $((DEPLOY_GPU_COUNT-1)))"
          cm_inf "[dry-run] auto-selected GPUs: ${gpus}"
        else
          cm_inf "auto-selecting ${DEPLOY_GPU_COUNT} free GPUs on ${node} ..."
          local out; out="$(nvidia_free_csv "$node" "$DEPLOY_GPU_COUNT")" || true
          gpus="$out"
          [[ -n "$gpus" ]] || cm_die "could not auto-select ${DEPLOY_GPU_COUNT} free GPUs on ${node}"
        fi
      fi
      local n_gpu; n_gpu="$(awk -F, '{print NF}' <<< "$gpus")"
      [[ "${TP:-}" ]] || TP="$n_gpu"

      # NIC selection: explicit --nics, or derive from `nvidia-smi topo -m`
      local nics="$DEPLOY_NICS"
      if [[ -z "$nics" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          # Map default GPU set 0,1,2,3 -> mlx5_0,mlx5_1 (per the canonical example).
          nics="mlx5_0,mlx5_1"
          cm_inf "[dry-run] derived NICs: ${nics}"
        else
          nics="$(topo_nics_for_gpus "$node" "$gpus")"
        fi
      fi
      cm_inf "deploy node=${node} gpus=[${gpus}] tp=${TP} nics=[${nics}] model_path=${MODEL_PATH}"
      cm_inf "deploy image=${DEPLOY_IMAGE} image_tar=${DEPLOY_IMAGE_TAR}"

      if [[ "$DRY_RUN" != "true" ]]; then
        cm_inf "ensuring deploy image on ${node}: ${DEPLOY_IMAGE}"
        cm_remote_bash "$node" "$DEPLOY_IMAGE" "$DEPLOY_IMAGE_TAR" <<'IMG' || cm_die "deploy image missing on ${node}: ${DEPLOY_IMAGE}"
set -Eeuo pipefail
IMAGE="$1"; TAR="$2"
if command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[INFO] docker image already present: $IMAGE"
  exit 0
fi

echo "[WARN] deploy image missing: $IMAGE"
echo "[INFO] trying fallback tar before docker pull: ${TAR:-<none>}"
loaded=0
if [[ -f "$TAR" ]]; then
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] docker load -i $TAR"
    docker load -i "$TAR" && loaded=1 || true
  fi
  if command -v ctr >/dev/null 2>&1; then
    echo "[INFO] ctr -n k8s.io images import $TAR"
    ctr -n k8s.io images import "$TAR" && loaded=1 || true
  fi
else
  echo "[WARN] tar fallback missing; trying docker pull next: $TAR" >&2
fi

if [[ "$loaded" == "1" ]]; then
  exit 0
fi

pull_dockerhub_ref() {
  local image="$1"
  local local_prefix="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}"
  local pull_prefix="${DOCKER_HUB_PULL_PREFIX:-docker.io}"
  case "$image" in
    "${local_prefix}"/*) printf '%s\n' "${pull_prefix}/${image#${local_prefix}/}" ;;
    docker.io/*) printf '%s\n' "${pull_prefix}/${image#docker.io/}" ;;
    *) printf '%s\n' "$image" ;;
  esac
}
if command -v docker >/dev/null 2>&1; then
  PULL_IMAGE="$(pull_dockerhub_ref "$IMAGE")"
  if docker pull "$PULL_IMAGE"; then
    if [[ "$PULL_IMAGE" != "$IMAGE" ]]; then
      docker tag "$PULL_IMAGE" "$IMAGE" || true
    fi
    exit 0
  fi
fi

echo "[ERROR] could not load or pull image: $IMAGE" >&2
exit 24
IMG
      fi
      if [[ "$DRY_RUN" == "true" ]]; then
        EXPECTED_GPU_UUIDS="dry-run"
        EXPECTED_GPU_PCIS="dry-run"
      else
        local inv; inv="$(gpu_inventory_for_indices "$node" "$gpus")"
        EXPECTED_GPU_UUIDS="${inv%%|*}"
        EXPECTED_GPU_PCIS="${inv#*|}"
        cm_inf "[verify] expected host GPUs: indices=${gpus} uuids=${EXPECTED_GPU_UUIDS:-<none>} pci=${EXPECTED_GPU_PCIS:-<none>}"
      fi
      if [[ "$COMPILEIQ" == "true" ]]; then
        cm_inf "compileiq=reserved_ui_only (ignored by runtime scripts in this version)"
      else
        cm_inf "compileiq=disabled"
      fi

      local app="vllmd-${RID}"
      local svc="${app}-svc"
      # NIC env
      local ucx_devs; ucx_devs="$(awk -v s="$nics" 'BEGIN{n=split(s,a,",");for(i=1;i<=n;i++){printf"%s%s:1",(i>1?",":""),a[i]}}')"

      apply_yaml() {
        if [[ "$DRY_RUN" == "true" ]]; then sed 's/^/  | /'; return 0; fi
        cm_kubectl -n "$NAMESPACE" apply -f -
      }
      if [[ "$DRY_RUN" == "true" ]]; then
        cm_inf "[dry-run] create ns ${NAMESPACE} if missing"
      else
        cm_kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || cm_kubectl create namespace "$NAMESPACE" >/dev/null 2>&1 || true
      fi

      cat <<YAML | apply_yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${app}, labels: { app: ${app}, run-id: "${RID}" } }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${app} } }
  template:
    metadata: { labels: { app: ${app} } }
    spec:
      nodeSelector: { kubernetes.io/hostname: "${node}" }
      hostIPC: true
      containers:
      - name: vllm
        image: ${DEPLOY_IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext: { capabilities: { add: ["IPC_LOCK"] } }
        env:
        - { name: NVIDIA_VISIBLE_DEVICES, value: "${gpus}" }
        - { name: NCCL_IB_HCA,            value: "${nics}" }
        - { name: UCX_NET_DEVICES,        value: "${ucx_devs}" }
        - { name: NCCL_IB_DISABLE,        value: "0" }
        - { name: VLLM_LOGGING_LEVEL,     value: "INFO" }
        args:
        - "vllm"
        - "serve"
        - "${MODEL_PATH}"
        - "--served-model-name=${MODEL}"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--tensor-parallel-size=${TP}"
        - "--max-model-len=${MAX_MODEL_LEN}"
        ports: [{ name: http, containerPort: 8000 }]
        readinessProbe:
          httpGet: { path: /health, port: 8000 }
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 60
        resources:
          limits:
            nvidia.com/gpu: "${n_gpu}"
        volumeMounts:
        - { name: model, mountPath: "${MODEL_PATH}", readOnly: true }
        - { name: shm, mountPath: /dev/shm }
      volumes:
      - { name: model, hostPath: { path: "${MODEL_PATH}" } }
      - { name: shm, emptyDir: { medium: Memory } }
---
apiVersion: v1
kind: Service
metadata: { name: ${svc}, labels: { app: ${app}, run-id: "${RID}" } }
spec:
  selector: { app: ${app} }
  ports: [{ name: http, port: 8000, targetPort: 8000 }]
YAML

      DEPLOYED_APP="$app"; DEPLOYED_SVC="$svc"; DEPLOYED_NODE="$node"
      DEPLOYED_GPUS="$gpus"; DEPLOYED_NICS="$nics"
      if [[ "$DRY_RUN" == "true" ]]; then
        TARGET="http://placeholder.${NAMESPACE}.svc:8000"
        BINDING_VERIFY="skipped_dry_run"
        GPU_VERIFY="skipped_dry_run"
        NIC_VERIFY="skipped_dry_run"
        ACTUAL_GPU_UUIDS="dry-run"
        ACTUAL_GPU_PCIS="dry-run"
        ACTUAL_NICS="dry-run"
        POD_NODE="$node"
        cm_inf "[dry-run] would wait for rollout, validate GPU/NIC binding, and bench"
      else
        cm_inf "waiting for ${app} rollout ..."
        cm_kubectl -n "$NAMESPACE" rollout status "deployment/${app}" --timeout=900s \
          || cm_die "vLLM deployment did not become ready"
        validate_deploy_bindings "$app" "$node" "$gpus" "$nics"
        # use service cluster IP for guidellm to hit
        local svc_ip; svc_ip="$(cm_kubectl -n "$NAMESPACE" get svc "$svc" -o jsonpath='{.spec.clusterIP}')"
        TARGET="http://${svc_ip}:8000"
      fi
      ;;
  esac
}

# Helpers used by the deploy branch.
nvidia_free_csv() {
  # Print first <count> indices whose memory.used <= 200 MiB, comma-joined.
  local node="$1" count="$2"
  local q='nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits'
  local txt
  if cm_is_local_host "$node"; then txt="$(bash -lc "$q" 2>/dev/null || true)"
  else txt="$(cm_remote_bash "$node" <<<"$q" 2>/dev/null || true)"; fi
  awk -F',' -v c="$count" '
    { gsub(/ /,"",$1); gsub(/ /,"",$2); if ($2+0 <= 200) { free[k++]=$1 } }
    END { for (i=0;i<k && i<c;i++) printf "%s%s", (i>0?",":""), free[i] }
  ' <<< "$txt"
}

topo_nics_for_gpus() {
  # Run `nvidia-smi topo -m`, then for each GPU index in $2 pick the closest NIC
  # (PIX > PXB) and resolve to mlx5_X via the NIC legend.
  local node="$1" gpus_csv="$2"
  local cmd='nvidia-smi topo -m'
  local topo
  if cm_is_local_host "$node"; then topo="$(bash -lc "$cmd" 2>/dev/null || true)"
  else topo="$(cm_remote_bash "$node" <<<"$cmd" 2>/dev/null || true)"; fi
  [[ -n "$topo" ]] || { echo ""; return; }
  echo "$topo" | awk -v gpus="$gpus_csv" '
    BEGIN { n=split(gpus,want,","); for(i=1;i<=n;i++) need[want[i]]=1; }
    /^[[:space:]]+GPU[0-9]/ {
      # header row: capture col index of each NICk
      for (i=1;i<=NF;i++) if ($i ~ /^NIC[0-9]+$/) niccol[$i]=i+1   # +1 because row[0]="GPUk"
    }
    /^GPU[0-9]+/ {
      gpu=substr($1,4); if (!(gpu in need)) next
      best=""; bestrank=99
      for (nic in niccol) {
        v=$(niccol[nic])
        r=(v=="PIX"?0:(v=="PXB"?1:(v=="PHB"?2:(v=="NODE"?3:99))))
        if (r<bestrank) { bestrank=r; best=nic }
      }
      if (best!="") chosen[best]=1
    }
    /^[[:space:]]*NIC[0-9]+:/ { sub(":","",$1); legend[$1]=$2 }
    END {
      first=1
      for (nic in chosen) {
        dev=legend[nic]; if (dev=="") dev=nic
        printf "%s%s", (first?"":","), dev; first=0
      }
    }'
}


normalize_csv() {
  tr ',' '
' <<< "${1:-}" | sed '/^$/d' | sort | paste -sd, -
}

gpu_inventory_for_indices() {
  # Print "uuid_csv|pci_csv" for the requested host GPU indices, preserving
  # the requested index order.  These identifiers survive container renumbering.
  local node="$1" gpus_csv="$2"
  local q='nvidia-smi --query-gpu=index,uuid,pci.bus_id --format=csv,noheader,nounits'
  local txt
  if cm_is_local_host "$node"; then txt="$(bash -lc "$q" 2>/dev/null || true)"
  else txt="$(cm_remote_bash "$node" <<<"$q" 2>/dev/null || true)"; fi
  awk -F',' -v gpus="$gpus_csv" '
    function trim(s){gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s}
    BEGIN { n=split(gpus,want,","); for(i=1;i<=n;i++) want[i]=trim(want[i]); }
    NF>=3 { idx=trim($1); uuid=trim($2); pci=trim($3); u[idx]=uuid; p[idx]=pci; }
    END {
      first=1;
      for(i=1;i<=n;i++){ idx=want[i]; if(idx in u){ printf "%s%s", (first?"":","), u[idx]; first=0; } }
      printf "|";
      first=1;
      for(i=1;i<=n;i++){ idx=want[i]; if(idx in p){ printf "%s%s", (first?"":","), p[idx]; first=0; } }
    }' <<< "$txt"
}

validate_deploy_bindings() {
  local app="$1" expected_node="$2" expected_gpus="$3" expected_nics="$4"
  cm_phase verify_binding
  local pod
  pod="$(cm_kubectl -n "$NAMESPACE" get pod -l "app=${app}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    BINDING_VERIFY="warn_no_pod"; GPU_VERIFY="warn_no_pod"; NIC_VERIFY="warn_no_pod"
    cm_warn "[verify] no pod found for app=${app}"
    return 0
  fi
  POD_NODE="$(cm_kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  local actual
  actual="$(cm_kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- bash -lc '
    nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits 2>/dev/null | sed "s/[[:space:]]//g"
  ' 2>/dev/null || true)"
  ACTUAL_GPU_UUIDS="$(printf '%s\n' "$actual" | awk -F, 'NF>=1{printf "%s%s",(NR>1?",":""),$1}')"
  ACTUAL_GPU_PCIS="$(printf '%s\n' "$actual" | awk -F, 'NF>=2{printf "%s%s",(NR>1?",":""),$2}')"

  local nic_probe hca visible_nics
  nic_probe="$(cm_kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- bash -lc '
    printf "NCCL_IB_HCA=%s\n" "${NCCL_IB_HCA:-}";
    printf "UCX_NET_DEVICES=%s\n" "${UCX_NET_DEVICES:-}";
    if command -v ibdev2netdev >/dev/null 2>&1; then ibdev2netdev 2>/dev/null | awk "{print \$1}" | paste -sd, -; else true; fi
  ' 2>/dev/null || true)"
  hca="$(printf '%s\n' "$nic_probe" | awk -F= '/^NCCL_IB_HCA=/{print $2; exit}' | tr -d ' ')"
  visible_nics="$(printf '%s\n' "$nic_probe" | tail -n 1 | tr -d ' ')"
  ACTUAL_NICS="${hca:-${visible_nics}}"

  local exp_uuid_norm act_uuid_norm exp_nic_norm act_nic_norm
  exp_uuid_norm="$(normalize_csv "$EXPECTED_GPU_UUIDS")"
  act_uuid_norm="$(normalize_csv "$ACTUAL_GPU_UUIDS")"
  exp_nic_norm="$(normalize_csv "$expected_nics")"
  act_nic_norm="$(normalize_csv "$hca")"

  GPU_VERIFY="pass"
  [[ "$POD_NODE" == "$expected_node" ]] || GPU_VERIFY="warn_node_mismatch"
  [[ -n "$exp_uuid_norm" && "$exp_uuid_norm" == "$act_uuid_norm" ]] || GPU_VERIFY="warn_gpu_uuid_mismatch"

  NIC_VERIFY="pass"
  [[ -n "$exp_nic_norm" && "$exp_nic_norm" == "$act_nic_norm" ]] || NIC_VERIFY="warn_nic_env_mismatch"

  if [[ "$GPU_VERIFY" == "pass" && "$NIC_VERIFY" == "pass" ]]; then
    BINDING_VERIFY="pass"
  else
    BINDING_VERIFY="warn"
  fi

  cm_inf "[verify] pod=${pod} node expected=${expected_node} actual=${POD_NODE}"
  cm_inf "[verify] gpu indices=${expected_gpus} expected_uuid=${EXPECTED_GPU_UUIDS:-<none>} actual_uuid=${ACTUAL_GPU_UUIDS:-<none>} gpu_verify=${GPU_VERIFY}"
  cm_inf "[verify] expected_nics=${expected_nics:-<none>} actual_env_hca=${hca:-<none>} visible_nics=${visible_nics:-<none>} nic_verify=${NIC_VERIFY}"
}

cleanup_deploy() {
  # Tear down a deploy if we created one (DEPLOYED_APP set).
  [[ -n "${DEPLOYED_APP:-}" ]] || return 0
  cm_phase cleanup_deploy
  [[ "$DRY_RUN" == "true" ]] && { cm_inf "[dry-run] would delete deploy/${DEPLOYED_APP}"; return 0; }
  cm_kubectl -n "$NAMESPACE" delete deployment "$DEPLOYED_APP" --ignore-not-found --wait=false 2>/dev/null || true
  cm_kubectl -n "$NAMESPACE" delete service    "$DEPLOYED_SVC" --ignore-not-found --wait=false 2>/dev/null || true
}
trap 'cleanup_deploy' EXIT

cm_phase resolve_endpoint
if [[ "$DRY_RUN" == "true" && -z "$TARGET" && "$ENDPOINT_MODE" =~ ^(pod|service)$ ]]; then
  TARGET="http://10.244.0.10:8000"   # placeholder for dry-run preview
  cm_inf "[dry-run] using placeholder target ${TARGET}"
else
  resolve_target
fi
cm_inf "target=${TARGET}"

# quick reachability probe (non-fatal in dry-run)
if [[ "$DRY_RUN" != "true" ]]; then
  if curl -sf "${TARGET}/v1/models" >/dev/null 2>&1; then
    cm_inf "endpoint /v1/models reachable"
  else
    cm_warn "endpoint /v1/models not reachable yet (guidellm may still connect)"
  fi
fi

# ---------------------------------------------------------------------------
# guidellm
# ---------------------------------------------------------------------------
cm_phase bench
build_guidellm() {
  local -a a=(guidellm benchmark
    --target "$TARGET"
    --model "$MODEL"
    --processor "$PROCESSOR"
    --profile "$PROFILE"
    --max-seconds "$MAX_SECONDS"
    --data "prompt_tokens=${PROMPT_TOKENS},output_tokens=${OUTPUT_TOKENS}"
    --output-path "${RESULT_DIR}/guidellm.json")
  [[ -n "$RATE" ]] && a+=(--rate "$RATE")
  [[ -n "$COMMON_EXTRA_ARGS" ]] && a+=($COMMON_EXTRA_ARGS)
  [[ -n "$EXTRA_ARGS" ]] && a+=($EXTRA_ARGS)
  printf '%s\0' "${a[@]}"
}

# offline env so huggingface_hub / transformers never reach the network
OFFLINE_ENV='HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1'

RC=0
mapfile -d '' -t GA < <(build_guidellm)
if [[ "$DRY_RUN" == "true" ]]; then
  cm_inf "[dry-run] ${OFFLINE_ENV} ${GA[*]}"
else
  set +e
  if [[ -n "$BMT_HOST" ]] && ! cm_is_local_host "$BMT_HOST"; then
    cm_inf "running guidellm on BMT host ${BMT_HOST}"
    printf '%s\n' "export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1; $(printf '%q ' "${GA[@]}")" \
      | cm_remote_bash "$BMT_HOST" 2>&1 | tee "${RESULT_DIR}/guidellm.txt"
    RC="${PIPESTATUS[0]}"
  else
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 "${GA[@]}" 2>&1 | tee "${RESULT_DIR}/guidellm.txt"
    RC="${PIPESTATUS[0]}"
  fi
  set -e
fi

STATUS="$([[ "$RC" == "0" ]] && echo success || echo failed)"

cm_phase done
cm_emit_json_line LLMD_BENCH_RESULT_JSON \
  status "$STATUS" \
  run_id "$RUN_ID" \
  host "$LEADER" \
  mode "$SERVE_MODE" \
  version "$VERSION" \
  model "$MODEL" \
  endpoint_mode "$ENDPOINT_MODE" \
  target "$TARGET" \
  deploy_node "${DEPLOYED_NODE:-}" \
  deploy_gpus "${DEPLOYED_GPUS:-}" \
  deploy_nics "${DEPLOYED_NICS:-}" \
  binding_verify "$BINDING_VERIFY" \
  gpu_verify "$GPU_VERIFY" \
  nic_verify "$NIC_VERIFY" \
  expected_gpu_uuids "$EXPECTED_GPU_UUIDS" \
  actual_gpu_uuids "$ACTUAL_GPU_UUIDS" \
  expected_gpus "${DEPLOYED_GPUS:-}" \
  actual_gpus "$ACTUAL_GPU_PCIS" \
  actual_nics "$ACTUAL_NICS" \
  pod_node "$POD_NODE" \
  compileiq "$COMPILEIQ" \
  common_extra_args "$COMMON_EXTRA_ARGS" \
  prefill_extra_args "$PREFILL_EXTRA_ARGS" \
  decode_extra_args "$DECODE_EXTRA_ARGS" \
  exit_code "$RC" \
  log_dir "$LOG_DIR"

exit "$RC"
