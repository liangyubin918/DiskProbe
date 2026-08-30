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
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 退出码 bit1(2) = 设备打开失败（权限/设备消失），此时不会有有效 JSON
            if exitStatus & 0x02 != 0 {
                return .failure(.unknown("无法打开 \(device)（设备不存在或需要更高权限）。"))
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

    /// 返回 stdout 与退出码。退出码交给调用方解释（smartctl 的退出码是位掩码）。
    private static func runProcess(_ path: String, args: [String]) -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // 必须在等待子进程退出前持续读取 stdout，避免输出填满 pipe
            // 缓冲区后父子进程相互等待。
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
        } catch {
            return ("", -1)
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
            return "未检测到 smartctl。请安装 smartmontools：brew install smartmontools"
        case .unsupported(let msg):
            return "该磁盘（或硬盘盒）不支持 SMART：\(msg)"
        case .parseFailed:
            return "无法解析 SMART 数据"
        case .unknown(let msg):
            return msg
        }
    }
}
