#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tools=${OMPUTER_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omputer-tools}
flutter=${FLUTTER_BIN:-$tools/flutter/bin/flutter}
if [ ! -x "$flutter" ]; then flutter=$(command -v flutter); fi
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  if [ -x "$tools/jdk17/bin/java" ]; then export JAVA_HOME=$tools/jdk17; fi
fi
if [ -d "$tools/android-sdk" ]; then export ANDROID_HOME=$tools/android-sdk; fi
cd "$base/mobile"
"$flutter" pub get
"$flutter" analyze
"$flutter" test
if [ "$#" -eq 0 ]; then set -- --debug; fi
"$flutter" build apk "$@"
