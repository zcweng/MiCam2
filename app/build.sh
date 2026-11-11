#!/bin/bash
# 本地构建：产出 build/MiCam2.app（不含大二进制，打包时再注入）
set -euo pipefail
cd "$(dirname "$0")"
APP="build/MiCam2.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH=$(uname -m)
TARGET="$ARCH-apple-macos15.0"

mkdir -p .build/modulecache .build/tmp
export TMPDIR="$(pwd)/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$(pwd)/.build/modulecache"

swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
  -module-cache-path "$(pwd)/.build/modulecache" \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/MiCam2" \
  Sources/*.swift 2>&1 | sed 's|Sources/||'

cp Resources/Info.plist "$APP/Contents/Info.plist"

# 如果本地有二进制，一并塞进去
for b in go2rtc ffmpeg; do
  if [ -x "dist/$b" ]; then cp "dist/$b" "$APP/Contents/Resources/$b"; fi
done
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "构建完成: $(pwd)/$APP"
du -sh "$APP"
