#!/usr/bin/env bash
# scripts/lib_image_prep.sh
# ------------------------
# Make sure every host has the image loaded before any of them starts a
# container.
#
# Checking that a tar exists is not enough. The hosts that already have the
# image launch and enter the rendezvous immediately, while a host still
# unpacking a tens-of-gigabytes tar arrives minutes later -- or never, if its
# docker run fails outright. Rank 0 then times out waiting for members and
# closes the store, and every other host reports a broken pipe:
#
#   RendezvousTimeoutError                              (on rank 0)
#   TCPStore ... Broken pipe ... remote=[rank0]:29500   (on the rest)
#
# which says nothing about the host that never showed up. So the load happens
# here, up front, and nothing starts until all of them have finished.
#
# Loads run in parallel: sequentially would cost the size of the tar times the
# number of nodes. Nothing is copied between machines -- each host loads from a
# tar it can already read, at the given path or by basename under
# POC_PLATFORM_DOCKERIMG_DIRS, the same resolution ensure_image uses.
#
# Usage:
#   source lib_image_prep.sh
#   image_prep_hosts "<image>" "<tar>" host1 host2 ...   # returns 1 on failure
#
# Requires cm_remote_bash from common.sh.

image_prep_hosts() {
  local img="$1" tar="$2"; shift 2
  local hosts=("$@")
  local i h verdict rc=0

  [[ -n "$img" || -n "$tar" ]] || return 0
  [[ "${#hosts[@]}" -gt 0 ]] || return 0

  echo "[INFO] preparing image on ${#hosts[@]} host(s): ${img:-<launcher default>}"
  local status_dir; status_dir="$(mktemp -d)"

  for i in "${!hosts[@]}"; do
    h="${hosts[$i]}"
    (
      out="$(cm_remote_bash "$h" <<PREP 2>&1
set -uo pipefail
img="${img}"
tar="${tar}"
dirs="${POC_PLATFORM_DOCKERIMG_DIRS:-}"

if [[ -n "\$img" ]] && docker image inspect "\$img" >/dev/null 2>&1; then
  echo "PRESENT"; exit 0
fi

found=""
[[ -n "\$tar" && -r "\$tar" ]] && found="\$tar"
if [[ -z "\$found" && -n "\$tar" && -n "\$dirs" ]]; then
  base="\$(basename "\$tar")"
  IFS=':' read -ra dd <<< "\$dirs"
  for d in "\${dd[@]}"; do
    [[ -n "\$d" && -r "\${d}/\${base}" ]] && { found="\${d}/\${base}"; break; }
  done
fi
[[ -n "\$found" ]] || { echo "NOTAR"; exit 0; }

load_out="\$(docker load -i "\$found" 2>&1)" || { echo "\$load_out"; echo "LOADFAIL"; exit 0; }

if [[ -n "\$img" ]] && docker image inspect "\$img" >/dev/null 2>&1; then
  echo "LOADED \$found"; exit 0
fi
# The tag inside the tar need not match the one the caller will ask for.
ref="\$(echo "\$load_out" | awk -F': ' '/Loaded image:/ {print \$2}' | tail -n 1)"
if [[ -n "\$img" && -n "\$ref" ]]; then
  docker tag "\$ref" "\$img" >/dev/null 2>&1 || true
  docker image inspect "\$img" >/dev/null 2>&1 && { echo "LOADED \$found"; exit 0; }
fi
echo "TAGMISS \${ref:-<none>}"
PREP
)"
      printf '%s' "$out" > "${status_dir}/${i}.out"
      printf '%s' "$(printf '%s' "$out" | tail -1 | tr -d '\r')" > "${status_dir}/${i}"
    ) &
  done

  # No host may start until every load has finished.
  wait

  for i in "${!hosts[@]}"; do
    h="${hosts[$i]}"
    verdict="$(cat "${status_dir}/${i}" 2>/dev/null || echo "")"
    case "$verdict" in
      PRESENT)  echo "  ${h}: already loaded" ;;
      LOADED*)  echo "  ${h}: loaded from ${verdict#LOADED }" ;;
      NOTAR)
        echo "  ${h}: [FAIL] no image, and no readable tar on this host" >&2
        echo "         looked for: ${tar:-<none>}" >&2
        rc=1 ;;
      LOADFAIL)
        echo "  ${h}: [FAIL] docker load failed" >&2
        sed 's/^/         /' "${status_dir}/${i}.out" >&2
        rc=1 ;;
      TAGMISS*)
        echo "  ${h}: [FAIL] tar loaded ${verdict#TAGMISS } but ${img} is still missing" >&2
        rc=1 ;;
      *)
        echo "  ${h}: [FAIL] unexpected result: ${verdict:-<empty>}" >&2
        sed 's/^/         /' "${status_dir}/${i}.out" 2>/dev/null >&2
        rc=1 ;;
    esac
  done
  rm -rf "$status_dir"

  if (( rc != 0 )); then
    echo >&2
    echo "[ERROR] not every host has the image; not starting." >&2
    echo "[ERROR] stage the tar where the host can read it, or point" >&2
    echo "[ERROR] POC_PLATFORM_DOCKERIMG_DIRS at a directory it is in." >&2
    return 1
  fi
  echo "[INFO] image ready on all ${#hosts[@]} host(s)"
  return 0
}
