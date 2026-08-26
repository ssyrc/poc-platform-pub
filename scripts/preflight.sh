#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/preflight.sh
# -------------------
# Check everything an MLPerf run needs before starting one, and report all
# problems at once.
#
# mlperf_run.sh --dry-run already validates the same ground, but it stops at
# the first missing piece, so a fresh deployment surfaces one problem per
# attempt. This walks the whole list, prints a ready-to-paste mlperf_run.sh
# command for what passed, and exits non-zero if anything required is missing.
# It reads only — nothing here starts a container or writes to the data root.
#
# Usage:
#   preflight.sh                      # check every suite/version
#   preflight.sh training v5.1        # check one target
#   MLPERF_ROOT=/path preflight.sh    # override the platform root
#
# Exit: 0 all required checks passed, 1 something required is missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh loads .env the same way the real launchers do, so this sees the
# same MLPERF_ROOT / DOCKER_HUB_IMAGE_PREFIX values they will.
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh" 2>/dev/null || true

MLPERF_ROOT="${MLPERF_ROOT:-${POC_PLATFORM_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}}"
DATA_ROOT="${MLPERF_DATA_ROOT:-${DATA_ROOT:-${MLPERF_ROOT}/data}}"
DOCKERIMG_DIR="${DATA_ROOT}/dockerimgs"
HUB="${DOCKER_HUB_IMAGE_PREFIX:-docker.io}"

WANT_SUITE="${1:-all}"
WANT_VERSION="${2:-all}"

FAIL=0
WARN=0
DETECTED_GPU_TYPE=""
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

ok()   { printf '  %sOK  %s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { printf '  %sMISS%s %s\n' "$RED" "$RESET" "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  %sWARN%s %s\n' "$YELLOW" "$RESET" "$1"; WARN=$((WARN+1)); }
note() { printf '       %s%s%s\n' "$DIM" "$1" "$RESET"; }
head_() { printf '\n\033[1m[%s]\033[0m\n' "$1"; }

need_dir()  { if [[ -d "$1" ]]; then ok "$2"; else bad "$2"; note "$1"; fi; }
need_file() { if [[ -s "$1" ]]; then ok "$2"; else bad "$2"; note "$1"; fi; }

# An image is satisfied either by being loaded already or by having its offline
# tar staged; the launchers try the tar before falling back to docker pull.
# Mirrors the launchers' fallback so this check agrees with what a run does.
resolve_tar() {
  local t="$1" base d
  [[ -n "$t" ]] || return 0
  if [[ -s "$t" ]]; then printf '%s' "$t"; return 0; fi
  base="$(basename "$t")"
  IFS=':' read -ra dirs <<< "${POC_PLATFORM_DOCKERIMG_DIRS:-}"
  for d in "${dirs[@]}"; do
    [[ -n "$d" ]] || continue
    if [[ -s "${d}/${base}" ]]; then printf '%s' "${d}/${base}"; return 0; fi
  done
  printf '%s' "$t"
}

check_image() {
  local image="$1" label="$3" tar_file
  tar_file="$(resolve_tar "$2")"
  if docker image inspect "$image" >/dev/null 2>&1; then
    ok "$label — image present locally"
  elif [[ -s "$tar_file" ]]; then
    ok "$label — not loaded, offline tar present"
    note "docker load -i ${tar_file}"
  else
    bad "$label — neither image nor tar"
    note "image: ${image}"
    note "tar  : ${tar_file}"
  fi
}

want() {  # $1=suite $2=version
  [[ "$WANT_SUITE" == "all" || "$WANT_SUITE" == "$1" ]] || return 1
  [[ "$WANT_VERSION" == "all" || "$WANT_VERSION" == "$2" ]] || return 1
  return 0
}

# --- host ------------------------------------------------------------------
head_ "host"
printf '  MLPERF_ROOT = %s\n  DATA_ROOT   = %s\n\n' "$MLPERF_ROOT" "$DATA_ROOT"

