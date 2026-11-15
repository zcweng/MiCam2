#!/bin/bash
# 保留策略：先按天数删，再按剩余空间兜底删最旧的段。
# 手工跑：bash scripts/prune.sh        由 launchd 每小时跑一次
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
KIT_DIR=$(cd "$SELF_DIR/.." && pwd)

: "${OUT_DIR:=/Volumes/MiCam2/micam2}"
: "${KEEP_DAYS:=30}"
: "${MIN_FREE_GB:=100}"
: "${PROTECT_NEWEST:=3}"

if [ -f "$KIT_DIR/config.env" ]; then
  # shellcheck disable=SC1091
  . "$KIT_DIR/config.env"
fi

log() { printf '%s [prune] %s\n' "$(date '+%F %T')" "$*"; }

[ -d "$OUT_DIR" ] || { log "目录不存在，跳过：$OUT_DIR"; exit 0; }

# 权限自检：macOS 的 TCC「可移除卷」限制下，stat 能过但读取/删除会被拒，
# 而 find 的 EPERM 被 2>/dev/null 吞掉后 wc -l 得到 0 —— 看起来"没事可做"，
# 实际是永远删不掉、盘慢慢写满。所以这里先显式确认目录读得动。
if ! ls "$OUT_DIR" >/dev/null 2>&1; then
  log "读不了 $OUT_DIR —— 不是空目录，是 macOS 权限（TCC）拒绝"
  log "  修法：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 添加 /bin/bash 并确认开关是开的"
  log "  （ffmpeg 单独被授权过也不够：find/rm/ls 这些属于 /bin/bash 的权限链）"
  exit 1
fi

# 不按可播性删半截段/空壳段：一律保留，只按天数与剩余空间清理。

# 1) 按天数清理
if [ "$KEEP_DAYS" -gt 0 ]; then
  n=$(find "$OUT_DIR" -type f -name '*.mp4' -mtime +"$KEEP_DAYS" -print -delete 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && log "按天数（>${KEEP_DAYS}d）删除 $n 个文件"
fi

# 2) 按剩余空间兜底
while :; do
  free=$(df -g "$OUT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "${free:-}" ] || { log "拿不到剩余空间，结束"; break; }
  [ "$free" -ge "$MIN_FREE_GB" ] && { log "剩余 ${free}G，正常"; break; }

  total=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.mp4' | wc -l | tr -d ' ')
  if [ "$total" -le "$PROTECT_NEWEST" ]; then
    log "只剩 $total 个文件（保护最近 $PROTECT_NEWEST 个），停止删除"
    break
  fi

  victim=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.mp4' -print0 \
           | xargs -0 ls -1tr 2>/dev/null | head -n 1)
  [ -n "${victim:-}" ] || break
  rm -f -- "$victim" && log "剩余 ${free}G < ${MIN_FREE_GB}G，删除 $(basename "$victim")"
done

used=$(du -sh "$OUT_DIR" 2>/dev/null | awk '{print $1}')
log "当前占用 ${used:-?}，文件数 $(find "$OUT_DIR" -maxdepth 1 -type f -name '*.mp4' | wc -l | tr -d ' ')"