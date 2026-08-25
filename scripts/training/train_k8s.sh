#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/training/train_k8s.sh
# -----------------------------
# Run an MLPerf *training* benchmark on Kubernetes by launching one pod per node
# (pinned to the node's hostname, requesting the matched GPU count) and running
# the benchmark container's OWN entrypoint (default: ./run_and_time.sh) inside
# it -- exactly the same script you'd run under SLURM/docker, just orchestrated
# by k8s with a torchrun rendezvous instead of srun.
#
# Modeled on the mlcommons/training_results NVIDIA recipe
# (github.com/mlcommons/training_results_v5.0 .../llama2_70b_lora):
#   export DATADIR=.../gov_report  MODEL=.../model  LOGDIR=...  CONT=<image>
#   source config_<system>.sh   # sets DGXNNODES, DGXNGPU, BATCHSIZE, ...
#   run_and_time.sh             # the actual training launcher
# Multi-node without SLURM uses PyTorch rendezvous (MASTER_ADDR/NNODES/NODE_RANK)
# as in the AMD MI325X no-SLURM guide. We also export SLURM_* equivalents so
# entrypoints that read either convention work.
#
# You supply the MLPerf container via --image (CONT) and the dataset/model
# paths; everything else is wired here. Topology-aware NIC binding is injected
# (NCCL_IB_HCA/UCX_NET_DEVICES) from `nvidia-smi topo -m` on the leader node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

OP="run"
RUN_ID=""; VERSION="v5.1"; BENCHMARK="llama2_70b_lora"; GPU_TYPE="H100"
NODES_CSV=""; GPUS_PER_NODE="8"; NAMESPACE="mlperf-training"
IMAGE=""                         # CONT: the MLPerf training container
DATADIR=""                       # dataset dir (mounted at /data inside container)
MODEL_PATH=""                    # preprocessed model/checkpoint dir
LOGDIR=""                        # where the container writes MLPerf logs
CONFIG=""                        # optional config_<system>.sh to source inside container
ENTRY="./run_and_time.sh"        # the benchmark's own launcher
WORKDIR=""                       # container workdir (e.g. /workspace/ft-llm); blank=image default
NIC_BIND="auto"
COMPILEIQ="false"
COMPILEIQ_ACF=""                 # reserved; UI-only for now
LOG_ROOT=""; MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
DRY_RUN="false"
SHM_SIZE="${MLPERF_K8S_SHM_SIZE:-64Gi}"
declare -a ENVS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) OP="stop"; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --benchmark) BENCHMARK="${2:-}"; shift 2 ;;
    --gpu-type) GPU_TYPE="${2:-}"; shift 2 ;;
    --nodes) NODES_CSV="${2:-}"; shift 2 ;;
    --gpus-per-node) GPUS_PER_NODE="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --datadir) DATADIR="${2:-}"; shift 2 ;;
    --model-path) MODEL_PATH="${2:-}"; shift 2 ;;
    --logdir) LOGDIR="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --entry) ENTRY="${2:-}"; shift 2 ;;
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --nic-bind) NIC_BIND="${2:-}"; shift 2 ;;
    --compileiq) COMPILEIQ="true"; shift ;;
    --compileiq-acf) COMPILEIQ_ACF="${2:-}"; shift 2 ;;
    --env) ENVS+=("${2:-}"); shift 2 ;;
    --data-path) DATADIR="${2:-}"; shift 2 ;;   # alias
    --log-root) LOG_ROOT="${2:-}"; shift 2 ;;
    --shm-size) SHM_SIZE="${2:-}"; shift 2 ;;
    --mlperf-root) MLPERF_ROOT="${2:-}"; shift 2 ;;
    --data-root) DATA_ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) echo "see header"; exit 0 ;;
    *) cm_die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ID" ]] || cm_die "--run-id required"
cm_validate_run_id "$RUN_ID"
[[ -n "$NODES_CSV" ]] || cm_die "--nodes required"
IFS=',' read -ra NODES <<< "$NODES_CSV"
for n in "${NODES[@]}"; do cm_validate_host "$n"; done
LEADER="${NODES[0]}"; NNODES="${#NODES[@]}"
WORLD_SIZE=$(( NNODES * GPUS_PER_NODE ))

