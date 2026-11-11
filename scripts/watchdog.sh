#!/bin/bash
# MiCam2 看门狗：root LaunchDaemon，每 120 秒跑一次，负责"卡住但没崩"的自愈。
#   1) 摄像头可达 + 能出帧        → 什么都不做
#   2) 摄像头可达但连续 3 次出不了帧 → 重启 go2rtc（生产者在半死状态时 KeepAlive 看不出问题）
#   3) 摄像头不可达                → 用 MAC 在局域网找它；IP 变了就改 yaml 再重启 go2rtc
#   4) ffmpeg 进程在、但段文件两轮没长 → kill 掉让 recorder 重连
# 状态记在 /var/tmp/micam2-watchdog，日志写 kit 的 logs/watchdog.log
set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

KIT_DIR="${MICAM2_DIR:-$HOME/micam2}"
[ -f "$KIT_DIR/config.env" ] && . "$KIT_DIR/config.env"
: "${CAMERA_MAC:=}"
: "${GO2RTC_API:=http://127.0.0.1:1984}"
: "${STREAM_NAME:=micam2}"
: "${GO2RTC_LABEL:=com.micam2.go2rtc}"

STATE=/var/tmp/micam2-watchdog
LOG_DIR="$KIT_DIR/logs"
LOG="$LOG_DIR/watchdog.log"
PROBE=/var/tmp/micam2-probe.mp4
mkdir -p "$STATE" "$LOG_DIR" 2>/dev/null || true

log() { printf '%s [watchdog] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; chmod 644 "$LOG" 2>/dev/null; }
counter() { cat "$STATE/$1" 2>/dev/null || echo 0; }
bump()    { echo $(( $(counter "$1") + 1 )) > "$STATE/$1"; }
reset_c() { echo 0 > "$STATE/$1"; }

# 日志别无限长：超过 256KB 只留最后 128KB
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 131072 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

yaml_cam_ip() {
  grep -o 'xiaomi://[^?]*@[0-9.]*' "$KIT_DIR/go2rtc.yaml" 2>/dev/null | head -1 | sed 's/.*@//'
}
cam_ip=$(yaml_cam_ip)
[ -n "$cam_ip" ] || { log "yaml 里没找到 xiaomi 流的 IP，退出"; exit 0; }

probe_ok() {
  rm -f "$PROBE"
  curl -s -m 15 -o "$PROBE" "$GO2RTC_API/api/frame.mp4?src=$STREAM_NAME" >/dev/null 2>&1
  local n
  n=$(stat -f%z "$PROBE" 2>/dev/null || echo 0)
  rm -f "$PROBE"
  [ "${n:-0}" -gt 5000 ]
}

restart_go2rtc() {
  log "重启 go2rtc：$1"
  if launchctl kickstart -k "system/$GO2RTC_LABEL" >>"$LOG" 2>&1; then
    sleep 10
    return 0
  fi
  log "kickstart 失败（需要 root）"
  return 1
}

# 用 MAC 在局域网里找摄像头：先看 ARP 缓存，扫不到就并发 ping 一遍 /24 再看
find_camera_ip() {
  local mac="$1" hint="$2" base ip
  [ -n "$mac" ] || return 1
  ip=$(arp -an 2>/dev/null | awk -v m="$mac" 'tolower($4)==m {gsub(/[()]/,"",$2); print $2; exit}')
  [ -n "$ip" ] && { echo "$ip"; return 0; }
  base=$(echo "$hint" | cut -d. -f1-3)
  [ -n "$base" ] || return 1
  for i in $(seq 1 254); do ping -c1 -W1 -t1 "$base.$i" >/dev/null 2>&1 & done
  wait 2>/dev/null
  ip=$(arp -an 2>/dev/null | awk -v m="$mac" 'tolower($4)==m {gsub(/[()]/,"",$2); print $2; exit}')
  [ -n "$ip" ] && { echo "$ip"; return 0; }
  return 1
}

# ---------- 0) go2rtc 进程本身在不在（KeepAlive 兜底，这里只记录） ----------
if ! pgrep -f "$KIT_DIR/bin/go2rtc" >/dev/null 2>&1; then
  log "go2rtc 进程不在，kickstart"
  restart_go2rtc "进程不在"
fi

# ---------- 1) 摄像头是否可达 ----------
if ! ping -c1 -W1 "$cam_ip" >/dev/null 2>&1; then
  bump noping
  strikes=$(counter noping)
  log "摄像头 $cam_ip ping 不通（第 ${strikes} 次）"
  if [ "$strikes" -ge 3 ]; then
    newip=$(find_camera_ip "$CAMERA_MAC" "$cam_ip" || true)
    if [ -n "${newip:-}" ] && [ "$newip" != "$cam_ip" ]; then
      log "摄像头 IP 漂移：$cam_ip → $newip，改 yaml 并重启 go2rtc"
      sed -i '' "s/@${cam_ip}?/@${newip}?/" "$KIT_DIR/go2rtc.yaml"
      restart_go2rtc "摄像头 IP 变了（$cam_ip → $newip）"
    elif [ -n "${newip:-}" ]; then
      log "摄像头在线（$newip）但 ping 不通，可能是 ICMP 被拦；继续按可达处理"
      reset_c noping
    else
      log "局域网里没找到该 MAC（相机应该是断电/离线），等它回来"
    fi
    reset_c noping   # 无论结果，别每轮都扫全网
  fi
  exit 0
fi
reset_c noping

# ---------- 2) 可达，但流能不能出帧 ----------
if probe_ok; then
  reset_c fail
else
  bump fail
  f=$(counter fail)
  log "取帧失败（第 ${f} 次）"
  if [ "$f" -ge 3 ]; then
    restart_go2rtc "连续 ${f} 次取不到帧"
    reset_c fail
    if probe_ok; then
      log "重启后恢复出帧"
    else
      log "重启后仍取不到帧 —— 可能是小米云端密钥/登录态问题，需要人工看一眼或重新登录账号"
    fi
  fi
fi

# ---------- 3) ffmpeg 是否在"假装工作"（进程在但段不增长） ----------
pid=$(pgrep -f "$KIT_DIR/bin/ffmpeg" | head -1)
if [ -n "${pid:-}" ]; then
  cur=$(lsof -p "$pid" 2>/dev/null | awk '$7 ~ /^[0-9]+$/ && $0 ~ /\.mp4$/ {print $7" "$NF; exit}')
  size=${cur%% *}
  prev=$(cat "$STATE/ffmpeg_size" 2>/dev/null || echo "")
  echo "${cur:-}" > "$STATE/ffmpeg_size"
  if [ -n "$prev" ] && [ "${cur:-}" = "$prev" ] && [ -n "${size:-}" ] && [ "$size" -gt 0 ]; then
    log "ffmpeg 的段文件两轮没增长（$cur），kill 掉让它重连"
    kill "$pid" 2>/dev/null || true
    echo "" > "$STATE/ffmpeg_size"
  fi
fi

exit 0