need_dir "$MLPERF_ROOT" "platform root"
need_dir "$DATA_ROOT" "data root"
need_dir "$DOCKERIMG_DIR" "docker image tar dir"

if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
  ok ".env present"
else
  warn ".env missing — site-specific values fall back to defaults"
  note "cp .env.example .env"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    bad "docker present but daemon not reachable"
  fi
else
  bad "docker not found"
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  # Map the marketing name onto the --gpu-type value the launchers accept, so
  # the suggested command below is right without hand-editing.
  case "$(printf '%s' "$gpu_name" | tr '[:lower:]' '[:upper:]')" in
    *GH200*)      DETECTED_GPU_TYPE="GH200" ;;
    *B300*)       DETECTED_GPU_TYPE="B300" ;;
    *B200*)       DETECTED_GPU_TYPE="B200" ;;
    *H200*|*H100*) DETECTED_GPU_TYPE="H100" ;;
    *A100*)       DETECTED_GPU_TYPE="A100" ;;
    *V100*)       DETECTED_GPU_TYPE="V100" ;;
    *"RTX PRO 6000"*) DETECTED_GPU_TYPE="RTX_PRO_6000" ;;
    *)            DETECTED_GPU_TYPE="" ;;
  esac
  gpu_n="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 0)"
  drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
  ok "nvidia-smi — ${gpu_n} x ${gpu_name:-unknown}, driver ${drv:-unknown}"
  # Inference v6.0 silently drops to the v5.1 image below this driver.
  drv_major="${drv%%.*}"
  if [[ "$drv_major" =~ ^[0-9]+$ && "$drv_major" -lt 590 ]]; then
    note "driver < 590: inference v6.0 will fall back to the v5.1 image"
  fi
else
  bad "nvidia-smi not found"
fi

printf '  arch        = %s\n' "$(uname -m)"

# --- training v4.1 ---------------------------------------------------------
if want training v4.1; then
  head_ "training v4.1 — llama2_70b_lora"
  need_dir "${MLPERF_ROOT}/training_results_v4.1-main/NVIDIA/benchmarks/llama2_70b_lora/implementations/h200_ngc24.09_nemo" "benchmark repo"
  need_dir "${DATA_ROOT}/training_llama2_70b_lora_v41/gov_report" "dataset (gov_report)"
  need_dir "${DATA_ROOT}/training_llama2_70b_lora_v41/model_nemo" "model (model_nemo)"
  need_file "${DATA_ROOT}/training_llama2_70b_lora_v41/model_nemo/model_config.yaml" "model_config.yaml"
  if compgen -G "${DATA_ROOT}/training_llama2_70b_lora_v41/model_nemo/*_tokenizer.model" >/dev/null; then
    ok "converted tokenizer"
  else
    bad "converted tokenizer (*_tokenizer.model)"
  fi
  check_image "${HUB}/myhomerepo/mlperf-nvidia:llama2_70b_lora-pyt" \
              "${DOCKERIMG_DIR}/llama2_70b_lora-pyt-v4.1.tar" "image (V100/A100/H100)"
  note "GH200 uses wahabk/...:llama2_70b_lora-pyt3 (arm64)"
  note "B300 has no default image — pass --docker-image or set IMAGE_B300_AMD64"
fi

