import Foundation

// MARK: - 检测记录 JSON 结构（与 ScanRecordExporter.json 的输出一一对应）

public struct ScanRecordFile: Codable, Sendable {
    public var format: String
    public var meta: ScanMeta?
    public var summary: ScanSummary?
    public var mapCells: [MapCell]
    public var anomalies: [ScanRecord]
}

extension ScanRecordExporter {
    /// 解析本 app 导出的 JSON 完整报告。日期为 iso8601（与导出端一致）。
    public static func parseJSON(_ data: Data) throws -> ScanRecordFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScanRecordFile.self, from: data)
    }
}

// MARK: - 两次扫描的异常对比

/// 按字节偏移对齐两次扫描的异常块（块大小不同的两次扫描也能对比）。
/// 语义：
///   新增   —— 上次正常，这次出问题（盘正在恶化的铁证）
///   加重   —— 两次都有问题，这次更严重
///   持续   —— 两次问题严重度相同
///   恢复   —— 上次有问题，这次正常（多为系统抖动造成的假阳性消退）
public struct RecordDiff: Sendable {
    public enum Kind: Int, Sendable {
        case new = 0
        case worsened = 1
        case persistent = 2
        case resolved = 3

        public var key: String {
            switch self {
            case .new: return "new"
            case .worsened: return "worsened"
            case .persistent: return "persistent"
            case .resolved: return "resolved"
            }
        }
    }

    public struct Item: Identifiable, Sendable {
        public var id: Int64 { offsetBytes }
        public var offsetBytes: Int64
        public var oldStatus: BlockStatus?   // nil = 上次正常
        public var newStatus: BlockStatus?   // nil = 本次正常
        public var oldBlockIndex: Int?       // 该次扫描里的块序号（块大小不同则两次不同）
        public var newBlockIndex: Int?
        public var kind: Kind
    }

    public var items: [Item]
    public var newCount: Int { count(.new) }
    public var worsenedCount: Int { count(.worsened) }
    public var persistentCount: Int { count(.persistent) }
    public var resolvedCount: Int { count(.resolved) }

    private func count(_ kind: Kind) -> Int {
        items.lazy.filter { $0.kind == kind }.count
    }

    public static func compute(old: [ScanRecord], new: [ScanRecord]) -> RecordDiff {
        var oldByOffset: [Int64: ScanRecord] = [:]
        for r in old { oldByOffset[r.offsetBytes] = r }
        var newByOffset: [Int64: ScanRecord] = [:]
        for r in new { newByOffset[r.offsetBytes] = r }

        var items: [Item] = []
        for (offset, newRec) in newByOffset {
            let oldRec = oldByOffset[offset]
            let kind: Kind
            if let o = oldRec {
                kind = newRec.status.severityOrder > o.status.severityOrder ? .worsened : .persistent
            } else {
                kind = .new
            }
            items.append(Item(offsetBytes: offset,
                              oldStatus: oldRec?.status,
                              newStatus: newRec.status,
                              oldBlockIndex: oldRec?.blockIndex,
                              newBlockIndex: newRec.blockIndex,
                              kind: kind))
        }
        for (offset, oldRec) in oldByOffset where newByOffset[offset] == nil {
            items.append(Item(offsetBytes: offset,
                              oldStatus: oldRec.status,
                              newStatus: nil,
                              oldBlockIndex: oldRec.blockIndex,
                              newBlockIndex: nil,
                              kind: .resolved))
        }
        // 新增 > 加重 > 持续 > 恢复，同级按偏移排序
        items.sort { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.offsetBytes < b.offsetBytes
        }
        return RecordDiff(items: items)
    }
}
