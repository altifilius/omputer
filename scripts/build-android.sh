#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${OMPUTER_BUILD_WORKER:-0}" != '1' ]; then
  exec systemd-run --user --wait --pipe --collect --unit="omputer-android-$PPID-$$" \
    --description='Omputer bounded Android build' --working-directory="$base" \
    --setenv=PATH --setenv=HOME --setenv=OMPUTER_BUILD_WORKER=1 \
    --setenv="OMPUTER_TOOLS_DIR=${OMPUTER_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools}" \
    --setenv="FLUTTER_BIN=${FLUTTER_BIN:-}" --setenv="JAVA_HOME=${JAVA_HOME:-}" \
    --setenv="ANDROID_HOME=${ANDROID_HOME:-}" \
    --property=MemoryHigh=2560M --property=MemoryMax=3G --property=MemorySwapMax=256M \
    --property=CPUQuota=150% --property=TasksMax=192 --property=Nice=10 \
    /usr/bin/sh "$base/scripts/build-android.sh" "$@"
fi
mkdir -p "$base/.packaging"
exec 9>"$base/.packaging/build.lock"
if ! flock -n 9; then
  printf '%s\n' 'Another Omputer build is running; finish it before building Android.' >&2
  exit 1
fi
tools=${OMPUTER_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools}
flutter=${FLUTTER_BIN:-$tools/flutter/bin/flutter}
if [ ! -x "$flutter" ]; then flutter=$(command -v flutter || true); fi
if [ -z "$flutter" ] || [ ! -x "$flutter" ]; then
  printf '%s\n' 'Flutter stable is required; set FLUTTER_BIN or install the isolated toolchain.' >&2
  exit 1
fi
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  if [ -x "$tools/jdk17/bin/java" ]; then export JAVA_HOME=$tools/jdk17; fi
fi
if [ -d "$tools/android-sdk" ]; then export ANDROID_HOME=$tools/android-sdk; fi
cd "$base/mobile"
"$flutter" pub get
"$flutter" analyze
"$flutter" test
if [ "$#" -eq 0 ]; then set -- --release --target-platform android-arm64,android-x64; fi
release=false
for argument in "$@"; do if [ "$argument" = '--release' ]; then release=true; fi; done
if [ "$release" = true ] && [ ! -f android/key.properties ]; then
  printf '%s\n' 'A release-signing identity is required in mobile/android/key.properties; no debug signer is substituted.' >&2
  exit 1
fi
"$flutter" build apk "$@"
if [ "$release" = true ]; then
  mkdir -p "$base/dist"
  pending=$base/dist/.omputer-android.apk.pending
  trap 'rm -f "$pending"' EXIT HUP INT TERM
  install -m 0644 build/app/outputs/flutter-apk/app-release.apk "$pending"
  mv "$pending" "$base/dist/omputer-android.apk"
  printf '%s\n' "Android app: $base/dist/omputer-android.apk"
fi
