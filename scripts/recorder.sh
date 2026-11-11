#!/bin/bash
# 守护式录像：从 go2rtc 的 RTSP 拉流，按固定时长切片写 MP4（-c copy，不转码）
# 由 launchd 保活；也可以用 nohup 手工跑：bash scripts/recorder.sh
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
KIT_DIR=$(cd "$SELF_DIR/.." && pwd)

# 默认值：环境变量 > config.env > 这里的兜底
: "${RTSP_URL:=rtsp://127.0.0.1:8554/micam2}"
: "${OUT_DIR:=/Volumes/MiCam2/micam2}"
: "${SEGMENT_SECONDS:=600}"
: "${RESTART_DELAY:=10}"
: "${MAX_RETRY_DELAY:=300}"
: "${READ_TIMEOUT_US:=15000000}"

if [ -f "$KIT_DIR/config.env" ]; then
  # shellcheck disable=SC1091
  . "$KIT_DIR/config.env"
fi

FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"

log() { printf '%s [recorder] %s\n' "$(date '+%F %T')" "$*"; }

if [ ! -x "$FFMPEG" ]; then
  log "找不到 ffmpeg（brew install ffmpeg），退出"
  exit 1
fi

# /Volumes/MiCam2/micam2 -> /Volumes/MiCam2
MOUNT_DIR=$(printf '%s' "$OUT_DIR" | awk -F/ '{print "/"$2"/"$3}')

fail_streak=0
log "start url=$RTSP_URL out=$OUT_DIR seg=${SEGMENT_SECONDS}s ffmpeg=$("$FFMPEG" -version | head -1)"

perm_hint() {
  log "无法访问 $1 —— 不是没挂载，是 macOS 权限（TCC）"
  log "  修法：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 加上 /bin/bash（运行本脚本的解释器）"
  log "  或把本脚本改成由已授权的 App / 终端启动"
}

while :; do
  if [ ! -d "$MOUNT_DIR" ]; then
    if mount | grep -qF " on ${MOUNT_DIR%/} " || [ -e "$MOUNT_DIR" ]; then
      perm_hint "$MOUNT_DIR"
    else
      log "外置盘未挂载：等待 $MOUNT_DIR"
    fi
    sleep 30
    continue
  fi
  if ! mkdir -p "$OUT_DIR"; then
    perm_hint "$OUT_DIR"
    sleep 30
    continue
  fi

  t0=$(date +%s)
  "$FFMPEG" -hide_banner -nostdin -nostats -loglevel warning \
    -rtsp_transport tcp -timeout "$READ_TIMEOUT_US" \
    -i "$RTSP_URL" \
    -map 0:v:0 -map 0:a:0? -c copy \
    -f segment -segment_time "$SEGMENT_SECONDS" -segment_format mp4 \
    -reset_timestamps 1 -strftime 1 \
    -movflags +faststart -tag:v hvc1 \
    "$OUT_DIR/%Y%m%d_%H%M%S.mp4"
  rc=$?
  dur=$(( $(date +%s) - t0 ))

  # 指数退避：断网/相机离线时不要每 10 秒去小米云换一次密钥（会被风控要验证码）。
  # 只要这次坚持了 60 秒以上（说明真的录到了东西），就把退避清零。
  if [ "$dur" -ge 60 ]; then
    fail_streak=0
  else
    fail_streak=$((fail_streak + 1))
  fi
  delay=$RESTART_DELAY
  i=0
  while [ "$i" -lt "$fail_streak" ] && [ "$delay" -lt "$MAX_RETRY_DELAY" ]; do
    delay=$((delay * 2)); i=$((i + 1))
  done
  [ "$delay" -gt "$MAX_RETRY_DELAY" ] && delay=$MAX_RETRY_DELAY

  log "ffmpeg 退出 rc=${rc}（本次坚持 ${dur}s，连续失败 $fail_streak 次），${delay}s 后重连"
  sleep "$delay"
done