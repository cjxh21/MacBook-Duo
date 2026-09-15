#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/Validation/bin"
swiftc -parse-as-library -O -framework QuartzCore "$PROJECT_DIR/Sources/HingeMotion.swift" "$PROJECT_DIR/Sources/MotionSample.swift" "$PROJECT_DIR/Sources/MotionRecorder.swift" "$PROJECT_DIR/Tools/AnalyzeMotion.swift" -o "$PROJECT_DIR/Validation/bin/analyze-motion"
"$PROJECT_DIR/Validation/bin/analyze-motion" "$@"
