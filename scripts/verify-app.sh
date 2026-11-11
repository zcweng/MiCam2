#!/bin/bash
# MiCam2.app 接管后的验收脚本
#
# 用法（在 MacMini 上）：bash scripts/verify-app.sh
#   - 不碰外置盘的部分直接从 ssh 跑就行
#   - 需要读 /Volumes 的部分会被 TCC 拦住（ssh 会话责任进程是 sshd-session），
#     所以脚本会自己装一个临时 LaunchAgent 把这段跑到 GUI 会话里，结果写到 ~/verify-app.out
#
# 输出：~/verify-app.out（最近一段的技术参数、进程、服务清单）

set -u
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
OUT="$HOME/verify-app.out"
TMPL="$HOME/Library/LaunchAgents/com.micam2.verify.plist"
LOG="$HOME/Library/Logs/MiCam2/app.log"
CFG="$HOME/Library/Application Support/MiCam2/config.json"
DIR=$(/usr/bin/python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/MiCam2/config.json')))['storage']['outDir'])" 2>/dev/null)

{
echo "===== MiCam2.app 验收 $(date '+%F %T') ====="
echo
echo "--- 1. 旧 launchd 服务（应全部不存在）---"
for l in com.micam2.watchdog com.micam2.recorder com.micam2.prune com.micam2.app; do
  if /bin/launchctl list | grep -q "$l"; then echo "  ✗ 还在: $l"; else echo "  ✓ 已卸: $l"; fi
done
for f in /Library/LaunchDaemons/com.micam2.watchdog.plist "$HOME/Library/LaunchAgents/com.micam2.recorder.plist" "$HOME/Library/LaunchAgents/com.micam2.prune.plist"; do
  [ -e "$f" ] && echo "  ✗ 残留文件: $f" || echo "  ✓ 无残留: $(basename "$f")"
done
echo
echo "--- 2. 进程 ---"
APP=$(/usr/bin/pgrep -f 'MiCam2.app/Contents/MacOS' | head -1)
FF=$(/usr/bin/pgrep -f 'MiCam2.app/Contents/Resources/ffmpeg' | head -1)
G2=$(/usr/bin/pgrep -f '/Library/Application Support/MiCam2/go2rtc' | head -1)
echo "  app=$([ -n "$APP" ] && echo "✓ pid $APP" || echo '✗ 没在跑')"
echo "  ffmpeg(子进程)=$([ -n "$FF" ] && echo "✓ pid $FF" || echo '✗ 没在跑')"
echo "  go2rtc(后台助手)=$([ -n "$G2" ] && echo "✓ pid $G2" || echo '✗ 没在跑')"
echo
echo "--- 3. 取帧（2K）---"
/usr/bin/curl -s -m 20 -o /tmp/vframe.jpg "http://127.0.0.1:1984/api/frame.jpeg?src=micam2"
echo "  frame.jpeg: $(/usr/bin/stat -f%z /tmp/vframe.jpg 2>/dev/null) 字节"
/usr/bin/file /tmp/vframe.jpg | sed 's/^/  /'
echo
echo "--- 4. 最新录像段 ---"
DIR=$(/usr/bin/python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/MiCam2/config.json')))['storage']['outDir'])" 2>/dev/null)
echo "  目录: $DIR"
NEWEST=$(/bin/ls -t "$DIR"/*.mp4 2>/dev/null | head -1)
if [ -z "$NEWEST" ]; then
  echo "  ✗ 目录里没有 mp4（权限或没在录）"
else
  echo "  最新: $(basename "$NEWEST")  $(/usr/bin/stat -f%z "$NEWEST") 字节"
  /usr/local/bin/ffprobe -v error -show_entries \
    stream=codec_name,codec_tag_string,width,height,sample_rate \
    -show_entries format=duration,bit_rate -of default=nw=1 "$NEWEST" 2>&1 | sed 's/^/  /'
fi
echo
echo "--- 5. app 日志尾部 ---"
/usr/bin/tail -8 "$LOG" 2>/dev/null | sed 's/^/  /'
echo
echo "--- 6. 配置摘要 ---"
/usr/bin/python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
cam=c['camera']
print("  输出:", c['storage']['outDir'])
print("  分段:", c['recorder']['segmentSeconds'], "秒  保留:", c['storage']['keepDays'], "天  最小空闲:", c['storage']['minFreeGB'], "GB")
print("  看门狗:", c['watchdog'])
print("  相机:", cam['ip'], cam['model'], "subtype", cam['subtype'], "MAC", cam['mac'])
print("  账号:", cam['account'], "（凭据不打印）")
PY
echo
echo "===== 结束 ====="
} > "$OUT" 2>&1

# 需要读外置盘的那段，放到 GUI 会话里重跑一次（覆盖上面的输出）
cat > "$TMPL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.micam2.verify</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$SELF</string><string>--in-gui</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PL
if [ "${1:-}" != "--in-gui" ]; then
  /bin/launchctl bootout gui/$(/usr/bin/id -u)/com.micam2.verify 2>/dev/null
  if /bin/launchctl bootstrap gui/$(/usr/bin/id -u) "$TMPL" 2>/dev/null; then
    echo "已把验收跑到 GUI 会话里（绕开 ssh 的 TCC 限制），等 8 秒…" >&2
    sleep 8
    /bin/launchctl bootout gui/$(/usr/bin/id -u)/com.micam2.verify 2>/dev/null
    /bin/rm -f "$TMPL"
  fi
fi
/bin/cat "$OUT"