import Foundation
import DiskProbeCore

// MARK: - SMART 信息模型

/// 一块盘的 SMART 摘要。字段为 nil 表示该盘不支持/读取失败。
struct SMARTInfo: Sendable {
    var health: String?          // "PASSED" / "FAILED" / nil(不支持)
    var temperatureC: Double?    // 温度（摄氏度）
    var powerOnHours: Int?       // 通电时间（小时）
    var model: String?           // 型号
    var serial: String?          // 序列号
    var firmware: String?        // 固件版本
    var interface: String?       // 接口类型（SATA/NVMe/USB...）
    var capacityBytes: Int64?    // 容量

    // HDD（ATA 属性）
    var reallocatedSectors: Int?    // 05 重映射扇区数
    var pendingSectors: Int?        // 197 当前待映射扇区
    var offlineUncorrectable: Int?  // 198 离线不可纠正扇区
    var crcErrors: Int?             // 199 接口 CRC 错误（多为线缆/接口问题）

    // SSD (NVMe)
    var percentUsed: Int?           // 寿命已用百分比
    var dataUnitsWritten: Int64?    // 已写数据量（512B 单位）
    var nandWrites: Int64?          // NAND 写入
    var mediaErrors: Int?           // 介质错误数（盘面/闪存读错误）

    /// 总体判断：是否健康
    var isHealthy: Bool? {
        guard let h = health else { return nil }
        if h.localizedCaseInsensitiveContains("passed") { return true }
        if h.localizedCaseInsensitiveContains("failed") { return false }
        return nil
    }
}

// MARK: - SMART 读取器

