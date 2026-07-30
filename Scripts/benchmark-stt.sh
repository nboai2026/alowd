#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SAMPLE_DIR="${1:-samples}"
echo "Benchmarking Alowd STT samples in ${SAMPLE_DIR}"
env CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
  swift test --disable-sandbox \
  --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security" \
  --manifest-cache local \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  --filter TranscriptionEngineTests
