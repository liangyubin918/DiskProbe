import Foundation

// MARK: - SMART 历史快照与趋势
//
// 单次 SMART 读数是孤立瞬间，判断老盘存亡靠趋势（重映射 40→45 是退化，
// 40 稳住不动是常态）。这里提供三件事：
//   1. 快照模型（只存趋势相关的风险属性原始值 + 通电小时，一个 JSON 几 KB）
//   2. 按盘（序列号）归档的本地存储（Application Support，上限 200 条）
//   3. 趋势计算（上次记录 → 当前读数，纯函数可测）
//
// 记录时机：扫描完成自动记一次 + 详情面板「记录快照」手动记。
// 只报数字变化（增/减/持平），不做任何结论——延续"零主观"原则。

/// 一次 SMART 读数的趋势快照。ATA 存跟踪属性的原始值前导整数；
/// NVMe 存关键计数字段。
struct SMARTSnapshot: Codable, Sendable, Equatable {
    var date: Date
    var model: String?
    var serial: String?
    var interface: String?
    var powerOnHours: Int64?
    var ataRaw: [Int: Int64]?
    var nvmeMediaErrors: Int64?
    var nvmeNumErrLogEntries: Int64?
    var nvmePercentageUsed: Int?
}

/// 历史文件结构（Application Support/DiskProbe/smart-history/<serial>.json）
struct SMARTHistoryFile: Codable {
    var format: String
    var serial: String
    var snapshots: [SMARTSnapshot]
}

/// 趋势面板的汇总信息
struct SMARTHistoryInfo: Sendable, Equatable {
    var count: Int
    var earliest: Date?
}

/// 一条属性的趋势：上次记录 → 当前读数。
/// `series` 是全部历史点 + 当前点（UI 展示时截尾）。
struct SMARTAttributeTrend: Identifiable, Sendable, Equatable {
    var key: String            // "ata:5" / "nvme:media_errors"
    var previous: Int64?       // nil = 上次没有该属性记录
    var current: Int64
    var delta: Int64?
    var lastRecordDate: Date?
    var series: [Int64]

    var id: String { key }
}

// MARK: - 本地存储

