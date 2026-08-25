#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/llmd/llmd_run.sh
# ------------------------
# Top-level dispatcher for the merged "llm-d Inference" tab.  It validates the
# request, derives a leader host (for log/stdout attribution), and hands off to
# scripts/llmd/llmd_serve.sh which deploys llm-d on Kubernetes and benchmarks
# it.  A single tab covers both:
#
#   --mode serve : plain llm-d serving + vllm bench serve
#   --mode pd    : prefill/decode disaggregation + vllm bench serve
#
# Output is prefixed with [<leader>] to match the host-attribution contract
# used by mlperf_run.sh / vllm_run.sh / pd_run.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

TARGET="${SCRIPT_DIR}/llmd_serve.sh"
[[ -x "$TARGET" ]] || cm_die "llmd_serve.sh not executable: $TARGET"

MODE_OP=""              # "" | --stop (passthrough)
SERVE_MODE="serve"
HOSTS_CSV=""
PASSTHRU=()

# Collect everything; we only need to peek at --mode and --hosts to pick a
# leader, then forward all flags verbatim to llmd_serve.sh.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) MODE_OP="--stop"; PASSTHRU+=("$1"); shift ;;
    --mode) SERVE_MODE="${2:-}"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --hosts) HOSTS_CSV="${2:-}"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --dry-run) PASSTHRU+=("$1"); shift ;;
    -h|--help) echo "usage: llmd_run.sh --mode serve|pd --run-id <id> --hosts <node> --model ... (see llmd_serve.sh header)"; exit 0 ;;
    *)
      # value-bearing flag: forward flag + its value when present
      if [[ "${2:-}" == --* || -z "${2:-}" ]]; then
        PASSTHRU+=("$1"); shift
      else
        PASSTHRU+=("$1" "$2"); shift 2
      fi
      ;;
  esac
done

case "$SERVE_MODE" in serve|pd) ;; *) cm_die "--mode must be serve|pd";; esac

[[ -n "$HOSTS_CSV" ]] || cm_die "--hosts required (worker node(s) running the pods to monitor)"
IFS=',' read -ra _h <<< "$HOSTS_CSV"
for h in "${_h[@]}"; do cm_validate_host "$h"; done
LEADER="${_h[0]}"

# Tell llmd_serve.sh which host owns the summary line.
PASSTHRU+=(--leader "$LEADER")

cm_phase dispatch
cm_inf "mode=${SERVE_MODE} leader=${LEADER} op=${MODE_OP:-run}"

set +e
"$TARGET" "${PASSTHRU[@]}" 2>&1 | sed -u "s/^/[${LEADER}] /"
RC="${PIPESTATUS[0]}"
set -e

cm_phase done
exit "$RC"
