#!/usr/bin/env bash
# scripts/lib_hosts.sh
# -------------------
# Turn host specifications into an ordered list, from --hosts, --hosts-file, or
# both. Order is significant everywhere this is used: the first host is rank 0
# and supplies MASTER_ADDR, so specs are expanded in the order they were given
# on the command line rather than being gathered by kind.
#
# A hosts file is one host per line:
#
#   # rack 3
#   11.111.111.11
#   22.222.222.22    # rank 1
#
# Blank lines and everything after a '#' are ignored. Commas and extra spaces
# are tolerated too, so a file written as a single comma-separated line, or one
# pasted from a --hosts argument, works without editing.
#
# Usage:
#   source lib_hosts.sh
#   HOST_SPECS+=("lit:a,b")     # from --hosts
#   HOST_SPECS+=("file:/path")  # from --hosts-file
#   hosts_expand HOSTS "${HOST_SPECS[@]}"

# hosts_read_file <path> -- prints one host per line.
hosts_read_file() {
  local f="$1"
  [[ -r "$f" ]] || { echo "[ERROR] hosts file not readable: $f" >&2; return 1; }
  # strip comments, then treat commas and any whitespace (including CR from
  # files written on Windows) as separators
  sed -e 's/#.*//' "$f" | tr ',' ' ' | tr -s '[:space:]' '\n' | sed '/^$/d'
}

# hosts_expand <array_name> <spec>... -- fills the named array, in order,
# skipping duplicates. Each spec is "lit:<csv>" or "file:<path>".
hosts_expand() {
  local -n _out="$1"; shift
  local spec kind value h
  local -A _seen=()
  _out=()

  for spec in "$@"; do
    kind="${spec%%:*}"
    value="${spec#*:}"
    case "$kind" in
      lit)  mapfile -t _items < <(printf '%s' "$value" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d') ;;
      file) mapfile -t _items < <(hosts_read_file "$value") || return 1 ;;
      *)    echo "[ERROR] bad host spec: $spec" >&2; return 1 ;;
    esac
    for h in ${_items[@]+"${_items[@]}"}; do
      # Same character set mlperf_run.sh accepts; IPv4 passes as-is.
      [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "[ERROR] invalid host: $h" >&2; return 1; }
      if [[ -n "${_seen[$h]:-}" ]]; then
        echo "[WARN] duplicate host ignored: $h" >&2
        continue
      fi
      _seen[$h]=1
      _out+=("$h")
    done
  done
}