# --- training v5.1 ---------------------------------------------------------
if want training v5.1; then
  head_ "training v5.1 — llama2_70b_lora"
  need_dir "${MLPERF_ROOT}/training_results_v5.1-main/NVIDIA/benchmarks/llama2_70b_lora/implementations/nemo" "benchmark repo"
  need_file "${DATA_ROOT}/training_llama2_70b_lora/data/train.npy" "train.npy"
  need_file "${DATA_ROOT}/training_llama2_70b_lora/data/validation.npy" "validation.npy"
  need_dir "${DATA_ROOT}/training_llama2_70b_lora/model" "model dir"
  check_image "${HUB}/donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90" \
              "${DOCKERIMG_DIR}/mlperf-nvidia_llama2_70b_lora-pyt-sm90.tar.gz" "image (all but GH200)"

  head_ "training v5.1 — llama31_8b"
  need_dir "${MLPERF_ROOT}/training_results_v5.1-main/NVIDIA/benchmarks/llama31_8b/implementations/nemo" "benchmark repo"
  need_dir "${DATA_ROOT}/training_llama31_8b/8b" "dataset"
  check_image "${HUB}/donnmyth/mlperf-nvidia:llama31_8b-pyt-sm90" \
              "${DOCKERIMG_DIR}/llama31_8b-pyt-sm90.tar" "image (all but GH200)"
fi

# --- inference v5.1 --------------------------------------------------------
if want inference v5.1; then
  head_ "inference v5.1 — llama2_70b"
  need_dir "${MLPERF_ROOT}/inference_results_v5.1-main/closed/NVIDIA" "benchmark repo"
  need_dir "${DATA_ROOT}/inference_llama2_70b/model" "base model"
  need_dir "${DATA_ROOT}/inference_llama2_70b/preprocessed_data" "preprocessed data"
  need_dir "${DATA_ROOT}/inference_llama2_70b/open_orca" "open_orca"
  check_image "${NVCR_PULL_PREFIX:-nvcr.io}/nvidia/mlperf/mlperf-inference:mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64" \
              "${DOCKERIMG_DIR}/mlperf-inference_mlpinf-v5.1-cuda12.9-pytorch25.05-ubuntu24.04-x86_64.tar" "image (x86_64)"
fi

# --- inference v6.0 --------------------------------------------------------
if want inference v6.0; then
  head_ "inference v6.0 — llama2_70b"
  need_dir "${MLPERF_ROOT}/inference_results_v6.0-main/closed/NVIDIA" "benchmark repo"
  need_dir "${DATA_ROOT}/inference_llama2_70b/model" "base model"
  need_dir "${DATA_ROOT}/inference_llama2_70b/preprocessed_data" "preprocessed data"
  if [[ -d "${DATA_ROOT}/inference_llama2_70b/model_fp4" ]]; then
    ok "FP4 quantized model"
  else
    # v6.0 warns and lets the NVIDIA prebuild flow proceed rather than failing.
    warn "FP4 quantized model absent — v6.0 warns and continues"
    note "${DATA_ROOT}/inference_llama2_70b/model_fp4"
  fi
  check_image "${NVCR_PULL_PREFIX:-nvcr.io}/nvidia/mlperf/mlperf-inference:tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_x86" \
              "${DOCKERIMG_DIR}/mlperf-inference_tensorrt_llm_release-feat-1.2-mlpinf-b5ddff4_mlperf-main-f538816_jan28_x86.tar" "image (x86_64)"
fi

# --- summary ---------------------------------------------------------------
head_ "summary"
printf '  missing: %d   warnings: %d\n\n' "$FAIL" "$WARN"

if [[ "$FAIL" -eq 0 ]]; then
  gpu="${GPU_TYPE:-${DETECTED_GPU_TYPE:-H100}}"
  host="$(hostname -s 2>/dev/null || echo localhost)"
  cat <<EOS
  Ready. Start a run with (adjust --gpu-type and --hosts):

    ${SCRIPT_DIR}/mlperf_run.sh \\
      --run-id \$(date +%Y%m%d_%H%M%S) \\
      --suite training --version v5.1 --benchmark llama2_70b_lora \\
      --gpu-type ${gpu} --hosts ${host} \\
      --dry-run

  Drop --dry-run to run for real. Stop with the same command plus --stop.
EOS
else
  echo "  Fix the MISS entries above, then re-run this check."
fi

exit $(( FAIL > 0 ? 1 : 0 ))
