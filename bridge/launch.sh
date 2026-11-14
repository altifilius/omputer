#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
runtime=${OMPUTER_OMP_SOURCE:-$data/omputer-tools/omp-18.20.0}
bun=$data/omp-session-resources/build-tools/bun-1.4.4/bun
if [ ! -x "$bun" ] || [ "$("$bun" --version)" != 1.4.4 ]; then
  printf '%s\n' "Required private Bun 1.4.4 is missing: $bun" >&2
  exit 1
fi
PATH=$(dirname "$bun"):$PATH
export PATH
if [ ! -f "$runtime/packages/coding-agent/src/cli.ts" ]; then
  printf '%s\n' "Isolated runtime missing. Run: sh '$base/bootstrap.sh'" >&2
  exit 1
fi
commit=c308970263ae13744ea15ab67302e3dac840e266
if [ -e "$runtime/.git" ]; then
  actual=$(git -C "$runtime" rev-parse HEAD)
elif [ -f "$runtime/.omputer-upstream-commit" ]; then
  actual=$(cat "$runtime/.omputer-upstream-commit")
else
  printf '%s\n' "Unverified runtime source. Run: sh '$base/bootstrap.sh'" >&2
  exit 1
fi
version=$("$bun" -e 'console.log(JSON.parse(await Bun.file(process.argv[1]).text()).version)' "$runtime/packages/coding-agent/package.json")
if [ "$actual" != "$commit" ] || [ "$version" != 18.20.0 ]; then
  printf '%s\n' 'Launch requires the verified OMP 18.20.0 source; no older runtime is substituted.' >&2
  exit 1
fi
# Keep the caller's cwd. OMP provider/account/settings discovery remains unchanged.
# The pinned OMP loader deduplicates resolved extension paths, including daemon-supplied -e.
exec "$bun" "$runtime/packages/coding-agent/src/cli.ts" -e "$base/index.ts" "$@"
