#!/bin/bash
# Runs the tests. They use Swift Testing, which ships with the full Xcode toolchain but
# not with the Command Line Tools, so this points at Xcode for this command only. It
# does not change which toolchain your Mac uses.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# A separate build folder: the app is built with a different toolchain, and the two
# would otherwise keep invalidating each other's builds.
swift test --build-path .build-tests "$@"
