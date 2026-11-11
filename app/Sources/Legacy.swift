import Foundation
import AppKit

// MARK: - 旧方案（4 个 launchd 服务 + ~/micam2 目录）的检测、导入与卸载

struct LegacyState {
    var daemons: [String] = []      // /Library/LaunchDaemons 里的
    var agents: [String] = []       // ~/Library/LaunchAgents 里的
    var kitExists = false
    var kitIsRunning = false

    var anythingFound: Bool { !daemons.isEmpty || !agents.isEmpty || kitExists }

    var summary: String {
        var bits: [String] = []
        if !daemons.isEmpty { bits.append("守护进程 \(daemons.count) 个") }
        if !agents.isEmpty { bits.append("用户代理 \(agents.count) 个") }
        if kitExists { bits.append("~/micam2 配置目录") }
        return bits.isEmpty ? "未发现旧方案" : bits.joined(separator: "、")
    }
}

enum Legacy {
    static let daemonLabels = ["com.micam2.go2rtc", "com.micam2.watchdog"]
    static let agentLabels = ["com.micam2.recorder", "com.micam2.prune"]

    static func scan() -> LegacyState {
        var s = LegacyState()
        let dm = FileManager.default
        for label in daemonLabels where dm.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist") {
            s.daemons.append(label)
        }
        for label in agentLabels where dm.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist") {
            s.agents.append(label)
        }
        let kit = NSHomeDirectory() + "/micam2"
        s.kitExists = dm.fileExists(atPath: kit)
        if let out = runSync("/bin/launchctl", ["list"]), out.contains("com.micam2.") {
            s.kitIsRunning = true
        }
        return s
    }

    /// 从旧目录导入配置（yaml + config.env）
    static func importConfig() -> MiCam2Config? {
        let kit = NSHomeDirectory() + "/micam2"
        var cfg = MiCam2Config()
        var found = false

        if let yaml = try? String(contentsOfFile: kit + "/go2rtc.yaml", encoding: .utf8) {
            found = true
            if let range = yaml.range(of: #"xiaomi://([^"?]+)@([0-9.]+)\?([^"]+)"#, options: .regularExpression) {
                let m = String(yaml[range])
                let parts = m.dropFirst("xiaomi://".count)
                if let at = parts.firstIndex(of: "@") {
                    let cred = parts[parts.startIndex..<at]                 // user:pass
                    let rest = parts[parts.index(after: at)...]             // ip?query
                    let userId = cred.split(separator: ":").first.map(String.init) ?? ""
                    cfg.camera.account = userId
                    if let q = rest.firstIndex(of: "?") {
                        cfg.camera.ip = String(rest[rest.startIndex..<q])
                        let query = String(rest[rest.index(after: q)...])
                        for kv in query.split(separator: "&") {
                            let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
                            guard pair.count == 2 else { continue }
                            switch pair[0] {
                            case "did": cfg.camera.did = pair[1]
                            case "model": cfg.camera.model = pair[1]
                            case "subtype": cfg.camera.subtype = Int(pair[1]) ?? 3
                            default: break
                            }
                        }
                    }
                }
            }
            // xiaomi: {"<米ID>": "V1:..."}
            if let r = yaml.range(of: #"\"[0-9]+\":\s*\"(V1:[^"]+)\""#, options: .regularExpression) {
                let line = String(yaml[r])
                if let q1 = line.range(of: "\""), let q2 = line.range(of: "\"", options: [], range: q1.upperBound..<line.endIndex) {
                    _ = q2
                }
                if let tokRange = line.range(of: "V1:")  {
                    var tok = String(line[tokRange.lowerBound...])
                    if tok.hasSuffix("\"") { tok.removeLast() }
                    cfg.camera.secret = tok
                    cfg.camera.secretIsPassword = false
                }
            }
            if let r = yaml.range(of: #"listen:\s*"127\.0\.0\.1:(\d{2,5})""#, options: .regularExpression) {
                let s = String(yaml[r])
                if let n = s.split(separator: ":").last.map({ Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }) {
                    cfg.apiPort = n ?? cfg.apiPort
                }
            }
        }

        if let env = try? String(contentsOfFile: kit + "/config.env", encoding: .utf8) {
            found = true
            for line in env.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                let key = String(t[t.startIndex..<eq])
                var val = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch key {
                case "OUT_DIR": cfg.storage.outDir = val
                case "SEGMENT_SECONDS": cfg.recorder.segmentSeconds = Int(val) ?? cfg.recorder.segmentSeconds
                case "KEEP_DAYS": cfg.storage.keepDays = Int(val) ?? cfg.storage.keepDays
                case "MIN_FREE_GB": cfg.storage.minFreeGB = Int(val) ?? cfg.storage.minFreeGB
                case "PROTECT_NEWEST": cfg.storage.protectNewest = Int(val) ?? cfg.storage.protectNewest
                case "READ_TIMEOUT_US": cfg.recorder.readTimeoutSec = (Int(val) ?? 15_000_000) / 1_000_000
                case "MAX_RETRY_DELAY": cfg.recorder.maxRetryDelay = Int(val) ?? cfg.recorder.maxRetryDelay
                case "CAMERA_MAC": cfg.camera.mac = val
                default: break
                }
                val = ""
            }
        }

        // 从 arp 表补 MAC
        if cfg.camera.mac.isEmpty, let out = runSync("/usr/sbin/arp", ["-an"]) {
            for line in out.split(separator: "\n") where line.contains("(\(cfg.camera.ip))") {
                let parts = line.split(separator: " ")
                if parts.count > 4 { cfg.camera.mac = String(parts[3]) }
            }
        }
        return found ? cfg : nil
    }

    /// 卸载旧 launchd 服务（需要管理员密码，会弹系统授权框）
    static func uninstall(completion: @escaping (Bool, String) -> Void) {
        var cmds: [String] = []
        for label in daemonLabels {
            cmds.append("launchctl bootout system/\(label) 2>/dev/null || true")
            cmds.append("rm -f /Library/LaunchDaemons/\(label).plist")
        }
        for label in agentLabels {
            cmds.append("launchctl bootout gui/$(id -u suke)/\(label) 2>/dev/null || true")
            cmds.append("rm -f \(NSHomeDirectory())/Library/LaunchAgents/\(label).plist")
        }
        // 停掉还在跑的旧进程
        cmds.append("pkill -f '\(NSHomeDirectory())/micam2/bin/go2rtc' 2>/dev/null || true")
        cmds.append("pkill -f '\(NSHomeDirectory())/micam2/bin/ffmpeg' 2>/dev/null || true")
        let script = cmds.joined(separator: "; ")
        runAdmin(script, completion: completion)
    }

    static func removeKit(completion: @escaping (Bool, String) -> Void) {
        runAdmin("rm -rf \(NSHomeDirectory())/micam2", completion: completion)
    }

    static func runAdmin(_ script: String, completion: @escaping (Bool, String) -> Void) {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                completion(proc.terminationStatus == 0, text)
            }
        }
        do { try p.run() } catch {
            DispatchQueue.main.async { completion(false, error.localizedDescription) }
        }
    }

    @discardableResult
    static func runSync(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 开机自启（一个指向本 app 的 LaunchAgent）

enum LoginItem {
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.micam2.app.plist"
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func install() {
        let app = Bundle.main.bundlePath
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>com.micam2.app</string>
          <key>ProgramArguments</key><array>
            <string>/usr/bin/open</string><string>-a</string><string>\(app)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ThrottleInterval</key><integer>20</integer>
        </dict></plist>
        """
        try? content.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = Legacy.runSync("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
        _ = Legacy.runSync("/bin/launchctl", ["enable", "gui/\(getuid())/com.micam2.app"])
    }

    static func remove() {
        _ = Legacy.runSync("/bin/launchctl", ["bootout", "gui/\(getuid())/com.micam2.app"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }
}