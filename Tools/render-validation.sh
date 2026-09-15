#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p Validation/bin
swiftc -parse-as-library -O -framework SwiftUI -framework AppKit -framework MetalKit Sources/HingeMotion.swift Sources/GlassRenderer.swift Tools/RenderValidation.swift -o Validation/bin/render-validation
Validation/bin/render-validation "$@"
