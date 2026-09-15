#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
TEST_DIR=$(mktemp -d /tmp/macbook-duo-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library "$PROJECT_DIR/Sources/HingeMotion.swift" \
  "$PROJECT_DIR/Tests/HingeMotionTests.swift" -o "$TEST_DIR/motion"
"$TEST_DIR/motion"
swiftc -parse-as-library -framework Security \
  "$PROJECT_DIR/Sources/ScreenCapturePermissionPreparation.swift" \
  "$PROJECT_DIR/Tests/PermissionPreparationTests.swift" -o "$TEST_DIR/permissions"
"$TEST_DIR/permissions"
swiftc -parse-as-library -framework QuartzCore \
  "$PROJECT_DIR/Sources/MotionSample.swift" "$PROJECT_DIR/Sources/MotionRecorder.swift" \
  "$PROJECT_DIR/Sources/HingeMotion.swift" "$PROJECT_DIR/Sources/RuntimePolicy.swift" \
  "$PROJECT_DIR/Tests/RuntimeTests.swift" -o "$TEST_DIR/runtime"
"$TEST_DIR/runtime"
swiftc -parse-as-library "$PROJECT_DIR/Sources/HingeMotion.swift" \
  "$PROJECT_DIR/Sources/MotionSample.swift" "$PROJECT_DIR/Sources/RuntimePolicy.swift" \
  "$PROJECT_DIR/Tests/RuntimePolicyTests.swift" -o "$TEST_DIR/policy"
"$TEST_DIR/policy"
swiftc -parse-as-library "$PROJECT_DIR/Sources/HingeMotion.swift" "$PROJECT_DIR/Sources/DesktopWakeAnimation.swift" "$PROJECT_DIR/Sources/SystemResumeState.swift" \
  "$PROJECT_DIR/Tests/DesktopWakeAnimationTests.swift" -o "$TEST_DIR/desktop-wake"
"$TEST_DIR/desktop-wake"
