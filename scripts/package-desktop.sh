#!/bin/sh
# Build-time only. End users open the resulting Omputer executable; no developer tools needed.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${OMPUTER_OMP_SOURCE:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools/omp}
if [ ! -f "$runtime/packages/coding-agent/binaries/omp-linux-x64" ]; then
  sh "$base/bridge/bootstrap.sh"
  (cd "$runtime" && bun scripts/ci-release-build-binaries.ts --targets linux-x64)
fi
stage=$base/.packaging/desktop
mkdir -p "$stage/resources/bridge" "$base/dist"
install -m 0755 "$runtime/packages/coding-agent/binaries/omp-linux-x64" "$stage/resources/omp-runtime"
for name in index.ts dialogs.ts ipc.ts wire.ts package.json; do
  install -m 0644 "$base/bridge/$name" "$stage/resources/bridge/$name"
done
archive=$base/.packaging/desktop-resources.tar.zst
tar --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner -C "$stage" -cf - resources | zstd -T2 -9 -f -o "$archive"
OMPUTER_EMBED_RESOURCES="$archive" cargo build --manifest-path "$base/Cargo.toml" --release
install -m 0755 "$base/target/release/omputer" "$base/dist/Omputer"
printf '%s\n' "Desktop app: $base/dist/Omputer" 'Open the application; it installs its own runtime and starts its local service.'
