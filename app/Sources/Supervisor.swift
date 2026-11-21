import Foundation
import AppKit
import Combine

// MARK: - 子进程

final class ChildProcess {
    let proc = Process()
    private let pipe = Pipe()
    private let inPipe = Pipe()
    private var buffer = Data()
    private let queue = DispatchQueue(label: "micam2.child.log")
    private let onLog: (String) -> Void
    private let label: String

    init(label: String, exec: URL, args: [String], onLog: @escaping (String) -> Void) {
        self.label = label
        self.onLog = onLog
        proc.executableURL = exec
        proc.arguments = args
        proc.standardOutput = pipe
        proc.standardError = pipe
        // 保留 stdin：停录时写 "q\n"，让 ffmpeg 写完 moov/faststart 再退出
        proc.standardInput = inPipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.queue.async { self.consume(d) }
        }
    }

    deinit {
        // NSTask/Process 在仍运行时 dealloc 会抛异常导致 SIGABRT；释放前必须先杀掉
        pipe.fileHandleForReading.readabilityHandler = nil
        proc.terminationHandler = nil
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(1.0)
            while proc.isRunning && Date() < deadline {
                usleep(10_000)
            }
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                onLog(s.trimmingCharacters(in: .whitespaces))
            }
        }
        if buffer.count > 65536 { buffer.removeAll() }
    }

    func start() throws { try proc.run() }
    var isRunning: Bool { proc.isRunning }
    var pid: Int32 { proc.processIdentifier }

    /// ffmpeg 交互退出：收尾当前段（写 moov）；比直接 SIGKILL 慢但文件可播
    func quitGracefully() {
        guard isRunning else { return }
        let fd = inPipe.fileHandleForWriting
        try? fd.write(contentsOf: Data("q\n".utf8))
    }

    func interrupt() { if isRunning { kill(pid, SIGINT) } }
    func terminate() { if isRunning { proc.terminate() } }
    func killForce() { if isRunning { kill(pid, SIGKILL) } }

    /// 优雅停：q → 短暂等 → SIGINT → 等到超时 → 才 SIGKILL。
    /// ffmpeg 收尾段（尤其 faststart）在外置盘上可能要数秒，timeout 宜 ≥10s。
    func stopAndWait(timeout: TimeInterval = 15.0, escalate: Bool = true) async -> Int32 {
        if isRunning {
            if escalate {
                quitGracefully()
                try? await Task.sleep(nanoseconds: 400_000_000)
                if isRunning { interrupt() }
            } else {
                terminate()
            }
        }
        _ = await wait(timeout: timeout)
        if isRunning { killForce() }
        if isRunning {
            _ = await wait(timeout: 0.5)
        }
        return isRunning ? -1 : proc.terminationStatus
    }

    /// 等到进程真正退出。录制循环用这个——不会在仍运行时返回。
    func wait() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            finishWhenExited(cont)
        }
    }

    /// 限时等待。超时后进程可能仍在跑：调用方必须继续持有本对象并自行 stop/kill，不可立刻释放。
    func wait(timeout: TimeInterval) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let lock = NSLock()
            var done = false
            let finish: @Sendable (Int32) -> Void = { c in
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                cont.resume(returning: c)
            }
            if !proc.isRunning {
                finish(proc.terminationStatus)
                return
            }
            proc.terminationHandler = { p in finish(p.terminationStatus) }
            DispatchQueue.global().async { [proc] in
                let deadline = Date().addingTimeInterval(timeout)
                while proc.isRunning && Date() < deadline { usleep(50_000) }
                if proc.isRunning {
                    finish(-1) // 仍在跑：不要读 terminationStatus 冒充已退出
                } else {
                    finish(proc.terminationStatus)
                }
            }
        }
    }

    private func finishWhenExited(_ cont: CheckedContinuation<Int32, Never>) {
        let lock = NSLock()
        var done = false
        let finish: @Sendable (Int32) -> Void = { c in
            lock.lock(); defer { lock.unlock() }
            if done { return }
            done = true
            cont.resume(returning: c)
        }
        if !proc.isRunning {
            finish(proc.terminationStatus)
            return
        }
        proc.terminationHandler = { p in finish(p.terminationStatus) }
        // 兜底轮询：避免 terminationHandler 在已退出竞态下漏掉
        DispatchQueue.global().async { [proc] in
            while proc.isRunning { usleep(100_000) }
            finish(proc.terminationStatus)
        }
    }
}

// MARK: - 运行状态

enum RunState: Equatable {
    case stopped, starting, recording, paused, stopping, failed(String)

    var isActive: Bool {
        switch self {
        case .recording, .starting, .paused, .stopping: return true
        case .stopped, .failed: return false
        }
    }
    /// 可以点「停止」：录制/暂停/启动中；停止中与已停止不可再点
    var canStop: Bool {
        switch self {
        case .recording, .paused, .starting: return true
        case .stopping, .stopped, .failed: return false
        }
    }
    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .recording: return "录制中"
        case .paused: return "已暂停"
        case .stopping: return "停止中"
        case .failed(let m): return "异常：\(m)"
        }
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
}

