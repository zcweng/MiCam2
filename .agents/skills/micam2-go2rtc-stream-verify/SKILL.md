---
name: micam2-go2rtc-stream-verify
description: "Verify or diagnose the MiCam2 Xiaomi camera stream through go2rtc on macOS, including 2K subtype selection, frame/ffprobe checks, interface-correct packet capture, single-instance checks, and recorder handoff."
---

1. Work from /Users/suke-3/MiCam2. Confirm go2rtc >=1.9.13 is installed and the external disk /Volumes/MiCam2 is mounted before recorder work.
2. Ensure only one go2rtc instance is running: run `pgrep -fl go2rtc` and `launchctl list | grep -i go2rtc`. Stop duplicates. For a user LaunchAgent use `launchctl bootout gui/$(id -u)/<label>`; for a system LaunchDaemon use `launchctl bootout system/<label>`. Restart with `launchctl kickstart -k ...` or rerun `./install.sh`.
3. Keep go2rtc.yaml local-only (127.0.0.1:1984). In the xiaomi source, set `subtype=3` when 2K is required. Do not hand-write `vendor`, `client_public`, or `sign`; they are injected when the stream opens.
4. Check idle API state: `curl -s http://127.0.0.1:1984/api/streams`. `consumers:null` is normal idle state, not a failure. Open a consumer to force startup.
5. Verify a frame: `curl -s -o /tmp/frame.jpeg http://127.0.0.1:1984/api/frame.jpeg?src=micam2` then `file /tmp/frame.jpeg`. Require `JPEG image data` and non-zero size; do not trust HTTP 200 alone.
6. Verify video: `ffmpeg -rtsp_transport tcp -i rtsp://127.0.0.1:8554/micam2 -t 15 -c copy -tag:v hvc1 /tmp/frame.mp4` then `ffprobe -v error -show_streams /tmp/frame.mp4`. Confirm hevc, expected resolution, about 20 fps, and opus audio if present. On a headless Mac use frame.jpeg/ffprobe/frame.mp4 instead of ffplay.
7. If startup fails with `read udp ... i/o timeout` and no `xiaomi: probe:` prefix, treat it as a Producer.Start read timeout. Find the actual route interface with `route -n get <camera-ip>` and use that interface in `tcpdump -ni <iface> host <camera-ip>`. Capture while concurrently pulling the frame/video; do not add a `udp` filter, so ARP and interface evidence remain visible.
8. While reproducing, run `lsof -nP -iUDP -a -p $(pgrep -x go2rtc)` to confirm the local UDP socket and `pgrep -fl go2rtc` to rule out session-stealing duplicate instances. Check firewall state. If local blocking is suspected, temporarily disable the firewall, retest, then add go2rtc to the allow list and re-enable the firewall.
9. Do not reject an unknown model string solely because it is absent from go2rtc's support list; validate with frame.jpeg and ffprobe first.
10. After the stream works, run `./install.sh --with-recorder`, confirm the external disk is mounted, wait for the first 10-minute segment, and verify with ffprobe that it is hevc and expected resolution. The `-tag:v hvc1` in recorder.sh is required for QuickTime compatibility.
11. Use scripts/prune.sh for retention checks and keep the camera microSD card inserted as an offline fallback because each new connection requires cloud key exchange.
