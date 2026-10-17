#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=${OMPUTER_OMP_SOURCE:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools/omp}
if [ ! -f "$runtime/packages/coding-agent/src/cli.ts" ]; then
  printf '%s\n' "Isolated runtime missing. Run: sh '$base/bootstrap.sh'" >&2
  exit 1
fi
# Keep the caller's cwd. OMP provider/account/settings discovery remains unchanged.
# The pinned OMP loader deduplicates resolved extension paths, including daemon-supplied -e.
exec bun "$runtime/packages/coding-agent/src/cli.ts" -e "$base/index.ts" "$@"
