#!/bin/bash
# Syntax-only Apple SDK checks with an explicitly labelled minimal React boundary.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tests/out
failures=0
for sdk in iphoneos appletvos; do
  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
  if [ "$sdk" = iphoneos ]; then target=arm64-apple-ios15.1; else target=arm64-apple-tvos15.1; fi
  for source in ios/ScreenCapture/*.m ios/ScreenCapture/*.mm; do
    log="tests/out/${sdk}-$(basename "$source")-syntax.log"
    if ! xcrun clang -fsyntax-only -fobjc-arc -fblocks -target "$target" -isysroot "$sdk_path" \
      -Itests/BridgeShim -Iios/ScreenCapture "$source" > "$log" 2>&1; then
      failures=$((failures + 1))
      cat "$log"
    fi
  done
done
printf 'Apple SDK syntax failures=%s\n' "$failures"
exit "$failures"
