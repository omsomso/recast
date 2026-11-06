#!/bin/sh
# Runs the engine tests. Uses Xcode's toolchain when Xcode is installed (see build.sh).
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift test "$@"
