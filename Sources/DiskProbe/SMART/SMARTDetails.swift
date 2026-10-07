import Foundation

// MARK: - SMART 详细信息模型（详情 sheet 的数据源）
//
// 与 SMARTInfo（摘要条）互补：摘要条只挑关键指标，这里保留 smartctl
// JSON 里的完整属性表、ATA 错误日志与自检日志。数据源同为
// `smartctl -j -a`（不换 -x：实测 USB 桥接普遍不支持 48 位 ATA 命令，
// GP 日志读不到，-x 只会多一轮无谓的失败探测）。

/// 一条 ATA SMART 属性的完整记录
struct SMARTAttributeRow: Identifiable, Sendable, Equatable {
    let id: Int                 // 属性 ID（1..255）
    let name: String            // smartctl 标准名（如 Reallocated_Sector_Ct）
    let value: Int?             // 归一化当前值
    let worst: Int?             // 历史最差
    let threshold: Int?         // 失败阈值（0 表示无阈值）
    let rawString: String       // 原始值字符串（可能带 "40 (0 1 0 0 0)" 这类后缀）
    let isPrefail: Bool         // prefail 属性：跌破阈值预示盘即将失效
    let whenFailed: String      // "" = 正常；"FAILING_NOW" / "In_the_past"

    init(id: Int, name: String, value: Int?, worst: Int?, threshold: Int?,
         rawString: String, isPrefail: Bool, whenFailed: String) {
        self.id = id; self.name = name; self.value = value; self.worst = worst
        self.threshold = threshold; self.rawString = rawString
        self.isPrefail = isPrefail; self.whenFailed = whenFailed
    }

    /// 正在/已经处于失败区（smartctl 明确标记）
    var isFailed: Bool { !whenFailed.isEmpty }

    /// 当前值已跌到阈值及以下（多数盘 when_failed 仍为空，靠数值判断兜底）
    var isCritical: Bool {
        guard let v = value, let t = threshold, t > 0 else { return false }
        return v <= t
    }
}

/// 一条 ATA 错误日志记录（盘只保留最近 5 条）
struct SMARTErrorLogEntry: Identifiable, Sendable, Equatable {
    let errorNumber: Int        // 第几次错误（累计编号）
    let lifetimeHours: Int      // 发生时的通电小时数
    let description: String     // 如 "Error: UNC at LBA = 0x0fffffff = 268435455"

    init(errorNumber: Int, lifetimeHours: Int, description: String) {
        self.errorNumber = errorNumber; self.lifetimeHours = lifetimeHours
        self.description = description
    }

    var id: Int { errorNumber }
}

/// 一条 ATA 自检日志记录
struct SMARTSelfTestEntry: Identifiable, Sendable, Equatable {
    let index: Int              // 日志槽位（1 = 最近一次）
    let typeDescription: String // "Short offline" / "Offline" 等
    let statusDescription: String // "Completed without error" 等
    let passed: Bool
    let lifetimeHours: Int?
    let lbaFirstError: Int64?   // 失败时首个出错 LBA

    init(index: Int, typeDescription: String, statusDescription: String,
         passed: Bool, lifetimeHours: Int?, lbaFirstError: Int64? = nil) {
        self.index = index; self.typeDescription = typeDescription
        self.statusDescription = statusDescription; self.passed = passed
        self.lifetimeHours = lifetimeHours; self.lbaFirstError = lbaFirstError
    }

    var id: Int { index }
}

/// NVMe 健康信息全量字段（smartctl 的 nvme_smart_health_information_log）
struct SMARTNVMeHealth: Sendable, Equatable {
    var criticalWarning: Int = 0
    var temperatureC: Double? = nil
    var availableSpare: Int? = nil
    var availableSpareThreshold: Int? = nil
    var percentageUsed: Int? = nil
    var dataUnitsRead: Int64? = nil     // 单位 1000 × 512B
    var dataUnitsWritten: Int64? = nil
    var hostReads: Int64? = nil         // 读命令次数
    var hostWrites: Int64? = nil
    var powerCycles: Int64? = nil
    var powerOnHours: Int64? = nil
    var unsafeShutdowns: Int64? = nil
    var mediaErrors: Int64? = nil
    var numErrLogEntries: Int64? = nil
}

/// 详细 SMART 信息
struct SMARTDetails: Sendable, Equatable {
    var bsdName: String
    var deviceType: String?         // "ata" / "nvme"
    var model: String?
    var serial: String?
    var firmware: String?
    var capacityBytes: Int64?
    var rotationRate: Int?          // ATA 有；NVMe 为 nil
    var formFactorName: String?     // 如 "2.5 inches"
    var health: String?             // "PASSED" / "FAILED"

    // ATA
    var attributes: [SMARTAttributeRow] = []
    var errorLog: [SMARTErrorLogEntry] = []
    var errorLogTotalCount: Int? = nil  // 累计错误数（日志里只留最近 5 条）
    var selfTestLog: [SMARTSelfTestEntry] = []

    // NVMe
    var nvmeHealth: SMARTNVMeHealth? = nil

    var isNVMe: Bool { deviceType?.lowercased() == "nvme" }

    init(bsdName: String, deviceType: String? = nil, model: String? = nil,
         serial: String? = nil, firmware: String? = nil, capacityBytes: Int64? = nil,
         rotationRate: Int? = nil, formFactorName: String? = nil, health: String? = nil) {
        self.bsdName = bsdName; self.deviceType = deviceType; self.model = model
        self.serial = serial; self.firmware = firmware; self.capacityBytes = capacityBytes
        self.rotationRate = rotationRate; self.formFactorName = formFactorName
        self.health = health
    }

