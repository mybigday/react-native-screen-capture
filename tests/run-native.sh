#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tests/out
python3 tests/extract-native-probes.py
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework CoreGraphics -framework CoreVideo \
  -Iios/ScreenCapture -Itests/out tests/NativeFailureProbe.m ios/ScreenCapture/RNSCFileStore.m \
  -o tests/out/NativeFailureProbe
tests/out/NativeFailureProbe > tests/out/native-results.json
python3 -c 'import json; r=json.load(open("tests/out/native-results.json")); print("native checks", r["checks"], "passed", r["passed"])'
