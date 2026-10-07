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

        lines.append(tr("DiskProbe 扫描记录", "DiskProbe Scan Report"))
        if let m = meta {
            let thresholdText = tr("警告 \(Int(m.warnMs)) ms / 异常 \(Int(m.abnormalMs)) ms",
                                   "warning \(Int(m.warnMs)) ms / abnormal \(Int(m.abnormalMs)) ms")
            lines.append(tr("磁盘", "Disk") + ",\(escape("\(m.diskName) (/dev/\(m.bsdName))"))")
            lines.append(tr("容量", "Capacity") + ",\(m.diskSizeBytes) " + tr("字节", "bytes"))
            lines.append(tr("块大小", "Block size") + ",\(m.blockSizeBytes) " + tr("字节", "bytes"))
            lines.append(tr("块总数", "Total blocks") + ",\(m.totalBlocks)")
            lines.append(tr("阈值", "Thresholds") + "," + escape(thresholdText))
            lines.append(tr("开始", "Started") + ",\(fmt.string(from: m.startedAt))")
            if let f = m.finishedAt { lines.append(tr("结束", "Finished") + ",\(fmt.string(from: f))") }
        }
        if let s = summary {
            let summaryText = tr("正常 \(s.normal) / 警告 \(s.warning) / 异常 \(s.abnormal) / 错误 \(s.error)",
                                 "normal \(s.normal) / warning \(s.warning) / abnormal \(s.abnormal) / error \(s.error)")
            lines.append(tr("汇总", "Summary") + "," + escape(summaryText))
        }
        let noteText = tr("块级明细仅含非正常块（警告/异常/错误）；格子明细覆盖全盘，状态取格内最严重块，耗时为该状态的采样值",
                          "Block detail lists only non-normal blocks (warning/abnormal/error); cell detail covers the whole disk with the most severe status per cell and its sampled elapsed time")
        lines.append(tr("说明", "Note") + "," + escape(noteText))
        lines.append("")

        // 格子明细：正常块不逐条落盘（百万行级），但格子汇总始终有全盘数据可分析
        if let m = meta, m.totalBlocks > 0, !cells.isEmpty {
            lines.append(tr("格子明细", "Cell detail"))
            lines.append(tr("格子序号,起始块,结束块,起始偏移(字节),状态,采样耗时(ms),采样块序号", "cell,start block,end block,start offset (bytes),status,sampled elapsed (ms),sampled block index"))
            // 与 ScanEngine.cellsPerBlockGroup 同一公式：导出端无法访问引擎内部，按同一定义重算
            let per = (m.totalBlocks + cells.count - 1) / cells.count
            for (i, c) in cells.enumerated() {
                let firstBlock = i * per
                // 小盘（totalBlocks < 格子数）尾部是空格子：firstBlock 已越过盘尾，
                // 导出"起始块 > 结束块"的反区间行只会污染数据，直接跳过
                if firstBlock >= m.totalBlocks { break }
                let lastBlock = min(m.totalBlocks, (i + 1) * per) - 1
                let offset = Int64(firstBlock) * m.blockSizeBytes
                let scanned = c.blockIndex >= 0
                lines.append("\(i),\(firstBlock),\(lastBlock),\(offset),\(c.status.displayName),"
                             + (scanned ? csvNumber(c.elapsedMs) : "") + ","
                             + (scanned ? String(c.blockIndex) : ""))
            }
            lines.append("")
        }

        lines.append(tr("异常块明细", "Non-normal block detail"))
        lines.append(tr("块序号,偏移(字节),耗时(ms),状态,errno", "block index,offset (bytes),elapsed (ms),status,errno"))
        if anomalies.isEmpty {
            // 全部块正常时明细为空：写明原因，避免被当成导出错漏
            lines.append(tr("（本次无非正常块）", "(no non-normal blocks in this scan)"))
        } else {
            for r in anomalies {
                let errno = r.errno.map(String.init) ?? ""
                lines.append("\(r.blockIndex),\(r.offsetBytes),\(csvNumber(r.elapsedMs)),\(r.status.displayName),\(errno)")
            }
        }
        // BOM：让 Excel/Numbers 按 UTF-8 识别非 ASCII 文本
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

    /// 小数统一一位。必须显式钉死 POSIX 区域：`String(format:)` 裸用会按
    /// 用户区域渲染，逗号小数区域（德/法/俄等）输出 `12,5`，把 CSV 拆列错位。
    static func csvNumber(_ v: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    /// CSV 字段转义 + 公式注入防护。
    /// 引号规则：含逗号/引号/换行（含 \r）时整段加引号。
    /// 注入规则：Excel/LibreOffice 会把以 = + - @ 开头的单元格按公式求值
    /// （卷名可被任何人改写），统一加 `'` 前缀无害化——这是数据行里唯一的
    /// 自由文本入口。
    static func escape(_ s: String) -> String {
        var value = s
        if let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}