/// 通过 smartctl（smartmontools）读取 SMART 信息。
/// 用户机器已安装 smartctl 7.5（brew）。
/// 若未安装，返回错误信息提示用户。
actor SMARTReader {

    /// 读取指定盘的 SMART。devicePath 如 "/dev/disk4"。
    /// 输出 smartctl -j -a 的 JSON 并解析关键字段。
    static func read(bsdName: String) async -> Result<SMARTInfo, SMARTError> {
        let device = "/dev/\(bsdName)"
        guard let smartctl = findSmartctl() else {
            return .failure(.notInstalled)
        }

        // smartctl -j -a /dev/diskX  — 全部信息，JSON 格式
        let (output, exitStatus) = runProcess(smartctl, args: ["-j", "-a", device])
        if exitStatus == Self.spawnFailureExitStatus {
            return .failure(.unknown(tr("无法启动 smartctl（可能被安全软件拦截或安装损坏）。",
                                       "Cannot launch smartctl (possibly blocked by security software or a broken install).")))
        }
        if exitStatus == Self.timeoutExitStatus {
            return .failure(.unknown(tr("读取超时（\(Int(Self.processTimeout)) 秒）：设备可能已卡死，常见于硬盘盒/线缆接触问题。",
                                       "Timed out after \(Int(Self.processTimeout)) s: the device may be wedged — commonly an enclosure or cable problem.")))
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 退出码 bit1(2) = 设备打开失败（权限/设备消失），此时不会有有效 JSON
            if exitStatus & 0x02 != 0 {
                return .failure(.unknown(tr("无法打开 \(device)（设备不存在或需要更高权限）。",
                                           "Cannot open \(device) (missing, or needs elevated access).")))
            }
            return .failure(.parseFailed)
        }

        // 设备不支持 SMART 时的典型响应：smartctl 输出错误文本而非 JSON
        if let err = json["smartctl"] as? [String: Any],
           let msg = err["message"] as? String,
           msg.localizedCaseInsensitiveContains("unsupported") {
            return .failure(.unsupported(msg))
        }

        var info = SMARTInfo()
        // 设备信息
        if let dev = json["device"] as? [String: Any] {
            info.interface = dev["type"] as? String
        }
        info.model = json["model_name"] as? String
        info.serial = json["serial_number"] as? String
        info.firmware = json["firmware_version"] as? String
        if let cap = json["user_capacity"] as? [String: Any],
           let bytes = cap["bytes"] as? Int64 {
            info.capacityBytes = bytes
        }
        // 健康状态（ATA: "smartctl" → "smart_status"；NVMe: "nvme_smart_health_information_log"）
        if let st = json["smart_status"] as? [String: Any] {
            info.health = st["passed"] as? Bool == true ? "PASSED" : "FAILED"
        } else if let nvme = json["nvme_smart_health_information_log"] as? [String: Any] {
            if nvme["critical_warning"] as? Int == 0 {
                info.health = "PASSED"
            } else {
                info.health = "FAILED"
            }
        }
        // smartctl 退出码是位掩码而非简单的成败标志：bit3(8) = SMART 状态检查
        // 返回 FAILED。坏盘恰恰会以非 0 退出码输出合法 JSON，所以 JSON 解析
        // 不能依赖退出码，但退出码可以用来兜底强制 FAILED。
        if exitStatus & 0x08 != 0 {
            info.health = "FAILED"
        }

        // ATA 属性表
        if let attrs = json["ata_smart_attributes"] as? [String: Any],
           let table = attrs["table"] as? [[String: Any]] {
            for a in table {
                guard let id = a["id"] as? Int else { continue }
                // 注意：raw.value 对多字节属性不可靠（如 Power_On_Hours 的 raw 值是
                // 端序混叠的整数）。正确数值在 raw.string 前缀里：
                //   "2263 (168 229 0)"  → 2263
                //   "34 (Min/Max 28/36)" → 34
                //   "0"                 → 0
                let rawStr = (a["raw"] as? [String: Any])?["string"] as? String ?? ""
                let num = Self.parseInt(rawStr)
                switch id {
                case 5:   info.reallocatedSectors = num
                case 9:   info.powerOnHours = num
                case 190: if info.temperatureC == nil { info.temperatureC = num.map(Double.init) }
                case 194: info.temperatureC = num.map(Double.init) // Temperature_Celsius 优先
                case 197: info.pendingSectors = num
                case 198: info.offlineUncorrectable = num
                case 199: info.crcErrors = num
                default: break
                }
            }
        }

        // NVMe SMART
        if let nvme = json["nvme_smart_health_information_log"] as? [String: Any] {
            info.percentUsed = nvme["percentage_used"] as? Int
            info.mediaErrors = nvme["media_errors"] as? Int
            if let temp = nvme["temperature"] as? Int {
                // 实测确认：smartctl 7.5 的 NVMe JSON temperature 已是摄氏度
                // （smartmontools 内部已把 NVMe log 的开尔文换算成摄氏度）
                info.temperatureC = Double(temp)
            }
            if let ph = nvme["power_on_hours"] as? Int {
                info.powerOnHours = ph
            }
            // data_units_written 单位是 1000 × 512B
            if let duw = nvme["data_units_written"] as? Int64, duw >= 0 {
                let (thousands, firstOverflow) = duw.multipliedReportingOverflow(by: 1000)
                let (bytes, secondOverflow) = thousands.multipliedReportingOverflow(by: 512)
                if !firstOverflow && !secondOverflow {
                    info.dataUnitsWritten = bytes
                }
            }
        }

        return .success(info)
    }

    /// 读取指定盘的完整 SMART 详情。devicePath 如 "/dev/disk4"。
    /// 与 read() 同源：`smartctl -j -a` 的 JSON 里本就带着全量属性表与日志，
    /// 这里把它们完整解析出来（read() 只取摘要字段）。
    static func readDetails(bsdName: String) async -> Result<SMARTDetails, SMARTError> {
        let device = "/dev/\(bsdName)"
        guard let smartctl = findSmartctl() else {
            return .failure(.notInstalled)
        }
        let (output, exitStatus) = runProcess(smartctl, args: ["-j", "-a", device])
        if exitStatus == Self.spawnFailureExitStatus {
            return .failure(.unknown(tr("无法启动 smartctl（可能被安全软件拦截或安装损坏）。",
                                       "Cannot launch smartctl (possibly blocked by security software or a broken install).")))
        }
        if exitStatus == Self.timeoutExitStatus {
            return .failure(.unknown(tr("读取超时（\(Int(Self.processTimeout)) 秒）：设备可能已卡死，常见于硬盘盒/线缆接触问题。",
                                       "Timed out after \(Int(Self.processTimeout)) s: the device may be wedged — commonly an enclosure or cable problem.")))
        }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if exitStatus & 0x02 != 0 {
                return .failure(.unknown(tr("无法打开 \(device)（设备不存在或需要更高权限）。",
                                           "Cannot open \(device) (missing, or needs elevated access).")))
            }
            return .failure(.parseFailed)
        }

        let details = SMARTDetails.parse(json: json, bsdName: bsdName)
        // 设备不存在/刚拔出时 smartctl 仍输出合法 JSON，但没有任何有效字段
        // （messages 里是 "Unable to detect device type"）。以"三无"判据识别，
        // 并把 smartctl 的原始报错透传给用户。
        if details.attributes.isEmpty && details.nvmeHealth == nil && details.model == nil {
            let messages = (json["smartctl"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            let text = messages.compactMap { $0["string"] as? String }.joined(separator: "; ")
            return .failure(.unknown(text.isEmpty
                ? tr("无法读取 SMART 详情。", "Unable to read SMART details.")
                : text))
        }
        return .success(details)
    }

    /// 读取 smartctl 纯文本输出（-a），供「复制诊断文本」使用。
    /// 文本形态对人（以及把剪贴板丢给 AI 分析）最友好，与详情 sheet 各走一路。
    static func readPlainText(bsdName: String) async -> Result<String, SMARTError> {
        guard let smartctl = findSmartctl() else {
            return .failure(.notInstalled)
        }
        let (output, exitStatus) = runProcess(smartctl, args: ["-a", "/dev/\(bsdName)"])
        if exitStatus == Self.timeoutExitStatus {
            return .failure(.unknown(tr("读取超时：设备可能已卡死。", "Read timed out: the device may be wedged.")))
        }
        guard !output.isEmpty else {
            return .failure(.unknown(tr("smartctl 无输出（退出码 \(exitStatus)）。", "smartctl produced no output (exit status \(exitStatus)).")))
        }
        return .success(output)
    }

    // MARK: 工具函数

    /// 从 raw.string 前缀解析整数：取字符串开头连续数字。
    /// "2263 (168 229 0)" → 2263；"34 (Min/Max 28/36)" → 34；"0" → 0；"" → nil
    static func parseInt(_ s: String) -> Int? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func findSmartctl() -> String? {
        let candidates = [
            "/opt/homebrew/bin/smartctl",   // Apple Silicon brew
            "/usr/local/bin/smartctl",      // Intel brew
            "/usr/local/sbin/smartctl",     // sbin
            "/usr/sbin/smartctl",           // 系统
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // 最后尝试 PATH
        let (output, _) = runProcess("/usr/bin/which", args: ["smartctl"])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// 子进程超时上限。目标盘常是坏盘/半死的桥接芯片，smartctl 卡在探测阶段
    /// 是常见现象；无超时会永久占住调用线程，且每次重试都新起一个挂死进程，
    /// 堆积后连磁盘枚举（同样跑在协作池上）都会被饿死。
    static let processTimeout: TimeInterval = 15
    /// 超时哨兵退出码（借用 GNU timeout 的约定值）；真实退出码是位掩码，不会取到它
    static let timeoutExitStatus: Int32 = -124
    /// spawn 失败哨兵（无法启动 smartctl 本身，与设备打不开是两回事）
    static let spawnFailureExitStatus: Int32 = -1

    /// 返回 stdout 与退出码。退出码交给调用方解释（smartctl 的退出码是位掩码），
    /// 超时/spawn 失败返回上面的哨兵值。
    private static func runProcess(_ path: String, args: [String]) -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ("", spawnFailureExitStatus)
        }

        // 后台持续收集 stdout，主线程带超时等待退出——绝不对故障设备无限期阻塞。
        // EOF（进程退出关闭写端）也会触发 signal。
        let collector = LockedData()
        let done = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                done.signal()
            } else {
                collector.append(chunk)
            }
        }
        let exitSem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exitSem.signal() }

        var timedOut = false
        if done.wait(timeout: .now() + processTimeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exitSem.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)   // Process 无 kill()，走 POSIX
                _ = exitSem.wait(timeout: .now() + 2)
            }
        } else {
            _ = exitSem.wait(timeout: .now() + 5)
        }
        out.fileHandleForReading.readabilityHandler = nil
        // 收尾读出 handler 尚未消费的尾部（进程已退出，读到 EOF 为止，不会阻塞）
        collector.append(out.fileHandleForReading.readDataToEndOfFile())
        p.waitUntilExit()

        let status: Int32 = timedOut ? timeoutExitStatus : p.terminationStatus
        return (collector.string, status)
    }

    /// 线程安全的数据收集器（readabilityHandler 回调与收尾读取并发）
    private final class LockedData {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

// MARK: - 错误类型

enum SMARTError: Error, Sendable {
    case notInstalled       // 未安装 smartctl
    case unsupported(String) // 设备不支持 SMART
    case parseFailed         // 输出无法解析
    case unknown(String)
}

extension SMARTError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return tr("未检测到 smartctl。请安装 smartmontools：brew install smartmontools",
                      "smartctl not found. Install smartmontools: brew install smartmontools")
        case .unsupported(let msg):
            return tr("该磁盘（或硬盘盒）不支持 SMART：\(msg)",
                      "This disk (or its enclosure) does not support SMART: \(msg)")
        case .parseFailed:
            return tr("无法解析 SMART 数据", "Unable to parse SMART data")
        case .unknown(let msg):
            return msg
        }
    }
}
