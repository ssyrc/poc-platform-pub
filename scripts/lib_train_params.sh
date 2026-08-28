#!/usr/bin/env bash
# scripts/lib_train_params.sh
# --------------------------
# Shared parallelism / hyperparameter flags for run_single_node.sh and
# run_multi_node.sh, plus the same feasibility check the container runs.
#
# The launchers take these as environment variables, not flags, and validate
# them inside the container — after the image is pulled and started. Checking
# here means a bad TP/GBS combination fails in a second instead of minutes in.
#
# The relationships, from validate_training_parallel_config in
# mlperf_train_v41.sh / mlperf_train_v51.sh:
#
#   WORLD = GPUS_PER_NODE x NNODES        (multi) or NUM_GPUS (single)
#   DP    = WORLD / (TP x PP x CP)        derived — there is no DP setting
#   requires  TP x PP x CP <= WORLD  and  WORLD % (TP x PP x CP) == 0
#   requires  GBS >= MBS x DP       and  GBS % (MBS x DP) == 0
#   grad_accum = GBS / (MBS x DP)
#
# Defaults if unset, applied inside the container: TP = GPUs per node, PP = 1,
# CP = 1, MBS = 1, GBS = 128, SEQ_LENGTH = 8192.
#
# Usage from a wrapper:
#   source lib_train_params.sh
#   ...  in the arg loop:  if train_param_try "$1" "${2:-}"; then shift "$TRAIN_PARAM_SHIFT"; continue; fi
#   train_params_validate "$WORLD" "$GPUS_PER_NODE"
#   train_params_export

TRAIN_PARAM_SHIFT=0
declare -A TRAIN_PARAMS=()

# Flag -> environment variable the launchers read.
declare -A _TRAIN_PARAM_MAP=(
  [--tp]=TP
  [--pp]=PP
  [--cp]=CP
  [--mbs]=MBS
  [--gbs]=GBS
  [--minibs]=MINIBS
  [--seq-len]=SEQ_LENGTH
  [--max-steps]=MLPERF_MAX_STEPS
  [--val-check-interval]=MLPERF_VAL_CHECK_INTERVAL
  [--limit-val-batches]=MLPERF_LIMIT_VAL_BATCHES
  [--precision]=TRAINER_PRECISION
  [--lr]=LR
  [--warmup-steps]=WARMUP_STEPS
  [--target-log-ppl]=TARGET_LOG_PPL
  [--extra-overrides]=MLPERF_EXTRA_OVERRIDES
  [--grad-accum]=MLPERF_GRAD_ACCUM
)

# Returns 0 and sets TRAIN_PARAM_SHIFT=2 when $1 is one of ours.
train_param_try() {
  local flag="$1" value="${2:-}"
  local var="${_TRAIN_PARAM_MAP[$flag]:-}"
  [[ -n "$var" ]] || { TRAIN_PARAM_SHIFT=0; return 1; }
  [[ -n "$value" ]] || { echo "[ERROR] ${flag} needs a value" >&2; exit 64; }
  TRAIN_PARAMS["$var"]="$value"
  TRAIN_PARAM_SHIFT=2
  return 0
}