    // MARK: 解析

    /// 从 `smartctl -j -a` 的 JSON 解析完整详情。纯函数，便于单元测试。
    /// JSON 缺属性表/日志（桥接不支持、设备非 ATA/NVMe）时对应字段保持空，
    /// 由调用方决定报错还是显示空态。
    static func parse(json: [String: Any], bsdName: String) -> SMARTDetails {
        var d = SMARTDetails(bsdName: bsdName)
        if let dev = json["device"] as? [String: Any] {
            d.deviceType = dev["type"] as? String
        }
        d.model = json["model_name"] as? String
        d.serial = json["serial_number"] as? String
        d.firmware = json["firmware_version"] as? String
        if let cap = json["user_capacity"] as? [String: Any] {
            d.capacityBytes = cap["bytes"] as? Int64
        }
        d.rotationRate = json["rotation_rate"] as? Int
        if let ff = json["form_factor"] as? [String: Any] {
            d.formFactorName = ff["name"] as? String
        }
        // 健康状态（ATA: smart_status.passed；NVMe: critical_warning == 0）
        if let st = json["smart_status"] as? [String: Any] {
            d.health = st["passed"] as? Bool == true ? "PASSED" : "FAILED"
        }

        // ATA 属性表（全量）
        if let table = attrTable(from: json) {
            d.attributes = table.compactMap { entry in
                guard let id = entry["id"] as? Int,
                      let name = entry["name"] as? String else { return nil }
                let raw = entry["raw"] as? [String: Any]
                let flags = entry["flags"] as? [String: Any]
                return SMARTAttributeRow(
                    id: id,
                    name: name,
                    value: entry["value"] as? Int,
                    worst: entry["worst"] as? Int,
                    threshold: entry["thresh"] as? Int,
                    rawString: raw?["string"] as? String ?? "",
                    isPrefail: flags?["prefailure"] as? Bool ?? false,
                    whenFailed: entry["when_failed"] as? String ?? ""
                )
            }
        }

        // ATA 错误日志（summary：仅最近 5 条）
        if let summary = (((json["ata_smart_error_log"] as? [String: Any])?["summary"]) as? [String: Any]) {
            d.errorLogTotalCount = summary["device_error_count"] as? Int
            if let table = summary["table"] as? [[String: Any]] {
                d.errorLog = table.compactMap { entry in
                    guard let num = entry["error_number"] as? Int else { return nil }
                    return SMARTErrorLogEntry(
                        errorNumber: num,
                        lifetimeHours: entry["lifetime_hours"] as? Int ?? 0,
                        description: entry["error_description"] as? String ?? ""
                    )
                }
            }
        }

        // ATA 自检日志（槽位可能为空，过滤空条目）
        if let st = json["ata_smart_self_testlog"] as? [String: Any],
           let table = st["table"] as? [[String: Any]] {
            d.selfTestLog = table.compactMap { entry in
                guard let index = entry["index"] as? Int else { return nil }
                let type = (entry["type"] as? [String: Any])?["string"] as? String ?? ""
                guard !type.isEmpty else { return nil } // 空槽位
                let status = entry["status"] as? [String: Any]
                let lba = (entry["lba_first_error"] as? [String: Any])?["value"] as? Int64
                return SMARTSelfTestEntry(
                    index: index,
                    typeDescription: type,
                    statusDescription: status?["string"] as? String ?? "",
                    passed: status?["passed"] as? Bool ?? true,
                    lifetimeHours: entry["lifetime_hours"] as? Int,
                    lbaFirstError: lba
                )
            }
        }

        // NVMe 健康日志（全量字段）
        if let nvme = json["nvme_smart_health_information_log"] as? [String: Any] {
            var h = SMARTNVMeHealth()
            h.criticalWarning = nvme["critical_warning"] as? Int ?? 0
            h.temperatureC = (nvme["temperature"] as? Int).map(Double.init)
            h.availableSpare = nvme["available_spare"] as? Int
            h.availableSpareThreshold = nvme["available_spare_threshold"] as? Int
            h.percentageUsed = nvme["percentage_used"] as? Int
            h.dataUnitsRead = nvme["data_units_read"] as? Int64
            h.dataUnitsWritten = nvme["data_units_written"] as? Int64
            h.hostReads = nvme["host_reads"] as? Int64
            h.hostWrites = nvme["host_writes"] as? Int64
            h.powerCycles = nvme["power_cycles"] as? Int64
            h.powerOnHours = nvme["power_on_hours"] as? Int64
            h.unsafeShutdowns = nvme["unsafe_shutdowns"] as? Int64
            h.mediaErrors = nvme["media_errors"] as? Int64
            h.numErrLogEntries = nvme["num_err_log_entries"] as? Int64
            // summary 条里没读到 smart_status 时按 critical_warning 兜底；
            // 字段缺失（个别精简固件）不武断判 FAILED，留 nil = 未知
            if d.health == nil, let cw = nvme["critical_warning"] as? Int {
                d.health = cw == 0 ? "PASSED" : "FAILED"
            }
            d.nvmeHealth = h
        }
        return d
    }

    /// 取 ATA 属性表；value/worst/thresh 均为 0–255 的归一化值，
    /// 不会溢出，`as? Int` 是安全的（raw.value 可能超 Int，但这里只取 raw.string）。
    private static func attrTable(from json: [String: Any]) -> [[String: Any]]? {
        guard let attrs = json["ata_smart_attributes"] as? [String: Any],
              let table = attrs["table"] as? [[String: Any]] else { return nil }
        return table
    }
}
