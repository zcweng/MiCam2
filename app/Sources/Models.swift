import Foundation

// MARK: - 配置模型

struct CameraConfig: Codable, Equatable {
    var name: String = "米家摄像机 2 云台版"
    var ip: String = ""
    var mac: String = ""
    var did: String = ""
    var model: String = "chuangmi.camera.039a01"
    /// go2rtc 的档位：1/2 = 864×480，3 = 2560×1440（2K）
    var subtype: Int = 3
    /// 小米账号（米 ID 或手机号）
    var account: String = ""
    /// 令牌（V1:...）或密码
    var secret: String = ""
    /// true = secret 是密码（走账号密码登录），false = secret 是 V1 令牌
    var secretIsPassword: Bool = false

    var isConfigured: Bool { !ip.isEmpty && (!account.isEmpty || !did.isEmpty) }

    var qualityLabel: String {
        switch subtype {
        case 3: return "2K 2560×1440"
        case 2: return "HD 864×480"
        default: return "SD 864×480"
        }
    }
}

struct RecorderConfig: Codable, Equatable {
    var segmentSeconds: Int = 300
    var readTimeoutSec: Int = 15
    var restartDelay: Int = 10
    var maxRetryDelay: Int = 300
}

struct StorageConfig: Codable, Equatable {
    var outDir: String = "/Volumes/Ugreen Disk/MiCam2"
    var keepDays: Int = 30
    /// 剩余空间低于这个值才按“最旧优先”删（GB）
    var minFreeGB: Int = 50
    /// 永远不删最近 N 个文件
    var protectNewest: Int = 3
}

struct WatchdogConfig: Codable, Equatable {
    var enabled: Bool = true
    var intervalSec: Int = 120
    /// 连续几次取帧失败才重启 go2rtc
    var failThreshold: Int = 3
}

struct MiCam2Config: Codable, Equatable {
    var camera = CameraConfig()
    var recorder = RecorderConfig()
    var storage = StorageConfig()
    var watchdog = WatchdogConfig()
    var apiPort: Int = 1984
    var rtspPort: Int = 8554
    var launchAtLogin: Bool = true

    /// 升级配置时补默认值：字段缺失不会导致读取失败
    init() {}

    enum CodingKeys: String, CodingKey {
        case camera, recorder, storage, watchdog, apiPort, rtspPort, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = (try? c.decodeIfPresent(CameraConfig.self, forKey: .camera)) .flatMap { $0 } ?? CameraConfig()
        recorder = (try? c.decodeIfPresent(RecorderConfig.self, forKey: .recorder)).flatMap { $0 } ?? RecorderConfig()
        storage = (try? c.decodeIfPresent(StorageConfig.self, forKey: .storage)).flatMap { $0 } ?? StorageConfig()
        watchdog = (try? c.decodeIfPresent(WatchdogConfig.self, forKey: .watchdog)).flatMap { $0 } ?? WatchdogConfig()
        apiPort = (try? c.decodeIfPresent(Int.self, forKey: .apiPort)).flatMap { $0 } ?? 1984
        rtspPort = (try? c.decodeIfPresent(Int.self, forKey: .rtspPort)).flatMap { $0 } ?? 8554
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)).flatMap { $0 } ?? true
    }

    // 子结构也要容错
    static func tolerant<T: Decodable>(_ type: T.Type, from c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, fallback: T) -> T {
        ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension CameraConfig {
    enum CodingKeys: String, CodingKey {
        case name, ip, mac, did, model, subtype, account, secret, secretIsPassword
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraConfig()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? d.name
        ip = (try? c.decodeIfPresent(String.self, forKey: .ip)) ?? nil ?? d.ip
        mac = (try? c.decodeIfPresent(String.self, forKey: .mac)) ?? nil ?? ""
        did = (try? c.decodeIfPresent(String.self, forKey: .did)) ?? nil ?? ""
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil ?? d.model
        subtype = (try? c.decodeIfPresent(Int.self, forKey: .subtype)) ?? nil ?? d.subtype
        account = (try? c.decodeIfPresent(String.self, forKey: .account)) ?? nil ?? ""
        secret = (try? c.decodeIfPresent(String.self, forKey: .secret)) ?? nil ?? ""
        secretIsPassword = (try? c.decodeIfPresent(Bool.self, forKey: .secretIsPassword)) ?? nil ?? false
    }
}

extension RecorderConfig {
    enum CodingKeys: String, CodingKey { case segmentSeconds, readTimeoutSec, restartDelay, maxRetryDelay }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecorderConfig()
        segmentSeconds = (try? c.decodeIfPresent(Int.self, forKey: .segmentSeconds)) ?? nil ?? d.segmentSeconds
        readTimeoutSec = (try? c.decodeIfPresent(Int.self, forKey: .readTimeoutSec)) ?? nil ?? d.readTimeoutSec
        restartDelay = (try? c.decodeIfPresent(Int.self, forKey: .restartDelay)) ?? nil ?? d.restartDelay
        maxRetryDelay = (try? c.decodeIfPresent(Int.self, forKey: .maxRetryDelay)) ?? nil ?? d.maxRetryDelay
    }
}

extension StorageConfig {
    enum CodingKeys: String, CodingKey { case outDir, keepDays, minFreeGB, protectNewest }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StorageConfig()
        outDir = (try? c.decodeIfPresent(String.self, forKey: .outDir)) ?? nil ?? d.outDir
        keepDays = (try? c.decodeIfPresent(Int.self, forKey: .keepDays)) ?? nil ?? d.keepDays
        minFreeGB = (try? c.decodeIfPresent(Int.self, forKey: .minFreeGB)) ?? nil ?? d.minFreeGB
        protectNewest = (try? c.decodeIfPresent(Int.self, forKey: .protectNewest)) ?? nil ?? d.protectNewest
    }
}

