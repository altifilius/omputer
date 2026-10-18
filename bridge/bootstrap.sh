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
# Stage pristine pinned sources and merge each patch target without touching live files.
# This accepts both pristine and previously patched installations, retaining unrelated
# private edits. Any conflict aborts the entire cutover before a source file changes.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
git -C "$runtime" apply --numstat "$base/runtime.patch" | while IFS="$(printf '\t')" read -r added removed file; do
  case "$file" in packages/coding-agent/src/*|packages/coding-agent/test/*|sdk/python/omp-rpc/src/omp_rpc/_wire.py|sdk/rust/omp-rpc/src/wire.rs|sdk/go/omp-rpc/wire.go) ;; *) printf '%s\n' "Unsafe runtime patch path: $file" >&2; exit 1 ;; esac
  mkdir -p "$stage/original/$(dirname "$file")" "$stage/desired/$(dirname "$file")"
  if git -C "$runtime" cat-file -e "HEAD:$file" 2>/dev/null; then
    git -C "$runtime" show "HEAD:$file" > "$stage/original/$file"
    cp "$stage/original/$file" "$stage/desired/$file"
  else
    : > "$stage/original/$file"
  fi
done
cp -R "$stage/original" "$stage/previous"
(cd "$stage/previous" && git apply "$base/runtime.previous.patch")
(cd "$stage/desired" && git apply "$base/runtime.patch")
git -C "$runtime" apply --numstat "$base/runtime.patch" | while IFS="$(printf '\t')" read -r added removed file; do
  mkdir -p "$stage/merged/$(dirname "$file")"
  if [ -f "$runtime/$file" ]; then
    if cmp -s "$runtime/$file" "$stage/desired/$file"; then
      cp "$runtime/$file" "$stage/merged/$file"
	elif git merge-file -p "$runtime/$file" "$stage/original/$file" "$stage/desired/$file" > "$stage/merged/$file"; then
	  :
	elif ! git merge-file -p "$runtime/$file" "$stage/previous/$file" "$stage/desired/$file" > "$stage/merged/$file"; then
      printf '%s\n' "Runtime patch conflicts in $file; all existing private changes are preserved. Resolve explicitly." >&2
      exit 1
    fi
  else
    cp "$stage/desired/$file" "$stage/merged/$file"
  fi
done
git -C "$runtime" apply --numstat "$base/runtime.patch" | while IFS="$(printf '\t')" read -r added removed file; do
  mkdir -p "$runtime/$(dirname "$file")"
  cp "$stage/merged/$file" "$runtime/$file"
done
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
