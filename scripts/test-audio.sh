#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Synthetic AVAudioConverter/stream tests; never requests microphone permission.
# Override DEVELOPER_DIR when selecting standalone Command Line Tools.
mkdir -p .build/audio-harness .build/module-cache
swiftc -module-cache-path "$PWD/.build/module-cache" \
  -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  Sources/OpenInsert/Services/StreamingAudioRecorder.swift \
  Tests/AudioHarness.swift \
  -o .build/audio-harness/test-audio
.build/audio-harness/test-audio
