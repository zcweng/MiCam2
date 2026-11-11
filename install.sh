#!/bin/bash
# 一键安装：下载 go2rtc → 生成 config.env → 装 launchd 服务
#
#   ./install.sh                 # 用户级 LaunchAgent（不用 sudo，需保持登录状态）
#   ./install.sh --system        # 系统级 LaunchDaemon（sudo，开机即跑，推荐给常开的 MacMini）
#   ./install.sh --with-recorder # 同时装录像守护（务必先把摄像头流跑通再用它）
set -euo pipefail

KIT_DIR=$(cd "$(dirname "$0")" && pwd)
GO2RTC_VERSION="${GO2RTC_VERSION:-v1.9.15}"
MODE="user"
WITH_RECORDER=0

for arg in "$@"; do
  case "$arg" in
    --system)        MODE="system" ;;
    --with-recorder) WITH_RECORDER=1 ;;
    -h|--help)       sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# ---------- 1. 依赖 ----------
FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"
[ -z "$FFMPEG" ] && FFMPEG="/opt/homebrew/bin/ffmpeg"
if [ ! -x "$FFMPEG" ]; then
  say "缺少 ffmpeg：先 brew install ffmpeg（只装 go2rtc 可以先不管，录像是必需的）"
fi

mkdir -p "$KIT_DIR/bin" "$KIT_DIR/logs"

# ---------- 2. go2rtc ----------
if [ -x "$KIT_DIR/bin/go2rtc" ]; then
  say "已存在 bin/go2rtc，跳过下载（想升级就删掉它重跑）"
else
  case "$(uname -m)" in
    arm64)  ZIP="go2rtc_mac_arm64.zip" ;;
    x86_64) ZIP="go2rtc_mac_amd64.zip" ;;
    *) echo "不支持的架构：$(uname -m)" >&2; exit 1 ;;
  esac
  URL="https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_VERSION}/${ZIP}"
  TMP=$(mktemp -d)
  # 国内直连 github.com:443 经常半死不活（能连上但龟速），所以镜像优先、直连兜底。
  # 想强制直连：GO2RTC_MIRRORS="" ./install.sh
  MIRRORS=()
  if [ -n "${GO2RTC_MIRRORS+x}" ]; then
    for m in $GO2RTC_MIRRORS; do MIRRORS+=("$m"); done
  else
    MIRRORS=("https://ghfast.top/" "https://gh-proxy.com/" "")
  fi
  GOT=0
  for prefix in "${MIRRORS[@]}"; do
    if [ -z "$prefix" ]; then say "下载（直连）$ZIP"
    else say "下载（镜像 ${prefix}）$ZIP"; fi
    if curl -fL -sS --connect-timeout 8 --speed-limit 51200 --speed-time 20 -m 150 \
         -o "$TMP/$ZIP" "${prefix}${URL}" && unzip -tq "$TMP/$ZIP" >/dev/null 2>&1; then
      GOT=1; break
    fi
    say "失败，换下一个源"
  done
  if [ "$GOT" -ne 1 ]; then
    echo "下载失败。手动做法：浏览器下载 $URL ，解压后把 go2rtc 放到 $KIT_DIR/bin/go2rtc 并 chmod +x" >&2
    exit 1
  fi
  unzip -o -q "$TMP/$ZIP" -d "$TMP"
  install -m 755 "$TMP/go2rtc" "$KIT_DIR/bin/go2rtc"
  xattr -d com.apple.quarantine "$KIT_DIR/bin/go2rtc" 2>/dev/null || true
  rm -rf "$TMP"
  say "已安装 $("$KIT_DIR/bin/go2rtc" -version 2>&1 | head -1)"
fi

# ---------- 3. 配置 ----------
if [ ! -f "$KIT_DIR/config.env" ]; then
  cp "$KIT_DIR/config.env.example" "$KIT_DIR/config.env"
  say "已生成 config.env（按需改 OUT_DIR / KEEP_DAYS，默认 /Volumes/MiCam2/micam2、保留 30 天）"
fi

# ---------- 4. launchd ----------
render() {
  sed -e "s|__KIT__|$KIT_DIR|g" -e "s|__HOME__|$HOME|g" "$1" > "$2"
}

install_agent() {
  local name="$1" src="$2" dest_dir tmp out
  tmp=$(mktemp)
  render "$src" "$tmp"

  if [ "$MODE" = "system" ]; then
    dest_dir="/Library/LaunchDaemons"
    sudo install -o root -g wheel -m 644 "$tmp" "$dest_dir/$name.plist"
    sudo launchctl bootout "system/$name" 2>/dev/null || true
    sudo launchctl bootstrap system "$dest_dir/$name.plist"
  else
    dest_dir="$HOME/Library/LaunchAgents"
    mkdir -p "$dest_dir"
    install -m 644 "$tmp" "$dest_dir/$name.plist"
    launchctl bootout "gui/$UID/$name" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$dest_dir/$name.plist"
    launchctl kickstart -k "gui/$UID/$name"
  fi
  rm -f "$tmp"
  say "已启动 $name"
}

install_agent "com.micam2.go2rtc" "$KIT_DIR/launchd/com.micam2.go2rtc.plist.in"
install_agent "com.micam2.prune"  "$KIT_DIR/launchd/com.micam2.prune.plist.in"

if [ "$WITH_RECORDER" = "1" ]; then
  install_agent "com.micam2.recorder" "$KIT_DIR/launchd/com.micam2.recorder.plist.in"
else
  say "录像守护未安装。先按下面步骤把流跑通，再执行：./install.sh --with-recorder"
fi

cat <<EOF

下一步：
  1) 浏览器打开 http://127.0.0.1:1984
     Add → Xiaomi → 用小米账号登录（要收验证码 / 过人机校验）
  2) WebUI 里把摄像头加进 streams，名字用 micam2（或改 config.env 里的 RTSP_URL）
  3) 本机验证出流：ffplay rtsp://127.0.0.1:8554/micam2
  4) 装录像：$KIT_DIR/install.sh --with-recorder $([ "$MODE" = "system" ] && echo --system)
  5) 看日志：tail -f $KIT_DIR/logs/recorder.log

EOF