/// 杀掉本 app 路径下残留的 ffmpeg（stop 置空引用后、或强杀 app 后的孤儿）
func killStrayMiCamFFmpeg() {
    guard let bin = AppPaths.ffmpeg?.path, !bin.isEmpty else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-9", "-f", bin]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

// MARK: - 主控

@MainActor
final class Supervisor: ObservableObject {
    static let shared = Supervisor()

    private let store = ConfigStore.shared
    var config: MiCam2Config { store.config }

    @Published private(set) var state: RunState = .stopped
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var currentFile: String = ""
    @Published private(set) var currentSize: Int64 = 0
    @Published private(set) var bitrateMbps: Double = 0
    @Published private(set) var freeGB: Double = 0
    @Published private(set) var todayCount: Int = 0
    @Published private(set) var todayBytes: Int64 = 0
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var go2rtcPID: Int32 = 0
    /// go2rtc 跑在哪里：后台助手（root）还是 app 子进程
    @Published private(set) var go2rtcMode: String = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastPrune: Date?
    @Published private(set) var lastWatchdog: Date?
    @Published private(set) var permissionProblem: String?
    /// 本地网络权限被拒（go2rtc 报 i/o timeout 且一直取不到帧）
    @Published private(set) var networkProblem = false
    /// 本次启动是否尝试过录制（用于区分“还没开始”与“开始了但失败”）
    @Published private(set) var hasStartedOnce = false
    /// 旧 launchd 服务还在跑，先接管再开始（否则两个录制器会往同一目录写重名片段）
    @Published private(set) var blockedByLegacy = false
    /// 外置盘是否真的可写（FDA 或用户点过「可移除卷」弹窗的允许，都算）
    @Published private(set) var volumeOK = Supervisor.hasFullDiskAccess()
    /// 当前 ffmpeg 实际录制模式
    @Published private(set) var actualRecordMode: RecordMode = .motion
    /// 动静检测期望模式（段边界才切到 actual）
    @Published private(set) var desiredRecordMode: RecordMode = .motion
    @Published private(set) var motionScore: Double = 0

    private var go2rtc: ChildProcess?
    private var ffmpeg: ChildProcess?
    private var recorderTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var watchdogTimer: Timer?
    private var pruneTimer: Timer?
    private var previewTimer: Timer?
    private var stopping = false
    private var paused = false
    private var frameFailStreak = 0
    private var lastStatsAt = Date()
    private let motionDetector = MotionDetector()
    /// 本轮 ffmpeg 启动时间，用于段边界对齐切模式
    private var modeAnchor = Date()
    /// 因期望模式变化而主动停 ffmpeg（不计失败 streak）
    private var switchingForMode = false
    private var idleEncoder: String?

    private init() {
        log("MiCam2 启动，配置目录 \(AppPaths.supportDir.path)")
    }

    // MARK: 日志

    /// 日志超过 8 MB 就滚一份（app.log → app.log.1），避免 24×7 跑着把盘写满
    private static var lastRotateCheck = Date.distantPast
    private static func rotateLogIfNeeded() {
        if Date().timeIntervalSince(lastRotateCheck) < 300 { return }
        lastRotateCheck = Date()
        let fm = FileManager.default
        let path = AppPaths.logFile.path
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 8_000_000 else { return }
        try? fm.removeItem(atPath: path + ".1")
        try? fm.moveItem(atPath: path, toPath: path + ".1")
    }

    func log(_ text: String) {
        let line = LogLine(date: Date(), text: text)
        logs.append(line)
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let out = "\(f.string(from: line.date)) [app] \(text)\n"
        Self.rotateLogIfNeeded()
        if let data = out.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: AppPaths.logFile) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: AppPaths.logFile)
            }
        }
    }

    // MARK: 权限自检

    /// 权限自检（同步版，供“自检”按钮用；可能被 TCC 弹窗阻塞，界面上请用 async 版）
    func permissionCheck() -> String? {
        guard AppPaths.go2rtc != nil else { return "缺少 go2rtc 可执行文件（应用包不完整）" }
        guard AppPaths.ffmpeg != nil else { return "缺少 ffmpeg 可执行文件（应用包不完整）" }
        return Self.probeWrite(dir: config.storage.outDir)
    }

    /// 权限自检（异步版）：把可能被 TCC 弹窗卡住的写入放到后台线程，最多等 timeout 秒
    func permissionCheckAsync(timeout: TimeInterval = 4) async -> String? {
        guard AppPaths.go2rtc != nil else { return "缺少 go2rtc 可执行文件（应用包不完整）" }
        guard AppPaths.ffmpeg != nil else { return "缺少 ffmpeg 可执行文件（应用包不完整）" }
        if !FileManager.default.fileExists(atPath: config.storage.outDir) {
            // 目录不存在时先判断是不是盘没挂载
            let comps = config.storage.outDir.split(separator: "/")
            if comps.count >= 2, config.storage.outDir.hasPrefix("/Volumes/") {
                let volume = "/Volumes/" + comps[1]
                if !FileManager.default.fileExists(atPath: volume) {
                    return "外置盘没挂载：找不到 \(volume)。插好硬盘或换一个目录。"
                }
            }
        }
        let dir = config.storage.outDir
        let hasFDA = Self.hasFullDiskAccess()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ v: String?) {
                lock.lock()
                if done { lock.unlock(); return }
                done = true
                lock.unlock()
                cont.resume(returning: v)
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(Self.probeWrite(dir: dir)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(hasFDA
                       ? "探测超时：就算有完全磁盘访问权限也写不进去，检查外置盘是否可写。"
                       : "探测超时：系统正在等你点授权弹窗（看屏幕上有无“允许”对话框）。"
                         + "更省事的办法是给 MiCam2 授「完全磁盘访问权限」——那样不会再弹窗，也不会卡住别的进程。")
            }
        }
    }

    /// 真的去写一个探针文件；TCC 未授权时这次 open() 会一直挂着
    /// 判断本身有没有「完全磁盘访问权限」
    /// 读 TCC 数据库：没授权时立刻 EPERM，**不会弹窗、不会卡住**，是最安全的探测方式。
    nonisolated static func hasFullDiskAccess() -> Bool {
        let p = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let fh = FileHandle(forReadingAtPath: p) else { return false }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: 16)) != nil
    }

    nonisolated static func probeWrite(dir: String) -> String? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                return "建不了目录 \(dir)（\(error.localizedDescription)）。盘已挂载的话，请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里勾选 MiCam2。"
            }
        }
        let probe = (dir as NSString).appendingPathComponent(".micam2_write_test")
        do {
            try "ok".write(toFile: probe, atomically: true, encoding: .utf8)
            try? fm.removeItem(atPath: probe)
            return nil
        } catch {
            return "写不进 \(dir)。请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里勾选 MiCam2，然后点“重新检测”。"
        }
    }

    // MARK: 启动 / 停止

    func setBlockedByLegacy() { blockedByLegacy = true }
    func clearBlockedByLegacy() { blockedByLegacy = false }

    /// 主动测一次外置盘写入。
    /// 没有 FDA 时这会弹出「可移除卷」授权框——比 FDA 更窄，是最推荐给用户的授权方式。
    /// 注意：弹窗挂着没人点会堵住所有进程对该盘的写入，所以界面里要提示“出现弹窗立刻点允许”。
    func probeVolumeNow() async {
        log("开始测试外置盘写入（屏幕上可能弹出授权框，请点“允许”）…")
        let dir = config.storage.outDir
        let r = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { Self.probeWrite(dir: dir) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return "超时：15 秒内没拿到授权（弹窗没人点，或盘不可写）"
            }
            let first = await group.next() ?? "未知错误"
            group.cancelAll()
            return first
        }
        if let r {
            volumeOK = false
            log("外置盘写入测试失败：\(r)")
            if r.contains("超时") {
                // 必须自动收尾：挂着的授权请求会让所有进程都写不进这块盘（实测能堵死正在录的 ffmpeg）
                dismissStuckPrompt()
                log("已自动尝试关掉卡住的授权框，避免它堵住其他程序写盘")
            }
        } else {
            volumeOK = true
            log("外置盘写入测试通过：\(config.storage.outDir)")
        }
    }

    /// 诊断：试着让一个子进程把文件写进录像目录，看 app 到底能不能写盘。
    /// 分别用内置 ffmpeg 和旧方案那个（已经有授权记录的）ffmpeg 试，谁通了就用谁。
    func testVolumeWrite() async {
        let dir = config.storage.outDir
        var candidates: [String] = []
        if let forced = ProcessInfo.processInfo.environment["MICAM2_TEST_FFMPEG"], !forced.isEmpty {
            candidates = [forced]
        }
        if let b = AppPaths.ffmpeg { candidates.append(b.path) }
        let legacy = NSHomeDirectory() + "/micam2/bin/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: legacy) { candidates.append(legacy) }
        for bin in candidates {
            let target = dir + "/.micam2_testwrite.mp4"
            try? FileManager.default.removeItem(atPath: target)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-y", "-hide_banner", "-loglevel", "error",
                           "-f", "lavfi", "-i", "testsrc=d=1:s=64x64:r=10",
                           "-c:v", "mpeg4", "-t", "1", target]
            let pipe = Pipe(); p.standardError = pipe
            log("TESTWRITE 用 \(bin) 写 \(target)")
            do { try p.run() } catch { log("TESTWRITE 启动失败 \(error.localizedDescription)"); continue }
            let deadline = Date().addingTimeInterval(12)
            while p.isRunning && Date() < deadline { usleep(200_000) }
            if p.isRunning {
                p.terminate()
                log("TESTWRITE 12 秒没返回 → 判定为卡在权限上")
                // 关键：被 kill 在 TCC open 上的子进程会留下挂起的授权请求，
                // 那会让所有进程都写不进这块盘（实测会把正在录的 ffmpeg 堵死）。必须收尾。
                dismissStuckPrompt()
            }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let exists = FileManager.default.fileExists(atPath: target)
            let size = (try? FileManager.default.attributesOfItem(atPath: target)[.size] as? Int) ?? 0
            log("TESTWRITE 结果 rc=\(p.terminationStatus) 文件=\(exists ? "有" : "无") \(size ?? 0) 字节 \(out.prefix(120))")
            if exists, (size ?? 0) > 100 {
                volumeOK = true
                try? FileManager.default.removeItem(atPath: target)
                return
            }
            try? FileManager.default.removeItem(atPath: target)
        }
        volumeOK = false
    }

    /// 关掉卡住的授权弹窗（视同拒绝）。实测有效，否则它会一直堵住磁盘写入。
    func dismissStuckPrompt() {
        _ = Legacy.runSync("/usr/bin/killall", ["UserNotificationCenter"])
        log("已尝试关闭卡住的授权弹窗（视同拒绝）")
    }

    func start() async {
        hasStartedOnce = true
        // 放在权限探测之前：这一步不需要碰外置盘，也不会弹窗
        if Legacy.scan().kitIsRunning && !CommandLine.arguments.contains("--force-start") {
            blockedByLegacy = true
            log("旧服务还在录制：先点「一键接管」把它们卸掉，否则两个录制器会往同一个目录写重名片段")
            return
        }
        blockedByLegacy = false
        guard !state.isActive else { return }
        stopping = false
        paused = false
        state = .starting

        let problem = await permissionCheckAsync()
        volumeOK = (problem == nil)
        if let problem {
            permissionProblem = problem
            state = .failed(problem)
            log("权限自检失败：\(problem)")
            return
        }
        permissionProblem = nil

        guard let yaml = try? store.writeGo2rtcYAML() else {
            state = .failed("生成配置失败")
            return
        }
        log("配置已生成：\(yaml.path)")

        // 防止上次强退留下的孤儿 ffmpeg 继续写盘
        killStrayMiCamFFmpeg()

        motionDetector.reset(to: .motion)
        desiredRecordMode = .motion
        actualRecordMode = .motion
        motionScore = 0
        switchingForMode = false

        // 起 go2rtc：优先用已安装的后台助手（root 才有本地网络权限）
        if Go2rtcHelper.isInstalled {
            if Go2rtcHelper.isHelperBinaryStale() {
                log("注意：后台助手里的 go2rtc 与 app 内置版本不一致（app 升级过）。到「设置 → 高级」点「重装后台组件」可同步。")
            }
            go2rtcMode = "后台助手"
            log("go2rtc 由后台助手运行，拉起以加载最新配置")
            // stop 时会 bootout；这里用 ensureRunning（bootstrap + kickstart）
            if Go2rtcHelper.ensureRunning() {
                var ready = false
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if await apiGet("/api/streams", timeout: 3) != nil { ready = true; break }
                }
                log(ready ? "go2rtc API 就绪" : "go2rtc API 未就绪")
                await checkHelperNetwork()
            } else {
                log("后台助手拉起失败，回退到 app 内置子进程")
                go2rtcMode = "内置子进程"
            }
            if go2rtcMode == "后台助手" {
                startedAt = Date()
                state = .recording
                startRecorderLoop()
                startTimers()
                await Task.yield()
                return
            }
        } else {
            go2rtcMode = "内置子进程"
        }
        guard let bin = AppPaths.go2rtc else { return }
        let g = ChildProcess(label: "go2rtc", exec: bin, args: ["-config", yaml.path]) { [weak self] line in
            Task { @MainActor in
                self?.log("[go2rtc] \(line)")
                if line.contains("i/o timeout") || line.contains("no route to host") || line.contains("network is unreachable") {
                    self?.networkProblem = true
                }
            }
        }
        do {
            try g.start()
        } catch {
            state = .failed("go2rtc 启动失败")
            log("go2rtc 启动失败：\(error.localizedDescription)")
            return
        }
        go2rtc = g
        go2rtcPID = g.pid
        log("go2rtc 已启动 pid=\(g.pid)")

        // 等 API 就绪
        var ready = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await apiGet("/api/streams", timeout: 3) != nil { ready = true; break }
        }
        if !ready { log("go2rtc API 未在 10 秒内就绪，继续尝试录制") }

        startedAt = Date()
        state = .recording
        startRecorderLoop()
        startTimers()
    }

    func pause() {
        guard state == .recording else { return }
        paused = true
        recorderTask?.cancel()
        recorderTask = nil
        let old = ffmpeg
        ffmpeg = nil
        state = .paused
        log("正在收尾当前段（写 moov）…")
        Task {
            let rc = await old?.stopAndWait(timeout: 15.0)
            // 仅清真正没退出的孤儿；收尾成功时 pkill 找不到进程
            if old?.isRunning == true { killStrayMiCamFFmpeg() }
            await MainActor.run {
                self.log(rc != nil && old?.isRunning != true
                         ? "已暂停录制（当前段已收尾，go2rtc 保持运行）"
                         : "已暂停录制（收尾超时，当前段可能不完整）")
            }
        }
    }

    func resume() {
        guard state == .paused else { return }
        paused = false
        state = .recording
        log("继续录制")
        startRecorderLoop()
    }

    func stop() async {
        guard state.canStop else { return }
        state = .stopping
        stopping = true
        paused = false
        recorderTask?.cancel()
        recorderTask = nil

        let oldF = ffmpeg
        ffmpeg = nil
        // 给足时间写 moov + faststart；过早 SIGKILL 会留下不可播的最新段
        log("正在收尾当前录像段…")
        let rc = await oldF?.stopAndWait(timeout: 15.0)
        if oldF?.isRunning == true {
            killStrayMiCamFFmpeg()
            log("ffmpeg 收尾超时，已强制结束（最新段可能不可播）")
        } else if oldF != nil {
            log("当前段已收尾（ffmpeg rc=\(rc ?? 0)）")
        }

        let oldG = go2rtc
        go2rtc = nil
        go2rtcPID = 0
        _ = await oldG?.stopAndWait(timeout: 1.5, escalate: false)

        if Go2rtcHelper.isInstalled {
            if Go2rtcHelper.stopDaemon() {
                log("后台 go2rtc 助手已停止")
            } else {
                log("后台 go2rtc 助手未能停止（设置 → 高级 → 重装后台组件，以更新 sudo 白名单）")
            }
        }

        state = .stopped
        startedAt = nil
        currentFile = ""
        currentSize = 0
        bitrateMbps = 0
        previewImage = nil
        networkProblem = false
        stopTimers()
        log("已停止")
    }

    func toggle() async {
        switch state {
        case .stopped, .failed: await start()
        case .recording: pause()
        case .paused: resume()
        case .starting, .stopping: break
        }
    }

    /// 重新做一次权限自检，结果写回界面
    func recheckPermissions() async -> String? {
        let p = await permissionCheckAsync()
        permissionProblem = p
        return p
    }

    /// 应用退出时的同步兜底：尽量收尾当前段，再强杀，避免孤儿
    func emergencyStop() {
        stopping = true
        paused = false
        recorderTask?.cancel()
        let oldF = ffmpeg
        let oldG = go2rtc
        ffmpeg = nil
        go2rtc = nil
        go2rtcPID = 0
        oldF?.quitGracefully()
        Thread.sleep(forTimeInterval: 0.3)
        oldF?.interrupt()
        oldG?.terminate()
        // 退出流程不能卡太久，但仍尽量等 moov 写完
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if oldF?.isRunning != true && oldG?.isRunning != true { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        oldF?.killForce()
        oldG?.killForce()
        if oldF?.isRunning == true { killStrayMiCamFFmpeg() }
        if Go2rtcHelper.isInstalled {
            _ = Go2rtcHelper.stopDaemon()
        }
    }

    // MARK: 录制循环

    private var loopGeneration = 0

    private func startRecorderLoop() {
        recorderTask?.cancel()
        loopGeneration += 1
        let gen = loopGeneration
        recorderTask = Task { [weak self] in await self?.recorderLoop(gen: gen) }
    }

    private func recorderLoop(gen: Int) async {
        var streak = 0
        while !Task.isCancelled && !stopping && !paused && gen == loopGeneration {
            guard let bin = AppPaths.ffmpeg else { log("找不到 ffmpeg"); return }
            let mode: RecordMode = {
                if !config.recorder.idleSparseEnabled { return .motion }
                return desiredRecordMode
            }()
            actualRecordMode = mode
            switchingForMode = false
            modeAnchor = Date()
            let args = ffmpegArgs(mode: mode)
            if mode == .idle {
                log("录制模式：静止稀疏（\(config.recorder.idleFrameIntervalSec)s/帧，\(config.recorder.idleVideoBitrate)，编码器 \(resolvedIdleEncoder())）")
            } else {
                log("录制模式：运动原流（-c copy）")
            }
            let f = ChildProcess(label: "ffmpeg", exec: bin, args: args) { [weak self] line in
                Task { @MainActor in self?.log("[ffmpeg] \(line)") }
            }
            let launchedAt = Date()
            do {
                try f.start()
            } catch {
                log("ffmpeg 启动失败：\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            ffmpeg = f
            let rc = await f.wait()
            ffmpeg = nil
            if Task.isCancelled || stopping || paused || gen != loopGeneration {
                f.terminate()   // 代数变了说明这轮已作废，别留下孤儿 ffmpeg 继续写盘
                break
            }

            let wasModeSwitch = switchingForMode
            switchingForMode = false
            let dur = Date().timeIntervalSince(launchedAt)
            if wasModeSwitch {
                streak = 0
                log("段边界切换录制模式（上一轮坚持 \(Int(dur))s，rc=\(rc)）")
                continue
            }
            if dur >= 60 { streak = 0 } else { streak += 1 }
            var delay = config.recorder.restartDelay
            var i = 0
            while i < streak && delay < config.recorder.maxRetryDelay {
                delay *= 2
                i += 1
            }
            delay = min(delay, max(config.recorder.maxRetryDelay, 1))
            log("ffmpeg 退出 rc=\(rc)（坚持 \(Int(dur))s，连续失败 \(streak) 次），\(delay)s 后重连")
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
    }

    private func ffmpegArgs(mode: RecordMode) -> [String] {
        let c = config
        let out = c.storage.outDir
        var args: [String] = [
            // 不用 -nostdin：停止时通过 stdin 发 q，让当前段写完 moov 再退出
            "-hide_banner", "-nostats", "-loglevel", "warning",
            "-rtsp_transport", "tcp",
            "-timeout", String(c.recorder.readTimeoutSec * 1_000_000),
            "-i", "rtsp://127.0.0.1:\(c.rtspPort)/micam2",
        ]
        let vtag: String
        switch mode {
        case .motion:
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]
            vtag = "hvc1"
        case .idle:
            let interval = max(c.recorder.idleFrameIntervalSec, 0.5)
            let fps = 1.0 / interval
            let enc = resolvedIdleEncoder()
            let br = c.recorder.idleVideoBitrate.isEmpty ? "200k" : c.recorder.idleVideoBitrate
            args += [
                "-map", "0:v:0", "-map", "0:a:0?",
                "-vf", String(format: "fps=%.6f", fps),
                "-c:v", enc, "-b:v", br,
                "-c:a", "aac", "-b:a", "32k",
            ]
            vtag = enc.contains("264") ? "avc1" : "hvc1"
        }
        args += [
            "-tag:v", vtag,
            "-f", "segment",
            "-segment_time", String(c.recorder.segmentSeconds),
            "-segment_format", "mp4",
            // segment 不会吃顶层 -movflags；必须经 segment_format_options 传给 mp4 muxer
            "-segment_format_options", "movflags=+faststart",
            "-reset_timestamps", "1",
            "-strftime", "1",
            "\(out)/%Y%m%d_%H%M%S.mp4",
        ]
        return args
    }

    /// 探测一次并缓存静止模式编码器：VT HEVC → libx265 → libx264
    private func resolvedIdleEncoder() -> String {
        if let idleEncoder { return idleEncoder }
        let enc = probeIdleEncoder()
        idleEncoder = enc
        return enc
    }

    private func probeIdleEncoder() -> String {
        guard let bin = AppPaths.ffmpeg else { return "libx264" }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "libx264" }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for name in ["hevc_videotoolbox", "libx265", "h264_videotoolbox", "libx264"] {
            if out.contains(name) { return name }
        }
        return "libx264"
    }

    /// 期望模式与实际不一致时，等到段边界再优雅停 ffmpeg，由 recorderLoop 用新模式拉起
    private func maybeSwitchModeAtSegmentBoundary() {
        guard state == .recording, config.recorder.idleSparseEnabled else { return }
        guard desiredRecordMode != actualRecordMode else { return }
        guard ffmpeg?.isRunning == true, !switchingForMode else { return }
        let seg = TimeInterval(max(config.recorder.segmentSeconds, 10))
        let elapsed = Date().timeIntervalSince(modeAnchor)
        // 至少完整跑过一段，且落在虚拟段尾（与 segment_time 对齐），避免一改期望就立刻切出碎文件
        guard elapsed >= seg else { return }
        let into = elapsed.truncatingRemainder(dividingBy: seg)
        guard into >= seg - 2.5 else { return }
        switchingForMode = true
        log("期望模式=\(desiredRecordMode.label)，段边界到，切换中…")
        ffmpeg?.quitGracefully()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.switchingForMode, self.ffmpeg?.isRunning == true else { return }
            self.ffmpeg?.interrupt()
        }
    }

    // MARK: 定时器

    private func startTimers() {
        stopTimers()

        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats()
                self?.maybeSwitchModeAtSegmentBoundary()
            }
        }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshPreview() }
        }
        let wd = TimeInterval(max(config.watchdog.intervalSec, 5))
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: wd, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watchdogTick() }
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runPrune() }
        }
        refreshStats()
    }

    private func stopTimers() {
        statsTimer?.invalidate(); statsTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        previewTimer?.invalidate(); previewTimer = nil
    }

    private func restartTimersForConfigChange() {
        guard state.isActive else { return }
        startTimers()
    }

    // MARK: 统计

    func refreshStats() {
        let list = RecordingStore.list(config.storage.outDir)
        recordings = Array(list.prefix(60))
        freeGB = RecordingStore.freeGB(config.storage.outDir) ?? 0

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        let prefix = f.string(from: Date())
        let today = list.filter { $0.name.hasPrefix(prefix) }
        todayCount = today.count
        todayBytes = today.reduce(0) { $0 + $1.size }

        if state == .recording, let newest = list.first {
            let deltaBytes = newest.size - currentSize
            let deltaT = max(Date().timeIntervalSince(lastStatsAt), 0.5)
            if currentSize > 0 && deltaBytes > 0 {
                bitrateMbps = Double(deltaBytes) * 8 / deltaT / 1_000_000
            } else if currentSize == 0 {
                bitrateMbps = 0
            }
            currentFile = newest.name
            currentSize = newest.size
        }
        lastStatsAt = Date()
    }

    // MARK: 预览

    private func refreshPreview() async {
        guard state.isActive else { return }
        if let data = await apiGet("/api/frame.jpeg?src=micam2", timeout: 8),
           data.count > 2000, data.first == 0xFF, data.dropFirst().first == 0xD8,
           let img = NSImage(data: data) {
            previewImage = img
            frameFailStreak = 0
            if networkProblem {
                networkProblem = false
                log("本地网络已通，画面恢复")
            }
            if state == .recording || state == .paused {
                motionDetector.ingest(img, config: config.recorder)
                motionScore = motionDetector.lastScore
                let next = config.recorder.idleSparseEnabled ? motionDetector.desiredMode : .motion
                if next != desiredRecordMode {
                    desiredRecordMode = next
                    log("动静检测：期望 \(next.label)（score=\(String(format: "%.4f", motionScore))）")
                }
                maybeSwitchModeAtSegmentBoundary()
            }
        }
    }

    // MARK: 看门狗

    func watchdogTick() async {
        guard config.watchdog.enabled, state.isActive, !stopping else { return }
        lastWatchdog = Date()

        // 注意：app 是 ad-hoc 签名，没有「本地网络」权限，ICMP 一定会失败，
        // 所以这里只用 go2rtc 的 HTTP 接口判断（走 127.0.0.1，不需要局域网权限）。
        if Go2rtcHelper.isInstalled {
            if !Go2rtcHelper.isRunning {
                log("看门狗：go2rtc 助手进程不在，重启")
                await restartGo2rtc(reason: "助手进程不在")
                return
            }
        } else if let g = go2rtc, !g.isRunning {
            log("看门狗：go2rtc 进程不在，重启")
            await restartGo2rtc(reason: "进程不在")
            return
        }

        if let data = await apiGet("/api/frame.jpeg?src=micam2", timeout: 12),
           data.count > 2000, data.first == 0xFF {
            frameFailStreak = 0
            return
        }
        frameFailStreak += 1
        log("看门狗：取帧失败 \(frameFailStreak)/\(config.watchdog.failThreshold)")
        if Go2rtcHelper.isInstalled { await checkHelperNetwork() }
        if frameFailStreak >= config.watchdog.failThreshold {
            frameFailStreak = 0
            if await recoverCameraIP() { return }
            await restartGo2rtc(reason: "连续 \(config.watchdog.failThreshold) 次取帧失败")
        }
    }

    private func restartGo2rtc(reason: String) async {
        log("重启 go2rtc（\(reason)）")
        if Go2rtcHelper.isInstalled {
            if Go2rtcHelper.ensureRunning() {
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if await apiGet("/api/streams", timeout: 3) != nil { break }
                }
                if await apiGet("/api/frame.jpeg?src=micam2", timeout: 12) != nil {
                    log("后台助手重启后恢复出帧")
                } else {
                    log("后台助手重启后仍取不到帧")
                    await checkHelperNetwork()
                }
                return
            } else {
                log("后台助手拉起失败（sudo 白名单可能没装或需重装助手）")
            }
        }
        let oldG = go2rtc
        go2rtc = nil
        go2rtcPID = 0
        _ = await oldG?.stopAndWait(timeout: 2.0, escalate: false)

        guard let bin = AppPaths.go2rtc else { return }
        _ = try? store.writeGo2rtcYAML()
        let g = ChildProcess(label: "go2rtc", exec: bin, args: ["-config", AppPaths.yamlFile.path]) { [weak self] line in
            Task { @MainActor in
                self?.log("[go2rtc] \(line)")
                if line.contains("i/o timeout") || line.contains("no route to host") {
                    self?.networkProblem = true
                }
            }
        }
        try? g.start()
        go2rtc = g
        go2rtcPID = g.pid

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await apiGet("/api/streams", timeout: 3) != nil { break }
        }
        if await apiGet("/api/frame.jpeg?src=micam2", timeout: 12) != nil {
            log("重启后恢复出帧")
        } else {
            log("重启后仍取不到帧 —— 可能需要重新登录小米账号")
        }
    }

    /// 相机 IP 漂移自愈：用 MAC 在局域网里找，找到就改配置重启 go2rtc
    private func recoverCameraIP() async -> Bool {
        let mac = config.camera.mac.lowercased()
        guard !mac.isEmpty else { return false }

        if let ip = await arpLookup(mac: mac) {
            if ip != config.camera.ip {
                log("相机 IP 漂移：\(config.camera.ip) → \(ip)")
                var c = config
                c.camera.ip = ip
                store.save(c)
                await restartGo2rtc(reason: "IP 变更")
                return true
            }
            return false
        }

        // 扫一遍 /24
        let base = config.camera.ip.split(separator: ".").dropLast().joined(separator: ".")
        guard !base.isEmpty else { return false }
        log("扫描 \(base).1-254 找相机（MAC \(mac)；app 没有本地网络权限，扫不到是正常的，建议给相机做 DHCP 静态绑定）…")
        _ = await shell("/bin/sh", ["-c",
            "for i in $(seq 1 254); do /sbin/ping -c1 -W200 -t1 \(base).$i >/dev/null 2>&1 & done; wait"])
        if let ip = await arpLookup(mac: mac), ip != config.camera.ip {
            log("相机 IP 漂移：\(config.camera.ip) → \(ip)")
            var c = config
            c.camera.ip = ip
            store.save(c)
            await restartGo2rtc(reason: "IP 变更")
            return true
        }
        return false
    }

    private func arpLookup(mac: String) async -> String? {
        let (_, out) = await shell("/usr/sbin/arp", ["-an"])
        let want = mac.lowercased()
        for line in out.split(separator: "\n") {
            // ? (192.168.1.50) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
            let parts = line.split(separator: " ")
            if parts.count > 4, parts[3].lowercased() == want {
                let ip = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                return ip
            }
        }
        return nil
    }

    private func checkHelperNetwork() async {
        let logText = Go2rtcHelper.tailLog(lines: 60)
        if logText.contains("i/o timeout") || logText.contains("no route to host") {
            networkProblem = true
        }
    }

    private func ping(_ ip: String) async -> Bool {
        let (code, _) = await shell("/sbin/ping", ["-c1", "-W800", "-t1", ip])
        return code == 0
    }

    // MARK: 清理

    func runPrune() {
        let (n, freed) = RecordingStore.prune(config.storage)
        lastPrune = Date()
        if n > 0 {
            log("清理 \(n) 个文件，释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        } else {
            log("清理检查完成，无需删除")
        }
        refreshStats()
    }

    /// 删除全部录像（会先暂停录制）
    func deleteAll() async {
        let wasRecording = state == .recording
        if wasRecording { pause() }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let list = RecordingStore.list(config.storage.outDir)
        var n = 0
        for r in list {
            if (try? FileManager.default.removeItem(at: r.url)) != nil { n += 1 }
        }
        log("已删除 \(n) 个录像文件")
        refreshStats()
        if wasRecording { resume() }
    }

    // MARK: 配置变更

    enum RestartNeed: Equatable { case none, go2rtc, recorder, both }

    func apply(_ new: MiCam2Config) {
        let old = config
        store.save(new)
        var need: RestartNeed = .none
        if old.camera != new.camera || old.apiPort != new.apiPort || old.rtspPort != new.rtspPort {
            need = .go2rtc
        }
        if old.recorder != new.recorder || old.storage.outDir != new.storage.outDir {
            need = (need == .go2rtc) ? .both : .recorder
        }
        switch need {
        case .none:
            break
        case .go2rtc, .both:
            if state.isActive {
                Task { await restartGo2rtc(reason: "配置变更") }
            }
        case .recorder:
            if state == .recording {
                ffmpeg?.interrupt()
                log("配置变更，重启录制")
            }
        }
        restartTimersForConfigChange()
        refreshStats()
    }

    // MARK: HTTP / shell

    private func apiGet(_ path: String, timeout: TimeInterval) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(config.apiPort)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return data
        } catch {
            return nil
        }
    }

    private func shell(_ path: String, _ args: [String]) async -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let code = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ c: Int32) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true; cont.resume(returning: c)
            }
            p.terminationHandler = { pr in finish(pr.terminationStatus) }
            DispatchQueue.global().async {
                while p.isRunning { usleep(100_000) }
                finish(p.terminationStatus)
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (code, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: 自检（由 `open -a MiCam2 --args --selftest` 触发，结果写日志）

    func runSelfTest() async {
        log("SELFTEST 开始")
        let p = await permissionCheckAsync()
        log("SELFTEST 权限: \(p ?? "通过")  FDA=\(Self.hasFullDiskAccess())")
        guard p == nil else {
            log("SELFTEST 结论: 失败（权限未就绪）")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            exit(2)
        }
        await start()
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        log("SELFTEST 状态: \(state.label)  go2rtc 模式=\(go2rtcMode)")

        await refreshPreview()
        log("SELFTEST 取帧: \(previewImage != nil ? "成功" : "失败")")
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        refreshStats()
        log("SELFTEST 当前段: \(currentFile) size=\(currentSize) 码率=\(String(format: "%.2f", bitrateMbps))Mbps")
        log("SELFTEST 今日: \(todayCount) 段 剩余=\(String(format: "%.0f", freeGB))GB")

        // 保留策略：先造一个过期文件，看它会不会被清掉
        let old = URL(fileURLWithPath: config.storage.outDir).appendingPathComponent("20000101_000000.mp4")
        FileManager.default.createFile(atPath: old.path, contents: Data(repeating: 0, count: 300_000))
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 30)], ofItemAtPath: old.path)
        log("SELFTEST 保留策略: 造了一个 30 天前的假段 \(old.lastPathComponent)")
        runPrune()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        log("SELFTEST 保留策略: 假段\(FileManager.default.fileExists(atPath: old.path) ? "还在（未清理）" : "已删除")")

        // 暂停 / 继续
        pause()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        log("SELFTEST 暂停后状态=\(state.label)")
        resume()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        log("SELFTEST 继续后状态=\(state.label)")

        await stop()
        log("SELFTEST 结束")
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0)
    }


    // MARK: 退出

    func shutdown() async {
        await stop()
    }
}