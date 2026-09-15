#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/MacBook Duo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXT_DIR="$CONTENTS_DIR/Extensions/DuoWallpaper.appex"
# Never inherit swiftc's host/toolchain deployment target (which may exceed this OS).
DUO_MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_DIR/Info.plist")
DUO_TARGET="$(uname -m)-apple-macos${DUO_MIN_MACOS}"

mkdir -p "$MACOS_DIR"
mkdir -p "$CONTENTS_DIR/Resources"
mkdir -p "$EXT_DIR/Contents/MacOS" "$EXT_DIR/Contents/Resources"
cp "$PROJECT_DIR/Assets/MacBookDuo.icns" "$CONTENTS_DIR/Resources/"
cp "$PROJECT_DIR/Assets/MacBookDuo.png" "$CONTENTS_DIR/Resources/"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

python3 - "$EXT_DIR" "$PROJECT_DIR/WallpaperPrototype/build/extension.entitlements" <<'PY'
import pathlib
import plistlib
import sys

extension = pathlib.Path(sys.argv[1])
extension.mkdir(parents=True, exist_ok=True)
info = dict(
    CFBundleIdentifier="studio.prototype.DuoWallpaper.extension",
    CFBundleName="MacBook Duo · 锁屏壁纸",
    CFBundleDisplayName="MacBook Duo · 锁屏壁纸",
    CFBundleExecutable="DuoWallpaper",
    CFBundlePackageType="XPC!",
    CFBundleVersion="9.7",
    CFBundleShortVersionString="0.9.7",
    LSMinimumSystemVersion="26.0",
    EXAppExtensionAttributes={"EXExtensionPointIdentifier": "com.apple.wallpaper"},
)
(extension / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
entitlements = pathlib.Path(sys.argv[2])
entitlements.parent.mkdir(parents=True, exist_ok=True)
entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
PY

swiftc \
  -target "$DUO_TARGET" \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework IOKit \
  -framework QuartzCore \
  -framework MetalKit \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework Security \
  -o "$MACOS_DIR/HingeGlass" \
  "$PROJECT_DIR/WallpaperPrototype/Shared/AngleBridge.swift" \
  "$PROJECT_DIR/WallpaperPrototype/Shared/WallpaperPaths.swift" \
  "$PROJECT_DIR"/Sources/*.swift

swiftc \
  -target "$DUO_TARGET" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -import-objc-header "$PROJECT_DIR/WallpaperPrototype/Vendor/WallpaperExtension-Bridging-Header.h" \
  -framework AppKit \
  -framework ExtensionFoundation \
  -framework AVFoundation \
  -framework MetalKit \
  -framework IOSurface \
  -framework Security \
  -o "$EXT_DIR/Contents/MacOS/DuoWallpaper" \
  "$PROJECT_DIR/Sources/HingeMotion.swift" \
  "$PROJECT_DIR/Sources/GlassRenderer.swift" \
  "$PROJECT_DIR"/WallpaperPrototype/Shared/*.swift \
  "$PROJECT_DIR"/WallpaperPrototype/Vendor/*.swift \
  "$PROJECT_DIR"/WallpaperPrototype/Extension/*.swift

python3 - "$MACOS_DIR/HingeGlass" "$EXT_DIR/Contents/MacOS/DuoWallpaper" "$DUO_MIN_MACOS" <<'PYVERIFY'
import re
import subprocess
import sys
for binary in sys.argv[1:3]:
    output = subprocess.check_output(["xcrun", "vtool", "-show-build", binary], text=True)
    versions = re.findall(r"minos\s+(\S+)", output)
    if not versions or any(v != sys.argv[3] for v in versions):
        raise SystemExit(f"Deployment target mismatch in {binary}: {versions}")
print(f"Verified deployment target: macOS {sys.argv[3]}")
PYVERIFY

cp "$PROJECT_DIR/WallpaperPrototype/Vendor/LICENSE-Phosphene" "$EXT_DIR/Contents/Resources/"
zsh "$PROJECT_DIR/Tools/sign-app.sh" "$APP_DIR" "$EXT_DIR" "$PROJECT_DIR/WallpaperPrototype/build/extension.entitlements"
echo "Built: $APP_DIR"
