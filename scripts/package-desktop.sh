#!/bin/sh
# Build-time only. End users open the resulting Omputer executable; no developer tools needed.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${OMPUTER_BUILD_WORKER:-0}" != '1' ]; then
  exec systemd-run --user --wait --pipe --collect --unit="omputer-package-$PPID-$$" \
    --description='Omputer bounded desktop packaging' --working-directory="$base" \
    --setenv=PATH --setenv=HOME --setenv=OMPUTER_BUILD_WORKER=1 \
    --setenv="OMPUTER_OMP_SOURCE=${OMPUTER_OMP_SOURCE:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools/omp}" \
    --property=MemoryHigh=2G --property=MemoryMax=3G --property=MemorySwapMax=256M \
    --property=CPUQuota=150% --property=TasksMax=192 --property=Nice=10 \
    /usr/bin/sh "$base/scripts/package-desktop.sh" "$@"
fi
mkdir -p "$base/.packaging" "$base/dist"
exec 9>"$base/.packaging/build.lock"
if ! flock -n 9; then
  printf '%s\n' 'Another Omputer build is running; finish it before packaging.' >&2
  exit 1
fi
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-1}
runtime=${OMPUTER_OMP_SOURCE:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools/omp}
# Validate/apply the pinned runtime patch even when an older compiled binary exists.
sh "$base/bridge/bootstrap.sh"
(cd "$runtime" && bun scripts/ci-release-build-binaries.ts --targets linux-x64)
"$runtime/packages/coding-agent/binaries/omp-linux-x64" --version
stage=$base/.packaging/desktop
mkdir -p "$stage/resources/bridge" "$base/dist"
install -m 0755 "$runtime/packages/coding-agent/binaries/omp-linux-x64" "$stage/resources/omp-runtime"
for name in "$base"/bridge/*.ts "$base"/bridge/package.json; do
  case "$name" in *.test.ts) continue ;; esac
  install -m 0644 "$name" "$stage/resources/bridge/$(basename "$name")"
done
bun "$base/scripts/component-versions.ts" "$base" "$runtime" "$stage/resources/component-versions.json"
archive=$base/.packaging/desktop-resources.tar.zst
pending_archive=$archive.pending
pending_executable=$base/dist/.Omputer.pending
trap 'rm -f "$pending_archive" "$pending_executable"' EXIT HUP INT TERM
tar --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner -C "$stage" -cf - resources | zstd -T1 -9 -f -o "$pending_archive"
mv "$pending_archive" "$archive"
OMPUTER_EMBED_RESOURCES="$archive" cargo build --manifest-path "$base/Cargo.toml" --release
install -m 0755 "$base/target/release/omputer" "$pending_executable"
mv "$pending_executable" "$base/dist/Omputer"
printf '%s\n' "Desktop app: $base/dist/Omputer" 'Open the application; it installs its own runtime and starts its local service.'