_tp_get() {  # $1=var $2=default
  local v="${TRAIN_PARAMS[$1]:-${!1:-}}"
  [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$2"
}

# Mirrors the container-side check so the same combination fails the same way.
train_params_validate() {
  local world="$1" gpus_per_node="$2"
  local tp pp cp mbs gbs mp dp grad

  tp="$(_tp_get TP "$gpus_per_node")"
  pp="$(_tp_get PP 1)"
  cp="$(_tp_get CP 1)"
  mbs="$(_tp_get MBS 1)"

  # GBS is derived from the node count unless it was given. A fixed default
  # cannot be right at every size: DP grows with the nodes, so a constant GBS
  # means each GPU does proportionally less work per step and runs at different
  # node counts stop being comparable. Deriving it keeps grad_accum -- the work
  # per GPU per step -- the same, and at one node it reproduces the previous
  # default of 128 exactly.
  local gbs_explicit=0
  [[ -n "${TRAIN_PARAMS[GBS]:-}" || -n "${GBS:-}" ]] && gbs_explicit=1
  local grad_target; grad_target="$(_tp_get MLPERF_GRAD_ACCUM 128)"
  local gbs
  if (( gbs_explicit )); then
    gbs="$(_tp_get GBS 128)"
  else
    gbs=0   # filled in below, once DP is known
  fi

  local name val
  for name in TP:"$tp" PP:"$pp" CP:"$cp" MBS:"$mbs" GRAD_ACCUM:"$grad_target"; do
    val="${name#*:}"
    [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 ]] || {
      echo "[ERROR] ${name%%:*} must be a positive integer: ${val}" >&2; exit 64; }
  done

  mp=$(( tp * pp * cp ))
  if (( mp > world )); then
    echo "[ERROR] TP*PP*CP=${mp} exceeds world size ${world} (gpus_per_node x nnodes)" >&2
    exit 64
  fi
  if (( world % mp != 0 )); then
    echo "[ERROR] world size ${world} must be divisible by TP*PP*CP=${mp}" >&2
    exit 64
  fi
  dp=$(( world / mp ))

  if (( ! gbs_explicit )); then
    gbs=$(( mbs * dp * grad_target ))
    TRAIN_PARAMS[GBS]="$gbs"
    echo "[INFO] GBS not given; derived ${gbs} = MBS(${mbs}) x DP(${dp}) x grad_accum(${grad_target})"
    echo "[INFO] pass --gbs to fix it, or --grad-accum to change the per-GPU work"
  fi

  [[ "$gbs" =~ ^[0-9]+$ && "$gbs" -ge 1 ]] || {
    echo "[ERROR] GBS must be a positive integer: ${gbs}" >&2; exit 64; }

  if (( gbs < mbs * dp )); then
    echo "[ERROR] GBS=${gbs} must be >= MBS(${mbs}) * DP(${dp}) = $(( mbs * dp ))" >&2
    exit 64
  fi
  if (( gbs % (mbs * dp) != 0 )); then
    local unit=$(( mbs * dp ))
    echo "[ERROR] GBS=${gbs} must be divisible by MBS(${mbs}) * DP(${dp}) = ${unit}" >&2
    echo "[ERROR] nearest valid: $(( gbs / unit * unit )) or $(( (gbs / unit + 1) * unit ))" >&2
    echo "[ERROR] or omit --gbs and it is derived from the node count" >&2
    exit 64
  fi
  grad=$(( gbs / (mbs * dp) ))

  echo "[INFO] parallel: TP=${tp} PP=${pp} CP=${cp} -> DP=${dp} (world=${world})"
  echo "[INFO] batch:    MBS=${mbs} GBS=${gbs} grad_accum=${grad}"
}

train_params_export() {
  local k
  for k in "${!TRAIN_PARAMS[@]}"; do
    export "${k}=${TRAIN_PARAMS[$k]}"
  done
  [[ "${#TRAIN_PARAMS[@]}" -gt 0 ]] && \
    echo "[INFO] overrides: $(for k in "${!TRAIN_PARAMS[@]}"; do printf '%s=%s ' "$k" "${TRAIN_PARAMS[$k]}"; done)"
  return 0
}

train_params_help() {
  cat <<'EOH'
  Parallelism (DP is derived: DP = world / (TP x PP x CP)):
    --tp <N>                 tensor parallel      (default: GPUs per node)
    --pp <N>                 pipeline parallel    (default: 1)
    --cp <N>                 context parallel     (default: 1)
  Batch:
    --mbs <N>                micro batch size     (default: 1)
    --gbs <N>                global batch size
                             omit and it is derived from the node count:
                             MBS x DP x grad-accum
    --grad-accum <N>         per-GPU work per step when --gbs is omitted
                             (default: 128)
    --minibs <N>             mini batch size
  Schedule / model:
    --seq-len <N>            sequence length      (default: 8192)
    --max-steps <N>          training steps
    --val-check-interval <N>
    --limit-val-batches <N>
    --precision <p>          BF16 | BF16-mixed | FP16 | FP8 | FP8_HYBRID
                             llama31_8b accepts bf16 only; anything BF16-like
                             is mapped to it, FP8 goes through model.fp8
    --lr <f>                 learning rate            (v5.1)
    --warmup-steps <N>                                (v5.1)
    --target-log-ppl <f>                              (v5.1)
    --extra-overrides "..."  extra Hydra overrides passed through
EOH
}

# Flags that legitimately take no value; everything else beginning with -- is
# expected to be followed by one.
_PASSTHRU_NO_VALUE=(--dry-run --stop --help -h)

# passthru_validate <arg>... -- refuse a flag whose value is missing.
#
# `--docker-image $IMG` with IMG unset collapses to a bare `--docker-image`.
# It then reaches mlperf_run.sh as the final argument, where `shift 2` runs out
# of arguments, and under `set -e` that exits 1 with nothing printed at all --
# indistinguishable from a broken cluster. Catch it here instead.
passthru_validate() {
  local args=("$@") i a nxt v
  for i in "${!args[@]}"; do
    a="${args[$i]}"
    [[ "$a" == --* ]] || continue
    for v in "${_PASSTHRU_NO_VALUE[@]}"; do
      [[ "$a" == "$v" ]] && continue 2
    done
    nxt="${args[$((i+1))]:-}"
    if [[ -z "$nxt" || "$nxt" == --* ]]; then
      echo "[ERROR] ${a} has no value." >&2
      echo "[ERROR] A shell variable used for it is probably empty -- check with:" >&2
      echo "[ERROR]   echo \"IMG=[\$IMG] TAR=[\$TAR]\"" >&2
      return 64
    fi
  done
  return 0
}
