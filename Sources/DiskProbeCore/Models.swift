import Foundation

// MARK: - 块状态（扫描地图里每个格子的颜色由它决定）

/// 单个扫描块的分类。颜色映射：
///   正常 → 绿色 / 警告 → 黄色 / 异常 → 红色 / 错误 → 深红 / 未扫描 → 灰色
public enum BlockStatus: String, Codable, Sendable, CaseIterable {
    case normal   = "正常"   // < warnMs
    case warning  = "警告"   // warnMs ..< errorMs
    case abnormal = "异常"   // >= errorMs（但读成功）
    case error    = "错误"   // 读取失败（errno）
    case unscanned = "未扫描"

    /// 给 UI 用的简短英文 key，便于做本地化或直接配色
    public var key: String {
        switch self {
        case .normal:    return "normal"
        case .warning:   return "warning"
        case .abnormal:  return "abnormal"
        case .error:     return "error"
        case .unscanned: return "unscanned"
        }
    }

    /// 严重程度排序：地图格子里多个块共用一格时，取最严重的状态
    public var severityOrder: Int {
        switch self {
        case .unscanned: return 0
        case .normal:    return 1
        case .warning:   return 2
        case .abnormal:  return 3
        case .error:     return 4
        }
    }
}

// MARK: - 扫描阈值（可调整参数）

/// 根据单块读取耗时把块归类。默认值参考 DiskGenius，UI 里可改。
public struct ScanThresholds: Codable, Sendable {
    public var warnMs: Double    // 默认 100
    public var abnormalMs: Double // 默认 500

    public init(warnMs: Double = 100, abnormalMs: Double = 500) {
        self.warnMs = warnMs
        self.abnormalMs = abnormalMs
    }

    /// 把"读取耗时 + 是否失败"映射成块状态
    public func classify(elapsedMs: Double, failed: Bool) -> BlockStatus {
        if failed { return .error }
        if elapsedMs >= abnormalMs { return .abnormal }
        if elapsedMs >= warnMs    { return .warning }
        return .normal
    }
}

// MARK: - 扫描块结果

/// 一个扫描块的完整记录。actor 内部生成，UI 读取展示。
public struct ScanBlock: Identifiable, Sendable {
    public let id: Int          // 块序号，0 ..< totalBlocks
    public let startOffset: Int64 // 磁盘上的字节偏移
    public let size: Int64        // 本块字节数（最后一块可能不足）
    public let elapsedMs: Double  // 读取耗时（失败时为尝试耗时）
    public let status: BlockStatus
    /// 读取失败时的 errno（成功为 nil）。常见：EIO=坏道
    public let errnoValue: Int32?

    public init(id: Int, startOffset: Int64, size: Int64,
                elapsedMs: Double, status: BlockStatus, errnoValue: Int32? = nil) {
        self.id = id; self.startOffset = startOffset; self.size = size
        self.elapsedMs = elapsedMs; self.status = status; self.errnoValue = errnoValue
    }
}

// MARK: - 扫描地图格子

/// 地图单个格子的聚合信息：颜色取格内最严重块的状态，
/// 悬停提示展示格子编号与定格该状态的采样耗时。
public struct MapCell: Sendable, Equatable, Codable {
    public var status: BlockStatus
    public var elapsedMs: Double
    public var blockIndex: Int    // -1 = 未扫描

    public static let unscanned = MapCell(status: .unscanned, elapsedMs: 0, blockIndex: -1)

    public init(status: BlockStatus, elapsedMs: Double, blockIndex: Int) {
        self.status = status
        self.elapsedMs = elapsedMs
        self.blockIndex = blockIndex
    }
}

// MARK: - 扫描记录导出

/// 一次扫描的元信息（导出报告的头部）
public struct ScanMeta: Codable, Sendable {
    public var diskName: String
    public var bsdName: String
    public var diskSizeBytes: Int64
    public var blockSizeBytes: Int64
    public var totalBlocks: Int
    public var warnMs: Double
    public var abnormalMs: Double
    public var startedAt: Date
    public var finishedAt: Date?

    public init(diskName: String, bsdName: String, diskSizeBytes: Int64, blockSizeBytes: Int64,
                totalBlocks: Int, warnMs: Double, abnormalMs: Double, startedAt: Date, finishedAt: Date?) {
        self.diskName = diskName; self.bsdName = bsdName; self.diskSizeBytes = diskSizeBytes
        self.blockSizeBytes = blockSizeBytes; self.totalBlocks = totalBlocks
        self.warnMs = warnMs; self.abnormalMs = abnormalMs
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

/// 非"正常"块的明细记录（警告/异常/错误）。正常块不逐条落盘，
/// 否则 1TB 盘会产生数百万行无用数据；完整地图快照在 JSON 报告里。
public struct ScanRecord: Codable, Sendable {
    public var blockIndex: Int
    public var offsetBytes: Int64
    public var elapsedMs: Double
    public var status: BlockStatus
    public var errno: Int32?     // nil = 读取成功但偏慢

    public init(blockIndex: Int, offsetBytes: Int64, elapsedMs: Double, status: BlockStatus, errno: Int32?) {
        self.blockIndex = blockIndex; self.offsetBytes = offsetBytes
        self.elapsedMs = elapsedMs; self.status = status; self.errno = errno
    }
}

// MARK: - 扫描汇总

public struct ScanSummary: Codable, Sendable {
    public var normal = 0
    public var warning = 0
    public var abnormal = 0
    public var error = 0
    public var unscanned = 0

    public init(normal: Int = 0, warning: Int = 0, abnormal: Int = 0, error: Int = 0, unscanned: Int = 0) {
        self.normal = normal
        self.warning = warning
        self.abnormal = abnormal
        self.error = error
        self.unscanned = unscanned
    }

    public var total: Int { normal + warning + abnormal + error + unscanned }
    public var hasIssues: Bool { warning + abnormal + error > 0 }
}
