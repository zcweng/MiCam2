#!/bin/bash
# 卸载 launchd 服务（保留 kit 目录和已录的视频）
#   ./uninstall.sh            # 用户级
#   sudo ./uninstall.sh --system
set -uo pipefail

MODE="user"
[ "${1:-}" = "--system" ] && MODE="system"

for name in com.micam2.recorder com.micam2.go2rtc com.micam2.prune; do
  if [ "$MODE" = "system" ]; then
    sudo launchctl bootout "system/$name" 2>/dev/null || true
    sudo rm -f "/Library/LaunchDaemons/$name.plist"
  else
    launchctl bootout "gui/$UID/$name" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$name.plist"
  fi
  echo "已移除 $name"
done

pkill -f '/MiCam2/bin/go2rtc' 2>/dev/null || true
echo "录像文件未删除。彻底清理：rm -rf $(cd "$(dirname "$0")" && pwd)"