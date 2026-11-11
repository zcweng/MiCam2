import SwiftUI
import AppKit

// MARK: - 设置页

struct SettingsPane: View {
    @ObservedObject var supervisor: Supervisor
    @State private var draft = MiCam2Config()
    @State private var loaded = false
    @State private var legacy = LegacyState()
    @State private var message: String?
    @State private var showDeleteConfirm = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("存储") {
                    row("录像目录") {
                        HStack {
                            TextField("", text: $draft.storage.outDir)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("选择…") { pickFolder() }
                        }
                    }
                    row("保留天数") {
                        HStack {
                            TextField("", value: $draft.storage.keepDays, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("天（0 = 不按天数删）").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("最小空闲") {
                        HStack {
                            TextField("", value: $draft.storage.minFreeGB, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("GB，低于这个值按最旧优先删").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("保护最新") {
                        HStack {
                            TextField("", value: $draft.storage.protectNewest, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("个文件永不删除").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("清理") {
                        HStack {
                            Button("立刻清理一次") { supervisor.runPrune() }
                            Button("删除全部录像…") { showDeleteConfirm = true }
                                .foregroundStyle(.red)
                        }
                    }
                }

                section("录制") {
                    row("分段长度") {
                        HStack {
                            TextField("", value: $draft.recorder.segmentSeconds, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("秒/段（断电最多丢这么多，推荐 300）").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("读超时") {
                        HStack {
                            TextField("", value: $draft.recorder.readTimeoutSec, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("秒，断流多久判定为掉线").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("重连退避") {
                        HStack {
                            TextField("", value: $draft.recorder.restartDelay, format: .number)
                                .frame(width: 60).textFieldStyle(.roundedBorder)
                            Text("→ 上限")
                            TextField("", value: $draft.recorder.maxRetryDelay, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("秒").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                section("自愈看门狗") {
                    row("启用") {
                        Toggle("相机掉线/进程卡死时自动重启", isOn: $draft.watchdog.enabled)
                    }
                    row("检查间隔") {
                        HStack {
                            TextField("", value: $draft.watchdog.intervalSec, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("秒").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("失败阈值") {
                        HStack {
                            TextField("", value: $draft.watchdog.failThreshold, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("次取帧失败后重启 go2rtc").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("") {
                        Text("看门狗还会在相机 IP 变化时用 MAC 自动找回，不需要手改配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("相机") {
                    row("名称") { TextField("", text: $draft.camera.name).textFieldStyle(.roundedBorder) }
                    row("IP") {
                        HStack {
                            TextField("", text: $draft.camera.ip).textFieldStyle(.roundedBorder).frame(width: 160)
                            Button("探测") { detectCamera() }
                            Spacer()
                        }
                    }
                    row("MAC") {
                        HStack {
                            TextField("aa:bb:cc:dd:ee:ff", text: $draft.camera.mac)
                                .textFieldStyle(.roundedBorder).frame(width: 190)
                            Text("IP 变了靠它找回来").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("设备 DID") {
                        TextField("", text: $draft.camera.did).textFieldStyle(.roundedBorder).frame(width: 190)
                    }
                    row("型号串") {
                        TextField("", text: $draft.camera.model).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    row("画质") {
                        Picker("", selection: $draft.camera.subtype) {
                            Text("标清 864×480").tag(1)
                            Text("高清 864×480").tag(2)
                            Text("2K 2560×1440（推荐）").tag(3)
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }

                section("小米账号") {
                    row("账号") {
                        TextField("米 ID 或手机号", text: $draft.camera.account)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    row("凭据") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if draft.camera.secretIsPassword {
                                    SecureField("小米账号密码", text: $draft.camera.secret)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    TextField("V1: 开头的令牌", text: $draft.camera.secret)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                Button("粘贴") {
                                    if let s = NSPasteboard.general.string(forType: .string) {
                                        draft.camera.secret = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            }
                            Picker("类型", selection: $draft.camera.secretIsPassword) {
                                Text("V1 令牌（推荐，已验证可用）").tag(false)
                                Text("账号密码（首次登录用）").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Text("换相机或换账号时改这里；改完点「保存并应用」，会重启 go2rtc 并重新协商。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                section("高级") {
                    row("端口") {
                        HStack {
                            Text("API").font(.caption)
                            TextField("", value: $draft.apiPort, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("RTSP").font(.caption)
                            TextField("", value: $draft.rtspPort, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("（只监听 127.0.0.1）").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("开机自启") {
                        Toggle("随登录启动 MiCam2", isOn: $draft.launchAtLogin)
                    }
                    row("后台组件") {
                        HStack(spacing: 8) {
                            Button("重装/同步 go2rtc 助手") {
                                supervisor.log("重新安装后台助手…")
                                let yaml = (try? ConfigStore.shared.writeGo2rtcYAML()) ?? AppPaths.yamlFile
                                Go2rtcHelper.install(yamlPath: yaml.path) { ok, out in
                                    supervisor.log(ok ? "后台助手已重装" : "重装失败：\(out)")
                                }
                            }
                            Button("彻底停止后台服务") {
                                Go2rtcHelper.stopService { ok, out in
                                    supervisor.log(ok ? "后台服务已停止（下次开始录制会自动拉起）" : "停止失败：\(out)")
                                }
                            }
                            if Go2rtcHelper.isHelperBinaryStale() {
                                Text("与内置版本不一致").font(.caption).foregroundStyle(.orange)
                            } else if Go2rtcHelper.isInstalled {
                                Text("已安装且一致").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("未安装").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    row("自检") {
                        HStack {
                            Button("权限自检") { runSelfCheck() }
                            if let r = testResult {
                                Text(r).font(.caption).foregroundStyle(r.hasPrefix("通过") ? .green : .red)
                            }
                        }
                    }
                }

                section("从旧方案迁移") {
                    row("检测") {
                        HStack {
                            Text(legacy.summary).font(.caption).foregroundStyle(.secondary)
                            Button("重新检测") { legacy = Legacy.scan() }
                        }
                    }
                    row("操作") {
                        HStack {
                            Button("导入旧配置") { importLegacy() }
                                .disabled(!legacy.anythingFound)
                            Button("卸载旧服务…") { uninstallLegacy() }
                                .disabled(legacy.daemons.isEmpty && legacy.agents.isEmpty)
                                .foregroundStyle(.red)
                            if let m = message {
                                Text(m).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    row("") {
                        Text("卸载会把 /Library/LaunchDaemons 和 ~/Library/LaunchAgents 里的 com.micam2.* 全部移除（需要管理员密码），之后由 MiCam2.app 全权接管。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button("恢复为已保存的值") { draft = supervisor.config }
                    Button("保存并应用") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == supervisor.config)
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            if !loaded {
                draft = supervisor.config
                legacy = Legacy.scan()
                loaded = true
            }
        }
        .confirmationDialog("删除全部录像？此操作不可撤销。", isPresented: $showDeleteConfirm) {
            Button("删除全部", role: .destructive) {
                Task { await supervisor.deleteAll() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 9) { content() }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
                )
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: 动作

    private func save() {
        supervisor.apply(draft)
        if draft.launchAtLogin {
            LoginItem.install()
        } else {
            LoginItem.remove()
        }
        message = "已保存并应用"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.storage.outDir)
        if panel.runModal() == .OK, let url = panel.url {
            draft.storage.outDir = url.path
        }
    }

    private func runSelfCheck() {
        testing = true
        testResult = supervisor.permissionCheck() == nil ? "通过：能读写录像目录" : (supervisor.permissionCheck() ?? "")
        testing = false
    }

    private func detectCamera() {
        let out = Legacy.runSync("/usr/sbin/arp", ["-an"]) ?? ""
        for line in out.split(separator: "\n") {
            if let r = line.range(of: #"\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) at ([0-9a-f:]{11,17})"#, options: .regularExpression) {
                let s = String(line[r])
                let parts = s.replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "(", with: "").components(separatedBy: " at ")
                if parts.count == 2, parts[0] == draft.camera.ip {
                    draft.camera.mac = parts[1]
                    message = "已从 ARP 表读到 MAC"
                    return
                }
            }
        }
        message = "ARP 表里没有 \(draft.camera.ip)，先确认相机在线"
    }

    private func importLegacy() {
        if let cfg = Legacy.importConfig() {
            draft = cfg
            supervisor.apply(cfg)
            message = "已导入旧配置（记得检查账号凭据）"
        } else {
            message = "没找到可导入的旧配置"
        }
    }

    private func uninstallLegacy() {
        Legacy.uninstall { ok, out in
            message = ok ? "旧服务已卸载" : "卸载失败：\(out)"
            legacy = Legacy.scan()
        }
    }
}

// MARK: - 日志页

struct LogPane: View {
    @ObservedObject var supervisor: Supervisor
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("运行日志").font(.headline)
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll).toggleStyle(.checkbox)
                Button("打开日志文件") { NSWorkspace.shared.open(AppPaths.logFile) }
                Spacer()
                Button("复制") {
                    let text = supervisor.logs.map { $0.text }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(supervisor.logs) { line in
                            Text("[\(stamp(line.date))] \(line.text)")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: supervisor.logs.count) { _, _ in
                    guard autoScroll, let last = supervisor.logs.last else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - 关于页

struct AboutPane: View {
    @ObservedObject var supervisor: Supervisor
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("MiCam2").font(.title2.weight(.semibold))
                        Text("小米摄像机 2 云台版 · 局域网 24 小时录像").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card {
                    info("版本", "1.0 (build 1)")
                    info("go2rtc", AppPaths.go2rtc?.path ?? "未打包")
                    info("ffmpeg", AppPaths.ffmpeg?.path ?? "未打包")
                    info("配置", AppPaths.configFile.path)
                    info("日志", AppPaths.logFile.path)
                }

                Card {
                    Text("权限").font(.headline)
                    Text("只需要给 MiCam2 一个「完全磁盘访问权限」，不再需要把 /bin/bash 交给它。把录像写到外置盘时，系统会再问一次（可移除卷），点允许即可。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("打开完全磁盘访问权限") {
                            openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Button("重新自检") {
                            _ = supervisor.permissionCheck()
                        }
                    }
                }

                Card {
                    Text("怎么用").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 「设置 → 相机」填 IP / DID / 型号串，或点「导入旧配置」。").font(.callout)
                        Text("2. 「设置 → 小米账号」粘贴 V1 令牌（或输入账号密码登录一次）。").font(.callout)
                        Text("3. 回「状态」页点开始，菜单栏会常驻；关掉窗口也不会停。").font(.callout)
                        Text("4. 关掉电脑再开、断电再上电，都会自己恢复（登录自启 + 看门狗）。").font(.callout)
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
            )
    }
}