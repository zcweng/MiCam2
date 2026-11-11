---
name: micam2-macos-tcc-recovery
description: "Diagnose and repair macOS TCC permission failures that block MiCam2 camera networking or writes to the external recording volume."
---

Use this when MiCam2 cannot reach the camera, ffmpeg hangs while opening an output file, or file operations on /Volumes/Ugreen Disk fail after installation, service changes, or a macOS upgrade.

1. Reproduce with the real operation: test camera access with a frame fetch from go2rtc, and test the recording volume with a small write/read in the target directory. Do not rely on UI status or HTTP status alone.

2. Classify the TCC layer from the symptom:
   - Local-network failure: the process gets sendto EHOSTUNREACH(65), not EACCES. Unsigned non-platform CLI binaries are silently denied by default. Run go2rtc as a root LaunchDaemon because root bypasses this restriction; do not expect a normal user process or ad-hoc CLI invocation to work.
   - Removable-volume failure: touch/mkdir/ls return EPERM immediately, or ffmpeg open() hangs waiting for a permission prompt. TCC evaluates the client binary plus the responsible process, not just uid. Platform binaries such as bash, find, rm, and ls never prompt and must be added to Full Disk Access manually if legacy scripts still require them. Third-party binaries such as ffmpeg may prompt per binary; approve the prompt and retry.
   - SSH-only failure: remote ssh sessions have sshd-session as the responsible process, so even an authorized binary can remain EPERM. Never use an ssh session to validate TCC for MiCam2; validate from the same GUI or launchd context that will actually run the service.

3. Choose the narrowest responsible process:
   - Legacy launchd setup: grant Full Disk Access to the actual binary/process that needs it, and keep go2rtc running as the root LaunchDaemon for local-network access.
   - MiCam2.app setup: grant Full Disk Access once to ~/Applications/MiCam2.app; the app becomes responsible for its go2rtc and ffmpeg child processes. Prefer this over continuing to grant /bin/bash. Approve the Local Network prompt on first camera connection from the app.

4. After changing permissions, restart the responsible process/service or quit and relaunch the app so TCC is re-evaluated. Then repeat the same real operation in the same context: fetch a frame and confirm it is a non-empty JPEG, then write and read a test file on /Volumes/Ugreen Disk.

5. After any macOS major upgrade, assume TCC may have reset. Recheck Full Disk Access and Local Network entries, rerun the frame and disk-write checks, and only then trust the recorder.
