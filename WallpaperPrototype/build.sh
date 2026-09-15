#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
BASE=WallpaperPrototype
APP="$PWD/$BASE/build/Duo Wallpaper Lab.app"
EXT="$APP/Contents/Extensions/DuoWallpaper.appex"
mkdir -p "$APP/Contents/MacOS" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
python3 - "$APP" "$EXT" <<'PY'
import plistlib,sys,pathlib
for path,identifier,name,exe,kind in [(sys.argv[1],'studio.prototype.DuoWallpaper','Duo Wallpaper Lab','DuoWallpaperHost','APPL'),(sys.argv[2],'studio.prototype.DuoWallpaper.extension','MacBook Duo · 锁屏实验','DuoWallpaper','XPC!')]:
 d=dict(CFBundleIdentifier=identifier,CFBundleName=name,CFBundleDisplayName=name,CFBundleExecutable=exe,CFBundlePackageType=kind,CFBundleVersion='1',CFBundleShortVersionString='0.1',LSMinimumSystemVersion='26.0')
 if kind=='APPL':d['LSUIElement']=True
 else:d['EXAppExtensionAttributes']={'EXExtensionPointIdentifier':'com.apple.wallpaper'}
 pathlib.Path(path,'Contents/Info.plist').write_bytes(plistlib.dumps(d))
pathlib.Path('WallpaperPrototype/build/extension.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
PY
swiftc -swift-version 5 -parse-as-library -O -framework AppKit -framework IOKit -framework QuartzCore Sources/HingeMotion.swift Sources/MotionSample.swift Sources/LidAngleSensor.swift "$BASE/Shared/AngleBridge.swift" "$BASE/Shared/WallpaperPaths.swift" "$BASE/Host/Main.swift" -o "$APP/Contents/MacOS/DuoWallpaperHost"
# ExtensionKit must enter through Foundation bootstrap, as Xcode extensionkit-extension targets do.
# The default Swift main exits with Unrecognized extension type before host configuration.
swiftc -swift-version 5 -parse-as-library -O -application-extension -Xlinker -e -Xlinker _NSExtensionMain -import-objc-header "$BASE/Vendor/WallpaperExtension-Bridging-Header.h" -framework AppKit -framework ExtensionFoundation -framework AVFoundation -framework MetalKit -framework IOSurface -framework Security Sources/HingeMotion.swift Sources/GlassRenderer.swift "$BASE"/Shared/*.swift "$BASE"/Vendor/*.swift "$BASE"/Extension/*.swift -o "$EXT/Contents/MacOS/DuoWallpaper"
cp "$BASE/Vendor/LICENSE-Phosphene" "$EXT/Contents/Resources/"
codesign --force --sign - --entitlements "$BASE/build/extension.entitlements" "$EXT"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (not installed or selected)"
