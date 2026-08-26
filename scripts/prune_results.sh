#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/prune_results.sh
# ------------------------
# Reclaim space in the MLPerf results trees under ${POC_PLATFORM_ROOT} by
# setting aside the vendor directories this platform never reads.
#
# Only NVIDIA paths are referenced by the benchmark scripts:
#   inference_results_v5.1-main/closed/NVIDIA          (mlperf_infer_v51.sh)
#   inference_results_v6.0-main/closed/NVIDIA          (mlperf_infer_v60.sh)
#   training_results_v4.1-main/NVIDIA/...              (mlperf_train_v41.sh)
#   training_results_v5.1-main/NVIDIA/...              (mlperf_train_v51.sh)
# Note the asymmetry: inference results split into closed/open/network
# divisions before the vendor, training results put the vendor at the top.
#
# Entries are MOVED into <root>/_quarantine, never deleted, and the original
# directory layout is reproduced there so a rollback is one tar. Delete the
# quarantine yourself once a Training and an Inference run have both passed —
# an MLPerf harness can reach for a sibling path at runtime in ways a static
# read of these scripts would not reveal.
#
# Usage:
#   prune_results.sh <root>                 # dry run, lists what would move
#   prune_results.sh <root> --apply         # actually move
#   KEEP="NVIDIA AMD" prune_results.sh ...  # override the keep list
#
# Rollback:
#   cd <root>/_quarantine && tar cf - . | ( cd .. && tar xf - ) \
#     && cd .. && rm -rf _quarantine
#
# Vendor directory names differ between submission rounds and are matched
# exactly, case included. Run the dry run first and check that everything you
# meant to keep is absent from the list; if a name you wanted is listed, it is
# spelled differently in that round (Google vs GoogleCloud, and so on).

ROOT="${1:-}"
APPLY="${2:-}"

if [[ -z "$ROOT" ]]; then
  echo "usage: $(basename "$0") <root> [--apply]" >&2
  echo "  root: directory holding inference_results_* / training_results_*" >&2
  exit 64
fi
if [[ ! -d "$ROOT" ]]; then
  echo "[ERROR] not a directory: $ROOT" >&2
  exit 66
fi

ROOT="$(cd "$ROOT" && pwd)"
read -r -a KEEP_LIST <<< "${KEEP:-NVIDIA AMD Google}"
QUARANTINE="${ROOT}/_quarantine"
MOVED=0
SKIPPED=0

in_keep() {
  local name="$1" k
  for k in "${KEEP_LIST[@]}"; do
    [[ "$name" == "$k" ]] && return 0
  done
  return 1
}

move_one() {
  local src="$1" dest="$2"
  if [[ "$APPLY" == "--apply" ]]; then
    mkdir -p "$(dirname "$dest")"
    mv -- "$src" "$dest"
    echo "  moved   ${src#$ROOT/}"
  else
    echo "  would move   ${src#$ROOT/}"
  fi
  MOVED=$((MOVED + 1))
}

# Walk one directory of vendor entries. Directories, files and dotfiles all
# count — anything not in the keep list is set aside.
scan_dir() {
  local dir="$1" entry name
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    if in_keep "$name"; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    move_one "$entry" "${QUARANTINE}/${entry#$ROOT/}"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 | sort -z)
}

echo "[INFO]  root:  $ROOT"
echo "[INFO]  keep:  ${KEEP_LIST[*]}"
if [[ "$APPLY" == "--apply" ]]; then
  echo "[INFO]  mode:  apply (moving into ${QUARANTINE#$ROOT/}/)"
else
  echo "[INFO]  mode:  dry run — pass --apply to move"
fi
echo

found_tree=0
for tree in "$ROOT"/inference_results_*; do
  [[ -d "$tree" ]] || continue
  found_tree=1
  echo "[$(basename "$tree")]"
  # closed/open/network sit between the tree root and the vendor.
  for division in closed open network; do
    scan_dir "$tree/$division"
  done
done

for tree in "$ROOT"/training_results_*; do
  [[ -d "$tree" ]] || continue
  found_tree=1
  echo "[$(basename "$tree")]"
  # No division level here — vendors are directly under the tree root, so the
  # tree's own README/LICENSE are swept up too unless added to KEEP.
  scan_dir "$tree"
done

if [[ "$found_tree" -eq 0 ]]; then
  echo "[WARN] no inference_results_* or training_results_* under $ROOT" >&2
  exit 0
fi

echo
echo "[OK]    kept ${SKIPPED}, $([[ "$APPLY" == "--apply" ]] && echo "moved" || echo "would move") ${MOVED}"
if [[ "$APPLY" != "--apply" ]]; then
  echo "[INFO]  re-run with --apply once the list looks right"
elif [[ "$MOVED" -gt 0 ]]; then
  echo "[INFO]  verify with a Training and an Inference run, then: rm -rf ${QUARANTINE}"
fi