# Defaults are intentionally aligned with the standalone MLPerf scripts that
# already worked in this environment. UI does not expose image selection.
DOCKERIMG_DIR="${DATA_ROOT}/dockerimgs"
set_training_defaults() {
  case "${VERSION}:${BENCHMARK}:${GPU_TYPE}" in
    v4.1:llama2_70b_lora:H100|v4.1:llama2_70b_lora:A100)
      IMAGE="${IMAGE:-${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/myhomerepo/mlperf-nvidia:llama2_70b_lora-pyt}"
      DATADIR="${DATADIR:-${DATA_ROOT}/training_llama2_70b_lora_v41/gov_report}"
      MODEL_PATH="${MODEL_PATH:-${DATA_ROOT}/training_llama2_70b_lora_v41/model_nemo}"
      WORKDIR="${WORKDIR:-/workspace/ft-llm}"
      ENTRY="${ENTRY:-./run_and_time.sh}"
      ;;
    v4.1:llama2_70b_lora:GH200)
      IMAGE="${IMAGE:-${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/wahabk/mlperf-nvidia:llama2_70b_lora-pyt3}"
      DATADIR="${DATADIR:-${DATA_ROOT}/training_llama2_70b_lora_v41/gov_report}"
      MODEL_PATH="${MODEL_PATH:-${DATA_ROOT}/training_llama2_70b_lora_v41/model_nemo}"
      WORKDIR="${WORKDIR:-/workspace/ft-llm}"
      ENTRY="${ENTRY:-./run_and_time.sh}"
      ;;
    v5.1:llama2_70b_lora:H100|v5.1:llama2_70b_lora:B300|v5.1:llama2_70b_lora:RTX6000|v5.1:llama2_70b_lora:RTX_PRO_6000)
      IMAGE="${IMAGE:-${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90}"
      DATADIR="${DATADIR:-${DATA_ROOT}/training_llama2_70b_lora/data}"
      MODEL_PATH="${MODEL_PATH:-${DATA_ROOT}/training_llama2_70b_lora/model}"
      WORKDIR="${WORKDIR:-/workspace/ft-llm}"
      ENTRY="${ENTRY:-./run_and_time.sh}"
      ;;
    v5.1:llama31_8b:H100|v5.1:llama31_8b:B300|v5.1:llama31_8b:RTX6000|v5.1:llama31_8b:RTX_PRO_6000)
      IMAGE="${IMAGE:-${DOCKER_HUB_IMAGE_PREFIX:-docker.io}/donnmyth/mlperf-nvidia:llama31_8b-pyt-sm90}"
      DATADIR="${DATADIR:-${DATA_ROOT}/training_llama31_8b/8b}"
      MODEL_PATH="${MODEL_PATH:-${DATA_ROOT}/training_llama31_8b/8b}"
      WORKDIR="${WORKDIR:-/workspace/llama31_8b}"
      ENTRY="${ENTRY:-./run_and_time.sh}"
      ;;
    *)
      cm_die "unsupported default for version=${VERSION} benchmark=${BENCHMARK} gpu=${GPU_TYPE}; pass explicit --image/--datadir/--model-path or update train_k8s.sh"
      ;;
  esac
}
set_training_defaults

KUBECTL="${KUBECTL_BIN:-kubectl}"  # compatibility only; use cm_kubectl wrappers below
RID="$(cm_safe_id "$RUN_ID")"
JOB="mlpt-${RID}"; SVC="${JOB}-rdzv"
NODES_YAML="$(printf '"%s",' "${NODES[@]}" | sed 's/,$//')"

kc() { if [[ "$DRY_RUN" == "true" ]]; then cm_inf "[dry-run] kubectl $*"; return 0; fi; cm_kubectl -n "$NAMESPACE" "$@"; }
cleanup() {
  cm_phase cleanup
  kc delete job "$JOB" --ignore-not-found --wait=false 2>/dev/null || true
  kc delete service "$SVC" --ignore-not-found --wait=false 2>/dev/null || true
}

if [[ "$OP" == "stop" ]]; then
  cleanup
  cm_emit_json_line MLPerf_RESULT_JSON status stopped run_id "$RUN_ID" host "$LEADER" benchmark "$BENCHMARK"
  exit 0
fi

[[ -n "$IMAGE" ]] || cm_die "image default resolution failed"
[[ -n "$DATADIR" ]] || cm_die "datadir default resolution failed"
[[ -n "$MODEL_PATH" ]] || cm_die "model-path default resolution failed"
cm_inf "image=${IMAGE}"
cm_inf "datadir=${DATADIR}"
cm_inf "model_path=${MODEL_PATH}"
cm_inf "workdir=${WORKDIR:-<image-default>} entry=${ENTRY}"
if [[ "$COMPILEIQ" == "true" ]]; then
  cm_inf "compileiq=reserved_ui_only (ignored by runtime scripts in this version)"
