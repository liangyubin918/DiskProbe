import Foundation

// MARK: - 检测记录导出（CSV / JSON）

/// 把一次扫描的快照导出为常用分析格式：
///   - CSV：文件头注释（磁盘/阈值/汇总）+ 非正常块明细行，UTF-8 带 BOM（Excel 直开）
///   - JSON：完整报告（元数据 + 汇总 + 6000 格地图快照 + 异常块明细）
public enum ScanRecordExporter {

    public static func csv(meta: ScanMeta?, summary: ScanSummary?, anomalies: [ScanRecord]) -> String {
        var lines: [String] = []
        let fmt = Self.dateFormatter

        lines.append("DiskProbe 扫描记录")
        if let m = meta {
            lines.append("磁盘,\(escape("\(m.diskName) (/dev/\(m.bsdName))"))")
            lines.append("容量,\(m.diskSizeBytes) 字节")
            lines.append("块大小,\(m.blockSizeBytes) 字节")
            lines.append("块总数,\(m.totalBlocks)")
            lines.append("阈值,\(escape("警告 \(Int(m.warnMs)) ms / 异常 \(Int(m.abnormalMs)) ms"))")
            lines.append("开始,\(fmt.string(from: m.startedAt))")
            if let f = m.finishedAt { lines.append("结束,\(fmt.string(from: f))") }
        }
        if let s = summary {
            lines.append("汇总,\(escape("正常 \(s.normal) / 警告 \(s.warning) / 异常 \(s.abnormal) / 错误 \(s.error)"))")
        }
        lines.append("")
        lines.append("块序号,偏移(字节),耗时(ms),状态,errno")
        for r in anomalies {
            let errno = r.errno.map(String.init) ?? ""
            lines.append("\(r.blockIndex),\(r.offsetBytes),\(csvNumber(r.elapsedMs)),\(r.status.rawValue),\(errno)")
        }
        // BOM：让 Excel/Numbers 按 UTF-8 识别中文
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    public static func json(meta: ScanMeta?, summary: ScanSummary?, cells: [MapCell],
                            anomalies: [ScanRecord]) throws -> Data {
        struct File: Codable {
            var format: String
            var meta: ScanMeta?
            var summary: ScanSummary?
            var mapCells: [MapCell]
            var anomalies: [ScanRecord]
        }
        let file = File(format: "DiskProbe 扫描记录 v1", meta: meta, summary: summary,
                        mapCells: cells, anomalies: anomalies)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    // MARK: helpers

    /// 小数统一一位，避免区域设置输出逗号小数点破坏 CSV
    private static func csvNumber(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    private static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}