extension WatchdogConfig {
    enum CodingKeys: String, CodingKey { case enabled, intervalSec, failThreshold }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatchdogConfig()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil ?? d.enabled
        intervalSec = (try? c.decodeIfPresent(Int.self, forKey: .intervalSec)) ?? nil ?? d.intervalSec
        failThreshold = (try? c.decodeIfPresent(Int.self, forKey: .failThreshold)) ?? nil ?? d.failThreshold
    }
}

// MARK: - 路径

enum AppPaths {
    static let bundleResources = Bundle.main.resourceURL ?? Bundle.main.bundleURL

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MiCam2", isDirectory: true)
    }
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var yamlFile: URL { supportDir.appendingPathComponent("go2rtc.yaml") }

    static var logFile: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/MiCam2/app.log")
    }

    static func binary(_ name: String) -> URL? {
        let inBundle = bundleResources.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
        // 开发时回退
        let dev = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("micam2/bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    static var go2rtc: URL? { binary("go2rtc") }
    static var ffmpeg: URL? { binary("ffmpeg") }
}

// MARK: - 配置存储

final class ConfigStore {
    static let shared = ConfigStore()
    private(set) var config = MiCam2Config()

    private init() {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let cfg = try? JSONDecoder().decode(MiCam2Config.self, from: data) else { return }
        config = cfg
    }

    func save(_ new: MiCam2Config) {
        config = new
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(new) {
            try? data.write(to: AppPaths.configFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
        }
    }

    /// 生成 go2rtc.yaml（每次启动前重写，保证与配置一致）
    @discardableResult
    func writeGo2rtcYAML() throws -> URL {
        let cam = config.camera
        let ffmpegPath = AppPaths.ffmpeg?.path ?? "ffmpeg"
        var yaml = """
        # 由 MiCam2.app 自动生成，手动改动会被覆盖
        log:
          level: info
        api:
          listen: "127.0.0.1:\(config.apiPort)"
        rtsp:
          listen: "127.0.0.1:\(config.rtspPort)"
        ffmpeg:
          bin: "\(ffmpegPath)"
        streams:
        """

        let account = cam.account.isEmpty ? "user" : cam.account
        var urlPart: String
        if cam.secretIsPassword && !cam.secret.isEmpty {
            let user = percentEncode(account)
            let pass = percentEncode(cam.secret)
            urlPart = "\(user):\(pass)@\(cam.ip)"
        } else {
            urlPart = "\(percentEncode(account)):cn@\(cam.ip)"
        }
        // vendor / client_public / sign 由小米云在开流时注入，手写会干扰协商
        let query = ["did=\(cam.did.isEmpty ? "0" : cam.did)", "model=\(cam.model)", "subtype=\(cam.subtype)"]
        yaml += "\n  micam2: \"xiaomi://\(urlPart)?\(query.joined(separator: "&"))\"\n"

        if !cam.secretIsPassword && !cam.secret.isEmpty {
            yaml += "\nxiaomi:\n  \"\(account)\": \"\(cam.secret)\"\n"
        }

        try yaml.write(to: AppPaths.yamlFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.yamlFile.path)
        return AppPaths.yamlFile
    }

    private func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - 录像文件

struct Recording: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: modified)
    }
}

enum RecordingStore {
    static func list(_ dir: String) -> [Recording] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Recording] = []
        for n in names where n.hasSuffix(".mp4") {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(n)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            out.append(Recording(url: url, size: size, modified: date))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// 与 `df` / prune.sh 同一口径。不要用 ImportantUsage：外置盘上常低估甚至为 0，会触发按最旧狂删。
    static func freeGB(_ dir: String) -> Double? {
        if let vals = try? FileManager.default.attributesOfFileSystem(forPath: dir),
           let free = vals[.systemFreeSize] as? NSNumber {
            return free.doubleValue / 1_000_000_000
        }
        return nil
    }

    /// 返回 (删除数量, 释放字节)。
    /// 不按可播性删半截段：空壳/半截段也保留，只按天数与剩余空间清理。
    @discardableResult
    static func prune(_ cfg: StorageConfig) -> (Int, Int64) {
        let fm = FileManager.default
        let all = list(cfg.outDir)
        guard !all.isEmpty else { return (0, 0) }
        // 只保护“刚写过的文件”（15 分钟内），而不是机械地保护最新 N 个，
        // 否则目录里文件很少时，一个几年前的坏文件会被当成“最新”永远不动。
        let protectN = max(cfg.protectNewest, 0)
        var protected = all.filter { Date().timeIntervalSince($0.modified) < 900 }
        protected += all.prefix(protectN)
        let newest = Set(protected.map { $0.url.path })
        var removed = 0
        var freed: Int64 = 0

        func drop(_ r: Recording) {
            if (try? fm.removeItem(at: r.url)) != nil {
                removed += 1
                freed += r.size
            }
        }

        // 1) 超过保留天数
        var rest = list(cfg.outDir).filter { !newest.contains($0.url.path) }
        if cfg.keepDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(cfg.keepDays) * 86400)
            for r in rest where r.modified < cutoff { drop(r) }
            rest = list(cfg.outDir).filter { !newest.contains($0.url.path) }
        }

        // 2) 剩余空间兜底：从最旧的删，始终保留最近 protectNewest 个
        if let free = freeGB(cfg.outDir), free < Double(cfg.minFreeGB) {
            for r in rest.reversed() {
                guard let f = freeGB(cfg.outDir), f < Double(cfg.minFreeGB) else { break }
                let left = list(cfg.outDir).count
                if left <= protectN { break }
                drop(r)
            }
        }
        return (removed, freed)
    }
}