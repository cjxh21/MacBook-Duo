#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p Validation/UI Validation/bin
swiftc -target arm64-apple-macos26.0 -D UI_VALIDATION -parse-as-library -O \
  -framework SwiftUI -framework AppKit -framework IOKit -framework QuartzCore \
  -framework MetalKit -framework ScreenCaptureKit -framework Carbon -framework Security \
  WallpaperPrototype/Shared/AngleBridge.swift WallpaperPrototype/Shared/WallpaperPaths.swift \
  Sources/*.swift Tools/UIValidation.swift -o Validation/bin/ui-validation
Validation/bin/ui-validation "$PWD/Validation/UI"
