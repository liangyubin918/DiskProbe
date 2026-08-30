import Foundation

// MARK: - 检测记录导出（CSV / JSON）

/// 把一次扫描的快照导出为常用分析格式：
///   - CSV：文件头注释（磁盘/阈值/汇总）+ 格子明细（全盘分区覆盖）+ 非正常块明细行，
///     UTF-8 带 BOM（Excel 直开）
///   - JSON：完整报告（元数据 + 汇总 + 地图快照 + 异常块明细）
public enum ScanRecordExporter {

    public static func csv(meta: ScanMeta?, summary: ScanSummary?, cells: [MapCell],
                           anomalies: [ScanRecord]) -> String {
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
        lines.append("说明,\(escape("块级明细仅含非正常块（警告/异常/错误）；格子明细覆盖全盘，状态取格内最严重块，耗时为该状态的采样值"))")
        lines.append("")

        // 格子明细：正常块不逐条落盘（百万行级），但格子汇总始终有全盘数据可分析
        if let m = meta, m.totalBlocks > 0, !cells.isEmpty {
            lines.append("格子明细")
            lines.append("格子序号,起始块,结束块,起始偏移(字节),状态,采样耗时(ms),采样块序号")
            // 与 ScanEngine.cellsPerBlockGroup 同一公式：导出端无法访问引擎内部，按同一定义重算
            let per = (m.totalBlocks + cells.count - 1) / cells.count
            for (i, c) in cells.enumerated() {
                let firstBlock = i * per
                let lastBlock = min(m.totalBlocks, (i + 1) * per) - 1
                let offset = Int64(firstBlock) * m.blockSizeBytes
                let scanned = c.blockIndex >= 0
                lines.append("\(i),\(firstBlock),\(lastBlock),\(offset),\(c.status.rawValue),"
                             + (scanned ? csvNumber(c.elapsedMs) : "") + ","
                             + (scanned ? String(c.blockIndex) : ""))
            }
            lines.append("")
        }

        lines.append("异常块明细")
        lines.append("块序号,偏移(字节),耗时(ms),状态,errno")
        if anomalies.isEmpty {
            // 全部块正常时明细为空：写明原因，避免被当成导出错漏
            lines.append("（本次无非正常块）")
        } else {
            for r in anomalies {
                let errno = r.errno.map(String.init) ?? ""
                lines.append("\(r.blockIndex),\(r.offsetBytes),\(csvNumber(r.elapsedMs)),\(r.status.rawValue),\(errno)")
            }
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
