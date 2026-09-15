#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p WallpaperPrototype/build
swiftc -swift-version 5 -parse-as-library -O -framework AppKit -framework MetalKit Sources/HingeMotion.swift Sources/GlassRenderer.swift WallpaperPrototype/Shared/*.swift WallpaperPrototype/Tests/OfflineTests.swift -o WallpaperPrototype/build/offline-tests
WallpaperPrototype/build/offline-tests
