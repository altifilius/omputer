#!/bin/sh
# Explicit opt-in. Does not alter /usr/bin/omp, provider configuration, or global extension settings.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=18.20.0
commit=c308970263ae13744ea15ab67302e3dac840e266
data=${XDG_DATA_HOME:-$HOME/.local/share}
runtime=${OMPUTER_OMP_SOURCE:-$data/omputer-tools/omp-$version}
bun=$data/omp-session-resources/build-tools/bun-1.4.4/bun
if [ ! -x "$bun" ] || [ "$("$bun" --version)" != 1.4.4 ]; then
  printf '%s\n' "Required private Bun 1.4.4 is missing: $bun" >&2
  exit 1
fi
# Subprocess generators invoking `bun` must use the same private runtime.
PATH=$(dirname "$bun"):$PATH
export PATH
if [ -e "$runtime" ]; then
  if [ -e "$runtime/.git" ]; then
    actual=$(git -C "$runtime" rev-parse HEAD)
  elif [ -f "$runtime/.omputer-upstream-commit" ]; then
    actual=$(cat "$runtime/.omputer-upstream-commit")
  else
    printf '%s\n' "Refusing unverified runtime source: $runtime" >&2
    exit 1
  fi
  if [ "$actual" != "$commit" ]; then
    printf '%s\n' "Expected OMP $version commit $commit; found $actual. Existing source is unchanged." >&2
    exit 1
  fi
  actual_version=$("$bun" -e 'console.log(JSON.parse(await Bun.file(process.argv[1]).text()).version)' "$runtime/packages/coding-agent/package.json")
  if [ "$actual_version" != "$version" ]; then
    printf '%s\n' "Expected source version $version; found $actual_version" >&2
    exit 1
  fi
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
# Read the exact upstream baseline, never HEAD of a privately modified checkout.
objects=$data/omputer-tools/omp
if ! git -C "$objects" cat-file -e "$commit^{commit}" 2>/dev/null; then
  objects=$stage/upstream.git
  git init --bare "$objects" >/dev/null
  git -C "$objects" fetch --depth 1 https://github.com/can1357/oh-my-pi.git "refs/tags/v$version"
  if [ "$(git -C "$objects" rev-parse 'FETCH_HEAD^{commit}')" != "$commit" ]; then
    printf '%s\n' 'Upstream tag does not match the pinned commit; refusing source.' >&2
    exit 1
  fi
fi
mkdir -p "$stage/upstream"
git -C "$objects" archive "$commit" > "$stage/upstream.tar"
tar -xf "$stage/upstream.tar" -C "$stage/upstream"
if [ ! -e "$runtime" ]; then
  mkdir -p "$(dirname "$runtime")"
  printf '%s\n' "$commit" > "$stage/upstream/.omputer-upstream-commit"
  # Do not merge into a concurrently created or unrelated destination.
  if [ -e "$runtime" ]; then
    printf '%s\n' "Runtime destination appeared during bootstrap: $runtime" >&2
    exit 1
  fi
  cp -R "$stage/upstream" "$stage/new-runtime"
  mv -T -n "$stage/new-runtime" "$runtime"
  if [ -e "$stage/new-runtime" ]; then
    printf '%s\n' "Runtime destination appeared during bootstrap: $runtime" >&2
    exit 1
  fi
fi
# Validate the entire target set and resolve every merge before changing a source file.
git apply --numstat "$base/runtime.patch" > "$stage/targets"
while IFS="$(printf '\t')" read -r added removed file; do
  case "$file" in
    packages/coding-agent/src/*|packages/coding-agent/test/*|packages/coding-agent/examples/extensions/resource-queue/*|packages/agent/src/*|packages/agent/test/*|packages/tui/src/*|packages/tui/test/*|packages/utils/src/*|packages/utils/test/*|scripts/ci-release-build-binaries.ts|sdk/python/omp-rpc/src/omp_rpc/_wire.py|sdk/rust/omp-rpc/src/wire.rs|sdk/go/omp-rpc/wire.go) ;;
    *) printf '%s\n' "Unsafe runtime patch path: $file" >&2; exit 1 ;;
  esac
  case "/$file/" in */../*|*/./*|*//*|*\\*) printf '%s\n' "Unsafe runtime patch path: $file" >&2; exit 1 ;; esac
  # Never follow a private source symlink outside the verified runtime tree.
  relative=$file
  while [ "$relative" != . ]; do
    if [ -L "$runtime/$relative" ]; then
      printf '%s\n' "Refusing symlink runtime patch target: $relative" >&2
      exit 1
    fi
    relative=$(dirname "$relative")
  done
  mkdir -p "$stage/original/$(dirname "$file")" "$stage/desired/$(dirname "$file")"
  if [ -f "$stage/upstream/$file" ]; then
    cp "$stage/upstream/$file" "$stage/original/$file"
    cp "$stage/upstream/$file" "$stage/desired/$file"
  else
    : > "$stage/original/$file"
  fi
done < "$stage/targets"
(cd "$stage/desired" && git apply "$base/runtime.patch")
while IFS="$(printf '\t')" read -r added removed file; do
  mkdir -p "$stage/merged/$(dirname "$file")"
  if [ ! -f "$stage/desired/$file" ]; then
    if [ -f "$runtime/$file" ] && ! cmp -s "$runtime/$file" "$stage/original/$file"; then
      printf '%s\n' "Refusing deletion of privately modified runtime file: $file" >&2
      exit 1
    fi
  elif [ -f "$runtime/$file" ]; then
    if cmp -s "$runtime/$file" "$stage/desired/$file"; then
      cp "$runtime/$file" "$stage/merged/$file"
    elif ! git merge-file -p "$runtime/$file" "$stage/original/$file" "$stage/desired/$file" > "$stage/merged/$file"; then
      printf '%s\n' "Runtime patch conflicts in $file; all existing private changes are preserved. Resolve explicitly." >&2
      exit 1
    fi
  else
    cp "$stage/desired/$file" "$stage/merged/$file"
  fi
done < "$stage/targets"
while IFS="$(printf '\t')" read -r added removed file; do
  mkdir -p "$runtime/$(dirname "$file")"
  if [ -f "$stage/desired/$file" ]; then
    cp "$stage/merged/$file" "$runtime/$file"
  else
    rm -f "$runtime/$file"
  fi
done < "$stage/targets"
(cd "$runtime" && "$bun" install --frozen-lockfile --ignore-scripts)
# Embed only authentic, matching-version variants; never rename modern as baseline.
native_cache=${PI_NATIVES_DIR:-$HOME/.omp/natives}/$version
native_dest=$runtime/packages/natives/native
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) native_pattern='pi_natives.linux-x64-*.node' ;;
  Linux:aarch64) native_pattern='pi_natives.linux-arm64.node' ;;
  *) printf '%s\n' 'This bootstrap supports Linux x64/arm64 PCs only.' >&2; exit 1 ;;
esac
for addon in "$native_cache"/$native_pattern; do
  [ -f "$addon" ] || continue
  cp "$addon" "$native_dest/$(basename "$addon")"
done
found=0
for addon in "$native_dest"/$native_pattern; do
  [ ! -f "$addon" ] || found=1
done
if [ "$found" != 1 ]; then
  printf '%s\n' "Missing matching $version native addon. Run installed omp once or build the matching native package." >&2
  exit 1
fi
(cd "$runtime" && "$bun" run gen:tool-views)
printf '%s\n' "Runtime ready: $runtime/packages/coding-agent/src/cli.ts" "Launch: OMPUTER_OMP_SOURCE='$runtime' sh '$base/launch.sh' [OMP arguments]"
