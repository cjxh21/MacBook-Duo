#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
for source in GlassRenderer.swift HingeMotion.swift LidAngleSensor.swift; do
  if [[ ! -f "Validation/Baseline/Sources/$source" ]]; then
    print -u2 "Missing historical baseline: Validation/Baseline/Sources/$source (see 源码说明.md)"
    exit 1
  fi
done
mkdir -p Validation/bin Validation/Generated
python3 - <<'PY'
from pathlib import Path
root = Path('Validation/Baseline/Sources')
output = Path('Validation/Generated')
shader = (root/'GlassRenderer.swift').read_text().replace('GlassMetalView','LegacyGlassMetalView').replace('GlassSurface','LegacyGlassSurface').replace('HingeMotion','LegacyHingeMotion')
shader = shader.replace('var beforeDraw:', 'var onFrame: ((Double, Double) -> Void)?\n    var onUpload: ((Double) -> Void)?\n    var beforeDraw:')
shader = shader.replace('command.addCompletedHandler { _ in _ = wrapped; _ = buffer }', '''command.addCompletedHandler { [weak self] command in
            _ = wrapped; _ = buffer
            let gpu = max(0, command.gpuEndTime - command.gpuStartTime)
            Task { @MainActor in self?.onUpload?(gpu) }
        }''')
shader = shader.replace('command.present(drawable)\n        command.commit()', '''command.present(drawable)
        command.addCompletedHandler { [weak self] command in
            let gpu = max(0, command.gpuEndTime - command.gpuStartTime)
            Task { @MainActor in self?.onFrame?(now, gpu) }
        }
        command.commit()''')
(output/'LegacyGlassRenderer.swift').write_text(shader)
(output/'LegacyHingeMotion.swift').write_text((root/'HingeMotion.swift').read_text().replace('HingeMotion','LegacyHingeMotion'))
sensor = (root/'LidAngleSensor.swift').read_text().replace('LidAngleSensor','LegacyLidAngleSensor')
sensor = sensor.replace('private var manager:', 'private(set) var readCount = 0\n    private var manager:')
sensor = sensor.replace('private func poll() {', 'private func poll() {\n        readCount += 1')
sensor = sensor.replace('private func discoverDevice()', 'func stop() { timer?.invalidate(); timer = nil }\n\n    private func discoverDevice()')
(output/'LegacyLidAngleSensor.swift').write_text(sensor)
PY
swiftc -parse-as-library -O -framework SwiftUI -framework AppKit -framework MetalKit -framework IOKit -framework Carbon \
  Sources/HingeMotion.swift Sources/MotionSample.swift Sources/RuntimePolicy.swift Sources/MotionRecorder.swift \
  Sources/LidAngleSensor.swift Sources/GlassRenderer.swift Validation/Generated/*.swift \
  Tools/RuntimeBenchmark.swift -o Validation/bin/runtime-benchmark
