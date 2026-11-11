import Foundation
import AppKit

/// go2rtc 后台助手
///
/// 为什么需要它：macOS 15 的「本地网络」TCC 对 ad-hoc 签名的 app 会**静默拒绝**（不弹窗），
/// 而验证过的绕过方式是 root（root 不受本地网络限制）。所以 go2rtc 作为一个极小的 root
/// LaunchDaemon 运行；它只负责网络取流，不读写任何用户文件，文件权限全部留在 app 自己身上。
enum Go2rtcHelper {
    static let label = "com.micam2.go2rtc"
    static let daemonPlist = "/Library/LaunchDaemons/com.micam2.go2rtc.plist"
    static let supportDir = "/Library/Application Support/MiCam2"
    static let binaryPath = supportDir + "/go2rtc"
    static let sudoersPath = "/etc/sudoers.d/micam2"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlist)
            && FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    /// 助手里的 go2rtc 是否和 app 内置的不是同一份（大小不同即认为不同）
    static func isHelperBinaryStale() -> Bool {
        guard let bin = AppPaths.go2rtc else { return false }
        let a = (try? FileManager.default.attributesOfItem(atPath: binaryPath)[.size] as? NSNumber)?.intValue ?? -1
        let b = (try? FileManager.default.attributesOfItem(atPath: bin.path)[.size] as? NSNumber)?.intValue ?? -2
        return a != b
    }

    static var isRunning: Bool {
        // 用 pgrep 判断比 launchctl print 简单，且不需要权限
        guard let out = Legacy.runSync("/bin/ps", ["-Ao", "command"]) else { return false }
        // 必须逐行精确匹配进程自身的命令行：
        // 旧写法是 out.contains(binaryPath) && !out.contains("grep")，
        // 结果只要机器上任何一条命令行里带 "grep"（比如有人在 ssh 里跑 grep），
        // 就会被判成“助手不在”，看门狗于是每 120 秒杀掉一次正在录的流。真 bug。
        return out.split(separator: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line == binaryPath || line.hasPrefix(binaryPath + " ")
        }
    }

    /// 安装：拷二进制 + 写 LaunchDaemon + 写最小 sudoers 白名单（只放行 restart/bootout）
    static func install(yamlPath: String, completion: @escaping (Bool, String) -> Void) {
        guard let bin = AppPaths.go2rtc else {
            completion(false, "应用包里没有 go2rtc")
            return
        }
        let user = NSUserName()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array>
            <string>\(binaryPath)</string>
            <string>-config</string>
            <string>\(yamlPath)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>10</integer>
          <key>StandardOutPath</key><string>/var/log/micam2-go2rtc.log</string>
          <key>StandardErrorPath</key><string>/var/log/micam2-go2rtc.log</string>
        </dict></plist>
        """
        let plistEscaped = shellEscape(plist)
        let script = """
        set -e
        /bin/mkdir -p '\(supportDir)'
        /bin/cp '\(bin.path)' '\(binaryPath)'
        /bin/chmod 755 '\(binaryPath)'
        /usr/bin/xattr -c '\(binaryPath)' 2>/dev/null || true
        /bin/echo \(plistEscaped) > '\(daemonPlist)'
        /usr/sbin/chown root:wheel '\(daemonPlist)'
        /bin/chmod 644 '\(daemonPlist)'
        /bin/echo '\(user) ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/\(label)' > '\(sudoersPath)'
        /bin/chmod 440 '\(sudoersPath)'
        /usr/sbin/visudo -cf '\(sudoersPath)' >/dev/null
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system '\(daemonPlist)'
        """
        Legacy.runAdmin(script, completion: completion)
    }

    /// 重启（走 sudoers 白名单，不会弹密码）
    @discardableResult
    static func restart() -> Bool {
        let (code, _) = runWithTimeout("/usr/bin/sudo", ["-n", "/bin/launchctl", "kickstart", "-k", "system/\(label)"], timeout: 30)
        return code == 0
    }

    /// 彻底停止后台服务（需要管理员密码）
    static func stopService(completion: @escaping (Bool, String) -> Void) {
        Legacy.runAdmin("""
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        """, completion: completion)
    }

    static func uninstall(completion: @escaping (Bool, String) -> Void) {
        Legacy.runAdmin("""
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -f '\(daemonPlist)' '\(sudoersPath)' '\(binaryPath)'
        """, completion: completion)
    }

    /// go2rtc 的日志（root 写的，末尾 200 行）
    static func tailLog(lines: Int = 120) -> String {
        guard let s = Legacy.runSync("/usr/bin/tail", ["-n", String(lines), "/var/log/micam2-go2rtc.log"]) else { return "" }
        return s
    }

    // MARK: 工具

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runWithTimeout(_ path: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}