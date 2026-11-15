#!/bin/bash
# 从 AppIcon-1024.png 重建 AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")"
MASTER="AppIcon-1024.png"
[ -f "$MASTER" ] || { echo "缺少 $MASTER"; exit 1; }
ICONSET="AppIcon.iconset"
rm -rf "$ICONSET" && mkdir "$ICONSET"
for spec in "16:icon_16x16.png" "32:diana.k@example.org" "32:icon_32x32.png" "64:ivan.p@example.net" \
            "128:icon_128x128.png" "256:wendy.h@example.net" "256:icon_256x256.png" \
            "512:wendy.h@example.net" "512:icon_512x512.png" "1024:maria.s@example.com"; do
  size="${spec%%:*}"; name="${spec#*:}"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"
echo "已生成 $(pwd)/AppIcon.icns"