else
  cm_inf "compileiq=disabled"
fi

# --- results dir + log streaming ---
[[ -n "$LOG_ROOT" ]] || LOG_ROOT="${MLPERF_ROOT}/training_logs_k8s"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_ROOT}/${STAMP}_${VERSION}_${BENCHMARK}_${RID}"
mkdir -p "$LOG_DIR"
echo "[platform] log_dir=${LOG_DIR}"
cm_inf "log_dir=${LOG_DIR}"

trap 'cm_err "interrupted"; cleanup' INT TERM

# --- topology-aware NIC binding (leader node) ---
cm_phase topology
NIC_DEVICES=""
if [[ "$NIC_BIND" == "auto" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    NIC_DEVICES="mlx5_0,mlx5_1,mlx5_3,mlx5_4"
  else
    if cm_is_local_host "$LEADER"; then TOPO="$(nvidia-smi topo -m 2>/dev/null || true)"
    else TOPO="$(cm_remote_bash "$LEADER" <<< 'nvidia-smi topo -m' 2>/dev/null || true)"; fi
    NIC_DEVICES="$(sed -n 's/^[[:space:]]*NIC[0-9]\+:[[:space:]]*\(mlx5_[0-9]\+\).*/\1/p' <<< "$TOPO" | paste -sd, -)"
  fi
else
  NIC_DEVICES="$NIC_BIND"
fi
cm_inf "NIC bind: ${NIC_DEVICES:-<none>}"
cm_inf "SHM size: ${SHM_SIZE}"

# --- env block ---
cm_phase deploy
ENV_YAML=""
add_env() { ENV_YAML+="        - { name: ${1}, value: \"${2}\" }"$'\n'; }
# topology / RDMA
[[ -n "$NIC_DEVICES" ]] && { add_env NCCL_IB_HCA "$NIC_DEVICES"; \
  add_env UCX_NET_DEVICES "$(echo "$NIC_DEVICES" | sed 's/\([^,]*\)/\1:1/g')"; \
  add_env NCCL_IB_DISABLE 0; }
# MLPerf contract (mlcommons/training_results convention)
add_env DATADIR "/data"
add_env MODEL "/model"
add_env LOGDIR "/results"
add_env DGXNNODES "$NNODES"
add_env DGXNGPU "$GPUS_PER_NODE"
add_env MLPERF_BENCHMARK "$BENCHMARK"
add_env MLPERF_VERSION "$VERSION"
add_env MLPERF_LOG_EVERY_N_STEPS "${MLPERF_LOG_EVERY_N_STEPS:-1}"
add_env MLPERF_ENABLE_PROGRESS_BAR "${MLPERF_ENABLE_PROGRESS_BAR:-true}"
add_env PYTHONUNBUFFERED "${PYTHONUNBUFFERED:-1}"
add_env TQDM_MININTERVAL "${TQDM_MININTERVAL:-0}"
# PyTorch rendezvous (non-SLURM multinode)
add_env MASTER_ADDR "${JOB}-0.${SVC}"
add_env MASTER_PORT "29500"
add_env NNODES "$NNODES"
add_env NPROC_PER_NODE "$GPUS_PER_NODE"
add_env WORLD_SIZE "$WORLD_SIZE"
# SLURM-equivalents (entrypoints that read SLURM_* still work)
add_env SLURM_NNODES "$NNODES"
add_env SLURM_NTASKS "$NNODES"
add_env SLURM_GPUS_PER_NODE "$GPUS_PER_NODE"
for kv in "${ENVS[@]:-}"; do [[ -z "$kv" ]] && continue; add_env "${kv%%=*}" "${kv#*=}"; done

CD_LINE=""; [[ -n "$WORKDIR" ]] && CD_LINE="cd ${WORKDIR}"
SRC_LINE=""; [[ -n "$CONFIG" ]] && SRC_LINE="source ${CONFIG}"

emit_service() {
cat <<YAML
apiVersion: v1
kind: Service
metadata: { name: ${SVC}, labels: { app: ${JOB} } }
spec:
  clusterIP: None
  selector: { app: ${JOB} }
  ports: [{ name: rdzv, port: 29500 }]
YAML
}

emit_job() {
cat <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: ${JOB}, labels: { app: ${JOB}, run-id: "${RID}" } }
spec:
  completions: ${NNODES}
  parallelism: ${NNODES}
  completionMode: Indexed
  backoffLimit: 0
  template:
    metadata: { labels: { app: ${JOB} } }
    spec:
      subdomain: ${SVC}
      restartPolicy: Never
      hostIPC: true
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - { key: kubernetes.io/hostname, operator: In, values: [${NODES_YAML}] }
      containers:
      - name: trainer
        image: ${IMAGE}
        securityContext: { capabilities: { add: ["IPC_LOCK"] } }
        env:
${ENV_YAML}        - name: NODE_RANK
          valueFrom: { fieldRef: { fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index'] } }
        - name: RANK
          valueFrom: { fieldRef: { fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index'] } }
        - name: SLURM_NODEID
          valueFrom: { fieldRef: { fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index'] } }
        command: ["bash","-lc"]
        args:
        - |
          set -euo pipefail
          ${CD_LINE}
          ${SRC_LINE}
          echo "[k8s] node_rank=\${NODE_RANK} nnodes=\${NNODES} nproc=\${NPROC_PER_NODE} master=\${MASTER_ADDR}"
          # Run the benchmark's own launcher. Most MLPerf entrypoints honor the
          # DGX*/SLURM_*/torchrun env above. If the entry itself calls torchrun,
          # it will use MASTER_ADDR/NNODES/NODE_RANK; otherwise we wrap it.
          entry_file="${ENTRY%% *}"
          if [[ -f "\${entry_file}" ]] && grep -qiE 'torchrun|torch.distributed' "\${entry_file}" 2>/dev/null; then
            exec bash -lc "${ENTRY}"
          else
            exec torchrun --nnodes=\${NNODES} --nproc-per-node=\${NPROC_PER_NODE} \
              --node-rank=\${NODE_RANK} --rdzv-backend=c10d \
              --rdzv-endpoint=\${MASTER_ADDR}:\${MASTER_PORT} \
              bash -lc "${ENTRY}"
          fi
        resources:
          limits:
            nvidia.com/gpu: "${GPUS_PER_NODE}"
        volumeMounts:
        - { name: data, mountPath: "/data" }
        - { name: model, mountPath: "/model", readOnly: true }
        - { name: results, mountPath: "/results" }
        - { name: shm, mountPath: /dev/shm }
      volumes:
      - { name: data, hostPath: { path: "${DATADIR}" } }
      - { name: model, hostPath: { path: "${MODEL_PATH}" } }
      - { name: results, hostPath: { path: "${LOGDIR:-${DATADIR}/results}" } }
      - { name: shm, emptyDir: { medium: Memory, sizeLimit: "${SHM_SIZE}" } }
YAML
}


# Verify what Kubernetes actually exposed inside each training pod.  This is
# intentionally non-fatal for the first PoC stage: the result JSON carries the
# verification status so the UI can display PASS/WARN without hiding benchmark
# logs.  Exact GPU identity cannot be pre-asserted here because this Job asks
# Kubernetes for a GPU count, not specific host GPU UUIDs.
BINDING_VERIFY="not_run"
VERIFY_EXPECTED_GPUS="${GPUS_PER_NODE}"
VERIFY_ACTUAL_GPUS=""
VERIFY_ACTUAL_GPU_UUIDS=""
VERIFY_ACTUAL_NICS=""
VERIFY_POD_NODES=""
validate_training_bindings() {
  cm_phase verify_binding
  if [[ "$DRY_RUN" == "true" ]]; then
    BINDING_VERIFY="skipped_dry_run"
    VERIFY_ACTUAL_GPUS="dry-run"
    cm_inf "[verify] dry-run: skip pod GPU/NIC visibility validation"
    return 0
  fi

  local pods
  pods="$(cm_kubectl -n "$NAMESPACE" get pods -l "app=${JOB}"     -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$pods" ]]; then
    BINDING_VERIFY="warn_no_pods"
    cm_warn "[verify] no pods found for app=${JOB}"
    return 0
  fi

  local all_ok="true"
  local pod node actual count uuids nics envs
  while IFS='|' read -r pod node; do
    [[ -n "$pod" ]] || continue
    actual="$(cm_kubectl -n "$NAMESPACE" exec "$pod" -c trainer -- bash -lc '
      nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits 2>/dev/null | sed "s/[[:space:]]//g"
    ' 2>/dev/null || true)"
    count="$(printf '%s
' "$actual" | sed '/^$/d' | wc -l | awk '{print $1}')"
    uuids="$(printf '%s
' "$actual" | awk -F, 'NF>=1{printf "%s%s",(NR>1?",":""),$1}')"
    envs="$(cm_kubectl -n "$NAMESPACE" exec "$pod" -c trainer -- bash -lc '
      printf "NVIDIA_VISIBLE_DEVICES=%s\n" "${NVIDIA_VISIBLE_DEVICES:-}";
      printf "NCCL_IB_HCA=%s\n" "${NCCL_IB_HCA:-}";
      printf "UCX_NET_DEVICES=%s\n" "${UCX_NET_DEVICES:-}";
      if command -v ibdev2netdev >/dev/null 2>&1; then ibdev2netdev 2>/dev/null | awk "{print \$1}" | paste -sd, -; else true; fi
    ' 2>/dev/null || true)"
    nics="$(printf '%s
' "$envs" | tail -n 1 | tr -d ' ')"
    cm_inf "[verify] pod=${pod} node=${node} expected_gpus=${GPUS_PER_NODE} actual_gpus=${count} uuids=${uuids:-<none>}"
    cm_inf "[verify] pod=${pod} env/devices: $(printf '%s' "$envs" | tr '
' ' ' | sed 's/[[:space:]]\+/ /g')"
    [[ "$count" == "$GPUS_PER_NODE" ]] || all_ok="false"
    VERIFY_POD_NODES+="${pod}@${node};"
    VERIFY_ACTUAL_GPUS+="${pod}:${count};"
    VERIFY_ACTUAL_GPU_UUIDS+="${pod}:${uuids};"
    VERIFY_ACTUAL_NICS+="${pod}:${nics};"
  done <<< "$pods"

  if [[ "$all_ok" == "true" ]]; then
    BINDING_VERIFY="pass_count_only"
  else
    BINDING_VERIFY="warn_gpu_count_mismatch"
  fi
  cm_inf "[verify] binding_verify=${BINDING_VERIFY}"
}

apply_stdin() {
  if [[ "$DRY_RUN" == "true" ]]; then cm_inf "[dry-run] kubectl apply -f -"; sed 's/^/  | /'; return 0; fi
  cm_kubectl -n "$NAMESPACE" apply -f -
}

if [[ "$DRY_RUN" == "true" ]]; then
  cm_inf "[dry-run] create ns ${NAMESPACE} if missing"
else
  kc get namespace "$NAMESPACE" >/dev/null 2>&1 || cm_kubectl create namespace "$NAMESPACE" >/dev/null 2>&1 || true
fi
emit_service | apply_stdin
emit_job | apply_stdin

RC=0
if [[ "$DRY_RUN" == "true" ]]; then
  cm_inf "[dry-run] would: kubectl wait + logs -f job/${JOB}"
  validate_training_bindings
else
  cm_phase wait
  cm_kubectl -n "$NAMESPACE" wait --for=condition=ready pod -l "app=${JOB}" --timeout=900s 2>&1 || true
  validate_training_bindings
  cm_phase logs
  cm_kubectl -n "$NAMESPACE" logs -f "job/${JOB}" --all-containers --prefix 2>&1 | tee "${LOG_DIR}/train.log" || true
  cm_phase status
  if cm_kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB}" --timeout=10s >/dev/null 2>&1; then RC=0
  else cm_kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q '[1-9]' && RC=1 || RC=0; fi
fi

STATUS="$([[ "$RC" == "0" ]] && echo success || echo failed)"
cleanup
cm_phase done
cm_emit_json_line MLPerf_RESULT_JSON \
  status "$STATUS" run_id "$RUN_ID" host "$LEADER" benchmark "$BENCHMARK" \
  version "$VERSION" nnodes "$NNODES" gpus_per_node "$GPUS_PER_NODE" \
  nic_bind "$NIC_DEVICES" binding_verify "$BINDING_VERIFY" \
  expected_gpus "$VERIFY_EXPECTED_GPUS" actual_gpus "$VERIFY_ACTUAL_GPUS" \
  actual_gpu_uuids "$VERIFY_ACTUAL_GPU_UUIDS" actual_nics "$VERIFY_ACTUAL_NICS" \
  pod_node "$VERIFY_POD_NODES" exit_code "$RC" log_dir "$LOG_DIR"
exit "$RC"