enum SMARTHistoryStore {
    /// 快照上限：正常使用频率下几年也记不满，防失控只做兜底
    static let maxSnapshots = 200

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DiskProbe/smart-history", isDirectory: true)
    }

    /// 序列号里通常只有字母数字；异常字符替换成下划线，保证是合法文件名
    static func fileName(serial: String) -> String {
        String(serial.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    static func historyURL(serial: String, directory: URL? = nil) -> URL {
        (directory ?? defaultDirectory()).appendingPathComponent(fileName(serial: serial) + ".json")
    }

    /// 读取某盘的全部快照（按时间升序）。无历史返回空数组。
    static func load(serial: String, directory: URL? = nil) -> [SMARTSnapshot] {
        let url = historyURL(serial: serial, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(SMARTHistoryFile.self, from: data) else { return [] }
        return file.snapshots
    }

    /// 追加快照。与最新一条完全相同（所有值一致）时跳过，避免连点记录产生
    /// 重复点。超出上限时丢弃最旧的。
    /// 返回是否真的写入了新快照。
    @discardableResult
    static func append(snapshot: SMARTSnapshot, serial: String, directory: URL? = nil) -> Bool {
        let dir = directory ?? defaultDirectory()
        if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) == nil
            && !FileManager.default.fileExists(atPath: dir.path) {
            return false
        }
        var snapshots = load(serial: serial, directory: directory)
        if let last = snapshots.last, last == snapshot { return false }
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
        let file = SMARTHistoryFile(format: "DiskProbe SMART 历史 v1",
                                    serial: serial, snapshots: snapshots)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return false }
        do {
            try data.write(to: historyURL(serial: serial, directory: directory), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 趋势计算（纯函数）

enum SMARTTrendEngine {
    /// 趋势跟踪的 ATA 属性（原始值）。顺序即 UI 展示顺序：
    /// 风险属性在前，9（通电时间）垫底作上下文。
    static let trackedATAIDs = [5, 197, 198, 187, 196, 199, 188, 9]

    /// 从详情读数提取当前值，键为 "ata:<id>" / "nvme:<字段>"。
    /// 原始值取 raw.string 的前导整数（与展示一致，厂商打包字段只取主值）。
    static func currentValues(from details: SMARTDetails) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for row in details.attributes {
            if let v = leadingInt64(row.rawString) {
                out["ata:\(row.id)"] = v
            }
        }
        if let h = details.nvmeHealth {
            if let m = h.mediaErrors { out["nvme:media_errors"] = m }
            if let n = h.numErrLogEntries { out["nvme:num_err_log_entries"] = n }
            if let p = h.percentageUsed { out["nvme:percentage_used"] = Int64(p) }
        }
        return out
    }

    /// 把一次详情读数转成可入库的快照
    static func snapshot(from details: SMARTDetails, date: Date) -> SMARTSnapshot {
        let values = currentValues(from: details)
        var ata: [Int: Int64] = [:]
        for (key, v) in values where key.hasPrefix("ata:") {
            if let id = Int(key.dropFirst(4)) { ata[id] = v }
        }
        var hours = values["ata:9"]
        if hours == nil { hours = details.nvmeHealth?.powerOnHours }
        return SMARTSnapshot(
            date: date,
            model: details.model,
            serial: details.serial,
            interface: details.deviceType,
            powerOnHours: hours,
            ataRaw: ata.isEmpty ? nil : ata,
            nvmeMediaErrors: details.nvmeHealth?.mediaErrors,
            nvmeNumErrLogEntries: details.nvmeHealth?.numErrLogEntries,
            nvmePercentageUsed: details.nvmeHealth?.percentageUsed
        )
    }

    /// 计算各跟踪属性的趋势：历史最后一条 = "上次记录"，详情读数 = "当前"。
    /// 历史为空返回空数组（此时 UI 显示"尚无快照"引导文案）。
    /// `series` 取最近 8 个历史点 + 当前点，避免 UI 行无限长。
    static func trends(history: [SMARTSnapshot], current: SMARTDetails) -> [SMARTAttributeTrend] {
        guard !history.isEmpty else { return [] }
        let values = currentValues(from: current)
        var out: [SMARTAttributeTrend] = []

        for id in trackedATAIDs {
            let key = "ata:\(id)"
            guard let cur = values[key] else { continue }
            var series = history.compactMap { $0.ataRaw?[id] }
            series.append(cur)
            let previous = history.last?.ataRaw?[id]
            out.append(SMARTAttributeTrend(
                key: key,
                previous: previous,
                current: cur,
                delta: previous.map { cur - $0 },
                lastRecordDate: history.last?.date,
                series: Array(series.suffix(8))
            ))
        }

        if let health = current.nvmeHealth {
            let nvmeEntries: [(key: String, value: Int64?)] = [
                ("nvme:media_errors", health.mediaErrors),
                ("nvme:num_err_log_entries", health.numErrLogEntries),
                ("nvme:percentage_used", health.percentageUsed.map { Int64($0) }),
            ]
            for entry in nvmeEntries {
                guard let cur = entry.value else { continue }
                var series = historySeries(history: history, key: entry.key)
                series.append(cur)
                let previous = history.last?.nvmeValue(forKey: entry.key)
                out.append(SMARTAttributeTrend(
                    key: entry.key,
                    previous: previous,
                    current: cur,
                    delta: previous.map { cur - $0 },
                    lastRecordDate: history.last?.date,
                    series: Array(series.suffix(8))
                ))
            }
        }
        return out
    }

    private static func historySeries(history: [SMARTSnapshot], key: String) -> [Int64] {
        history.compactMap { $0.nvmeValue(forKey: key) }
    }

    /// 原始值字符串的前导整数（"45" → 45；"24 (0 1 0 0 0)" → 24）
    static func leadingInt64(_ s: String) -> Int64? {
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int64(digits)
    }
}

extension SMARTSnapshot {
    /// 统一取值入口：键为 "nvme:media_errors" 等
    func nvmeValue(forKey key: String) -> Int64? {
        switch key {
        case "nvme:media_errors": return nvmeMediaErrors
        case "nvme:num_err_log_entries": return nvmeNumErrLogEntries
        case "nvme:percentage_used": return nvmePercentageUsed.map(Int64.init)
        default: return nil
        }
    }
}
