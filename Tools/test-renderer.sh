#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p Validation/bin
swiftc -parse-as-library -framework SwiftUI -framework AppKit -framework MetalKit Sources/HingeMotion.swift Sources/GlassRenderer.swift Tests/RendererLifecycleTests.swift -o Validation/bin/renderer-tests
Validation/bin/renderer-tests
