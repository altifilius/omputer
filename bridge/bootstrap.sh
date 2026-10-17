#!/bin/sh
# Explicit opt-in. Does not alter /usr/bin/omp, provider configuration, or global extension settings.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime=${OMPUTER_OMP_SOURCE:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools/omp}
commit=c8913466dd7bf92040de911f8e00e30b8f4e48a2
if [ ! -d "$runtime/.git" ]; then
  if [ -e "$runtime" ]; then
    printf '%s\n' "Refusing existing non-Git runtime path: $runtime" >&2
    exit 1
  fi
  git clone --depth 1 --branch v18.10.2 https://github.com/can1357/oh-my-pi.git "$runtime"
fi
actual=$(git -C "$runtime" rev-parse HEAD)
if [ "$actual" != "$commit" ]; then
  printf '%s\n' "Expected OMP v18.10.2 commit $commit; found $actual. Refusing to modify another runtime." >&2
  exit 1
fi
if git -C "$runtime" apply --check "$base/runtime.patch" 2>/dev/null; then
  git -C "$runtime" apply "$base/runtime.patch"
elif ! git -C "$runtime" apply --reverse --check "$base/runtime.patch" 2>/dev/null; then
  printf '%s\n' 'Runtime export patch conflicts; preserve local changes and resolve explicitly.' >&2
  exit 1
fi
(cd "$runtime" && bun install --frozen-lockfile --ignore-scripts)
# Source loading searches the workspace native directory, not the binary extraction cache.
native_cache=${PI_NATIVES_DIR:-$HOME/.omp/natives}/18.10.2
native_dest=$runtime/packages/natives/native
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) native_file=pi_natives.linux-x64-baseline.node ;;
  Linux:aarch64) native_file=pi_natives.linux-arm64.node ;;
  *) printf '%s\n' 'This bootstrap supports Linux x64/arm64 PCs only.' >&2; exit 1 ;;
esac
if [ -f "$native_cache/$native_file" ]; then
  cp "$native_cache/$native_file" "$native_dest/$native_file"
elif [ ! -f "$native_dest/$native_file" ]; then
  printf '%s\n' "Missing matching native addon. Run installed omp once, then retry; or build: bun --cwd='$runtime/packages/natives' run build" >&2
  exit 1
fi
(cd "$runtime" && bun run gen:tool-views)
printf '%s\n' "Runtime ready: $runtime/packages/coding-agent/src/cli.ts" "Launch: OMPUTER_OMP_SOURCE='$runtime' sh '$base/launch.sh' [OMP arguments]"
