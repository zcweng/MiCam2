import SwiftUI
import AppKit

@main
struct MiCam2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var supervisor = Supervisor.shared

    init() {
        NSLog("MiCam2: App.init")
        Bootstrap.run()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(supervisor: supervisor)
        } label: {
            Label("MiCam2", systemImage: MenuContent.icon(for: supervisor.state))
        }
        .menuBarExtraStyle(.menu)

        Window("MiCam2 录像", id: "main") {
            MainWindow(supervisor: supervisor)
        }
        .defaultSize(width: 940, height: 640)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("打开主窗口") { WindowOpener.open() }
                    .keyboardShortcut("0")
            }
        }
    }
}

enum WindowOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        // 关窗后窗口会销毁，这里用 AppleScript 以外的兜底：遍历已有窗口，没有再走 URL 触发
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.title.contains("MiCam2") }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .micam2ShowWindow, object: nil)
        }
    }
}

extension Notification.Name {
    static let micam2ShowWindow = Notification.Name("micam2.showWindow")
}

enum Bootstrap {
    private static var done = false

    /// 启动逻辑放这里而不是 delegate 回调：SwiftUI 的 delegate 适配在某些启动路径下不回调，
    /// 而 App.init 一定会执行。多次调用是幂等的。
    static func run() {
        guard !done else { return }
        done = true
        NSLog("MiCam2: Bootstrap.run")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        Task { @MainActor in
            let sup = Supervisor.shared
            // 不自动开始时不去碰外置盘：否则会弹出「可移除卷」授权框，
            // 而挂起的授权框会让别的进程（旧录制）也写不进去。
            if CommandLine.arguments.contains("--no-autostart") {
                sup.log("界面已打开（未自动开始）。授权后点「开始」。")
                return
            }
            if CommandLine.arguments.contains("--testwrite") {
                await sup.testVolumeWrite()
                sup.log("TESTWRITE 汇总 可写=\(sup.volumeOK)")
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            if CommandLine.arguments.contains("--probevolume") {
                await sup.probeVolumeNow()
                sup.log("PROBE 完成 可写=\(sup.volumeOK)")
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(0)
            }
            if Legacy.scan().kitIsRunning && !CommandLine.arguments.contains("--force-start") {
                sup.log("旧服务还在录制：先点「一键接管」把它们卸掉，再让 MiCam2 开录")
                sup.setBlockedByLegacy()
                return
            }
            sup.log("界面启动完成，权限自检：\(await sup.permissionCheckAsync() ?? "通过")")
            if sup.config.launchAtLogin && !LoginItem.isEnabled {
                LoginItem.install()
                sup.log("已设置开机自启")
            }
            if CommandLine.arguments.contains("--checkperm") {
                sup.log("CHECKPERM FDA=\(Supervisor.hasFullDiskAccess()) 可写=\(sup.volumeOK) 旧服务在跑=\(Legacy.scan().kitIsRunning)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(0)
            }
            if CommandLine.arguments.contains("--selftest") {
                await sup.runSelfTest()
                return
            }
            if sup.config.camera.isConfigured {
                await sup.start()
            } else {
                sup.log("还没有配置相机，请到「设置 → 相机」填写或点「导入旧配置」")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MiCam2: didFinishLaunching")
        let me = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.suke.micam2")
        if me.count > 1 && !CommandLine.arguments.contains("--allow-multi") {
            NSApp.terminate(nil)
            return
        }
        Bootstrap.run()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Supervisor.shared.emergencyStop()
    }
}

// MARK: - 菜单栏

struct MenuContent: View {
    @ObservedObject var supervisor: Supervisor

    static func icon(for state: RunState) -> String {
        switch state {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .starting: return "arrow.triangle.2.circlepath"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Text("MiCam2 · \(supervisor.state.label)")
        Text(supervisor.currentFile.isEmpty ? "—" : supervisor.currentFile)
            .font(.caption)
            .foregroundStyle(.secondary)
        Divider()
        Button("打开主窗口") { windowFront() }
        Button("打开录像目录") {
            NSWorkspace.shared.open(URL(fileURLWithPath: supervisor.config.storage.outDir))
        }
        Divider()
        Button(supervisor.state == .recording ? "暂停录制" : "开始录制") {
            Task { await supervisor.toggle() }
        }
        Button("停止") {
            Task { await supervisor.stop() }
        }
        .disabled(!supervisor.state.isActive)
        Divider()
        Button("退出 MiCam2") {
            Task {
                await supervisor.stop()
                NSApp.terminate(nil)
            }
        }
    }

    private func windowFront() {
        WindowOpener.open()
        for w in NSApp.windows where w.canBecomeMain {
            w.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - 主窗口

enum MainTab: String, CaseIterable, Identifiable {
    case status = "状态"
    case settings = "设置"
    case logs = "日志"
    case about = "关于"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .status: return "video.fill"
        case .settings: return "slider.horizontal.3"
        case .logs: return "text.alignleft"
        case .about: return "info.circle"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var supervisor: Supervisor
    @State private var tab: MainTab = .status

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(MainTab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t.icon).frame(width: 18)
                            Text(t.rawValue)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(tab == t ? Color.accentColor.opacity(0.16) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                StatusDot(state: supervisor.state)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .padding(10)
            .frame(width: 148)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            Divider()

            Group {
                switch tab {
                case .status: StatusPane(supervisor: supervisor)
                case .settings: SettingsPane(supervisor: supervisor)
                case .logs: LogPane(supervisor: supervisor)
                case .about: AboutPane(supervisor: supervisor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: .micam2ShowWindow)) { _ in
            for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        }
    }
}

struct StatusDot: View {
    let state: RunState
    var color: Color {
        switch state {
        case .recording: return .green
        case .paused: return .orange
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(state.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - 状态页

struct StatusPane: View {
    @ObservedObject var supervisor: Supervisor
    @Environment(\.openURL) private var openURL
    @State private var legacy = LegacyState()
    @State private var fdaGranted = Supervisor.hasFullDiskAccess()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let problem = supervisor.permissionProblem {
                    banner(problem, kind: .error)
                }
                if !supervisor.config.camera.isConfigured {
                    banner("还没有配置相机：在「设置 → 相机」填写，或把旧方案的配置导入进来。", kind: .warning, pane: "Privacy_AllFiles")
                }
                if !supervisor.volumeOK {
                    permissionBanner
                }
                if supervisor.networkProblem {
                    banner("本地网络权限没授予：go2rtc 连不上局域网里的相机（报 i/o timeout）。去「系统设置 → 隐私与安全性 → 本地网络」勾选 MiCam2，然后点“重新检测”。",
                           kind: .error, pane: "Privacy_LocalNetwork")
                }
                if supervisor.blockedByLegacy {
                    legacyBanner
                }
                if !Go2rtcHelper.isInstalled {
                    helperBanner
                }
                if legacy.kitIsRunning && !legacy.daemons.isEmpty {
                    legacyBanner
                }
                HStack(alignment: .top, spacing: 16) {
                    previewCard
                    statsCard
                }
                recentCard
            }
            .padding(18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { legacy = Legacy.scan(); fdaGranted = Supervisor.hasFullDiskAccess() }
        .task {
            legacy = Legacy.scan()
            fdaGranted = Supervisor.hasFullDiskAccess()
            // 每 3 秒自动刷新一次授权状态：用户在系统设置里勾完不用回来点“重新检测”
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let now = Supervisor.hasFullDiskAccess()
                if now != fdaGranted {
                    fdaGranted = now
                    if now { supervisor.log("检测到已授予完全磁盘访问权限") }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(supervisor.config.camera.name).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text("\(supervisor.config.camera.ip) · \(supervisor.config.camera.qualityLabel)")
                    if !supervisor.currentFile.isEmpty {
                        Text("· \(supervisor.currentFile)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task { await supervisor.toggle() }
                } label: {
                    Label(supervisor.state == .recording ? "暂停" : "开始",
                          systemImage: supervisor.state == .recording ? "pause.fill" : "play.fill")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(supervisor.state == .starting)

                Button {
                    Task { await supervisor.stop() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!supervisor.state.isActive)
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85))
                if let img = supervisor.previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.system(size: 26))
                        Text(supervisor.state.isActive ? "等待画面…" : "未录制")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: 420)

            Text("画面每 2 秒刷新一次（go2rtc 取单帧）")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            statRow("状态", supervisor.state.label)
            statRow("当前段", supervisor.currentFile.isEmpty ? "—" : supervisor.currentFile)
            statRow("段大小", supervisor.currentSize > 0
                    ? ByteCountFormatter.string(fromByteCount: supervisor.currentSize, countStyle: .file) : "—")
            statRow("码率", supervisor.bitrateMbps > 0 ? String(format: "%.2f Mbps", supervisor.bitrateMbps) : "—")
            Divider()
            statRow("今日", "\(supervisor.todayCount) 段 / \(ByteCountFormatter.string(fromByteCount: supervisor.todayBytes, countStyle: .file))")
            statRow("剩余空间", String(format: "%.0f GB", supervisor.freeGB))
            statRow("磁盘授权", supervisor.volumeOK
                    ? (fdaGranted ? "完全磁盘访问 ✓" : "可写 ✓（可移除卷授权）")
                    : "未授权（下面两种方式二选一）")
            statRow("保留", "\(supervisor.config.storage.keepDays) 天（低于 \(supervisor.config.storage.minFreeGB)GB 时按最旧删）")
            statRow("go2rtc", supervisor.go2rtcPID > 0
                    ? "运行中 pid \(supervisor.go2rtcPID)（\(supervisor.go2rtcMode)）"
                    : (Go2rtcHelper.isInstalled ? "后台助手" : "未运行"))
            if let lw = supervisor.lastWatchdog {
                statRow("上次自检", timeText(lw))
            }
        }
        .padding(14)
        .frame(maxWidth: 380, alignment: .leading)
        .background(card)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近录像").font(.headline)
                Spacer()
                Button("打开目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: supervisor.config.storage.outDir))
                }
                .buttonStyle(.link)
                Button("清理一次") { supervisor.runPrune() }
                    .buttonStyle(.link)
            }
            if supervisor.recordings.isEmpty {
                Text("还没有录像文件").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(supervisor.recordings.prefix(6)) { r in
                        HStack {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                            Text(r.name).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(r.sizeText).foregroundStyle(.secondary).font(.caption)
                            Text(r.timeText).foregroundStyle(.secondary).font(.caption)
                            Button("播放") { NSWorkspace.shared.open(r.url) }
                                .buttonStyle(.link)
                            Button("显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([r.url])
                            }
                            .buttonStyle(.link)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .background(card)
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("还没有写入录像目录的权限").font(.callout).bold()
                Text("推荐：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 勾选 MiCam2。这条路不弹窗、不会卡住别的程序。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("只想授权这一块盘的话：点“测试并授权”，屏幕会弹「MiCam2 想访问可移除卷上的文件」，请 10 秒内点允许；不点它会自己收尾。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("⚠️ 授权框挂着不点，会让所有程序（包括正在录的旧服务）都写不进这块盘——实测会卡死正在写的 ffmpeg。")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("测试并授权") {
                        Task { await supervisor.probeVolumeNow() }
                    }.buttonStyle(.borderedProminent)
                    Button("打开完全磁盘访问设置") {
                        openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("解除卡住的弹窗") { supervisor.dismissStuckPrompt() }
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var helperBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("还需要装一个后台组件（go2rtc）").font(.callout)
                Text("macOS 15 不给未签名的 app 弹「本地网络」授权，所以取流这一步由一个小后台服务以 root 跑：它只做网络、不碰任何文件。安装需要一次管理员密码。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("安装后台组件") {
                supervisor.log("开始安装后台助手…")
                let yaml = (try? ConfigStore.shared.writeGo2rtcYAML()) ?? AppPaths.yamlFile
                Go2rtcHelper.install(yamlPath: yaml.path) { ok, out in
                    supervisor.log(ok ? "后台助手安装成功" : "后台助手安装失败：\(out)")
                    Task { @MainActor in
                        if ok {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            await supervisor.start()
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var legacyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到旧的 launchd 服务还在跑：\(legacy.summary)")
                    .font(.callout)
                Text(supervisor.volumeOK
                     ? "一键接管会卸载它们（需要管理员密码），然后由 MiCam2 自己起 go2rtc 和录制。"
                     : "先让 MiCam2 拿到这块盘的写入权限再接管——否则接管完旧录制停了，新录制又写不进盘。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("一键接管") {
                supervisor.log("开始接管：卸载旧服务…")
                Legacy.uninstall { ok, out in
                    if ok {
                        supervisor.log("旧服务已卸载")
                        legacy = Legacy.scan()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            await supervisor.start()
                            legacy = Legacy.scan()
                        }
                    } else {
                        supervisor.log("卸载旧服务失败：\(out)")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!supervisor.volumeOK)
        }
        .padding(12)
        .background(Color.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(v).font(.system(.body, design: .rounded)).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private enum BannerKind { case warning, error }
    private func banner(_ text: String, kind: BannerKind, pane: String = "Privacy_AllFiles") -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .error ? .red : .orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("打开权限设置") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
            .buttonStyle(.bordered)
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .buttonStyle(.bordered)
            Button("重新检测") {
                Task { @MainActor in
                    if await supervisor.recheckPermissions() == nil { await supervisor.start() }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background((kind == .error ? Color.red : Color.orange).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}