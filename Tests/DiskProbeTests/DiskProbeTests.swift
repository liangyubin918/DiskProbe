import Foundation
import Testing
@testable import DiskProbeCore
@testable import DiskProbe
@testable import DiskProbeHelper

// MARK: ScanThresholds.classify 边界

@Suite struct ThresholdClassificationTests {
    let t = ScanThresholds(warnMs: 100, abnormalMs: 500)

    @Test func belowWarnIsNormal() {
        #expect(t.classify(elapsedMs: 99.9, failed: false) == .normal)
    }

    @Test func exactlyWarnIsWarning() {
        #expect(t.classify(elapsedMs: 100, failed: false) == .warning)
    }

    @Test func exactlyAbnormalIsAbnormal() {
        #expect(t.classify(elapsedMs: 500, failed: false) == .abnormal)
    }

    @Test func failureBeatsElapsed() {
        #expect(t.classify(elapsedMs: 1, failed: true) == .error)
    }
}

// MARK: 地图分组（大容量盘地图冻结的回归测试）

@Suite struct MapGroupingTests {
    @Test func smallDisksUseOneBlockPerCell() {
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 1, cellCount: 6000) == 1)
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 5999, cellCount: 6000) == 1)
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 6000, cellCount: 6000) == 1)
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 6001, cellCount: 6000) == 2)
    }

    @Test func hugeDiskStillCoversAllCells() {
        // 4.7TB @ 128KB ≈ 36,000,000 块：旧版（向下取整）在超过这里之后
        // group > 6000，guard 永远失败，地图与统计完全冻结
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 36_000_000, cellCount: 6000) == 6000)
        // 6TB @ 128KB ≈ 48.8M 块（旧版触发 bug 的典型场景）
        let group = ScanEngine.cellsPerBlockGroup(totalBlocks: 48_800_000, cellCount: 6000)
        #expect(group == 8134)
        // 最后一块必须映射到最后一格
        #expect(min(5999, (48_800_000 - 1) / group) == 5999)
    }

    @Test func invalidInputsFallBackToOne() {
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 0, cellCount: 6000) == 1)
        #expect(ScanEngine.cellsPerBlockGroup(totalBlocks: 100, cellCount: 0) == 1)
    }
}

// MARK: BlockStatus

@Suite struct BlockStatusTests {
    @Test func severityOrdering() {
        #expect(BlockStatus.unscanned.severityOrder < BlockStatus.normal.severityOrder)
        #expect(BlockStatus.normal.severityOrder < BlockStatus.warning.severityOrder)
        #expect(BlockStatus.warning.severityOrder < BlockStatus.abnormal.severityOrder)
        #expect(BlockStatus.abnormal.severityOrder < BlockStatus.error.severityOrder)
    }

    @Test func mapKeepsMostSevereStatus() {
        var map = Array(repeating: BlockStatus.unscanned, count: 4)
        // 同一格子依次写入 normal → error → warning，应保留最严重的 error
        for status in [BlockStatus.normal, .error, .warning] {
            if status.severityOrder > map[2].severityOrder {
                map[2] = status
            }
        }
        #expect(map[2] == .error)
    }
}

// MARK: smartctl raw.string 前缀解析

@Suite struct RawStringParsingTests {
    @Test func parsesLeadingInteger() {
        #expect(SMARTReader.parseInt("2263 (168 229 0)") == 2263)
        #expect(SMARTReader.parseInt("34 (Min/Max 28/36)") == 34)
        #expect(SMARTReader.parseInt("0") == 0)
    }

    @Test func rejectsNonNumericPrefix() {
        #expect(SMARTReader.parseInt(" 42") == nil)   // 前导空格不算数字前缀
        #expect(SMARTReader.parseInt("") == nil)
        #expect(SMARTReader.parseInt("abc") == nil)
    }
}

// MARK: ScanProgress.fraction

@Suite struct ProgressFractionTests {
    private func makeProgress(totalBlocks: Int, scanned: Int) -> ScanProgress {
        ScanProgress(
            currentIndex: 0, totalBlocks: totalBlocks, scannedCount: scanned,
            elapsedSeconds: 0, speedMBps: 0, etaSeconds: 0,
            lastBlock: ScanBlock(id: 0, startOffset: 0, size: 0, elapsedMs: 0, status: .normal),
            summary: ScanSummary(), mapCells: []
        )
    }

    @Test func fractionIsScannedOverTotal() {
        #expect(abs(makeProgress(totalBlocks: 100, scanned: 25).fraction - 0.25) < 0.0001)
    }

    @Test func zeroTotalDoesNotDivideByZero() {
        #expect(makeProgress(totalBlocks: 0, scanned: 0).fraction == 0)
    }
}

// MARK: BatchCodec（XPC 批次二进制编解码）

@Suite struct BatchCodecTests {
    @Test func roundTripPreservesAllFields() {
        let offsets: [Int64] = [0, 131_072, 1_048_576]
        let elapsedMs: [Double] = [3.5, 120.25, 950.75]
        let errnos: [Int32] = [0, 0, 5]
        let data = BatchCodec.encode(firstIndex: 42, offsets: offsets,
                                     elapsedMs: elapsedMs, errnos: errnos)
        let batch = BatchCodec.decode(data)
        #expect(batch != nil)
        #expect(batch?.firstIndex == 42)
        #expect(batch?.offsets == offsets)
        #expect(batch?.elapsedMs == elapsedMs)
        #expect(batch?.errnos == errnos)
    }

    @Test func rejectsGarbage() {
        #expect(BatchCodec.decode(Data()) == nil)
        #expect(BatchCodec.decode(Data(repeating: 0xFF, count: 64)) == nil)
        #expect(BatchCodec.decode(Data(repeating: 0x00, count: 10)) == nil) // 头部不足
    }

    @Test func emptyBatchRoundTrips() {
        let data = BatchCodec.encode(firstIndex: 0, offsets: [], elapsedMs: [], errnos: [])
        let batch = BatchCodec.decode(data)
        #expect(batch?.count == 0)
    }
}

// MARK: 特权 helper 的设备路径白名单

@Suite struct DevicePathValidationTests {
    @Test func acceptsWholeRawDiskOnly() {
        #expect(ScanRunner.pathAllowed("/dev/rdisk8"))
        #expect(ScanRunner.pathAllowed("/dev/rdisk0"))
    }

    @Test func rejectsEverythingElse() {
        #expect(!ScanRunner.pathAllowed("/dev/disk8"))      // 非裸设备
        #expect(!ScanRunner.pathAllowed("/dev/rdisk8s2"))   // 分区
        #expect(!ScanRunner.pathAllowed("/etc/passwd"))     // 普通文件
        #expect(!ScanRunner.pathAllowed("/tmp/evil"))       // 随意路径
        #expect(!ScanRunner.pathAllowed(""))
    }

    @Test func deviceProblemRejectsNonDeviceFiles() {
        // 存在但不是字符设备的路径必须被拒
        #expect(ScanRunner.deviceProblem("/etc/passwd") != nil)
        #expect(ScanRunner.deviceProblem("/dev/disk8") != nil)
    }
}

// MARK: 地图格子合并（悬停信息管道）

@Suite struct MapCellMergeTests {
    @Test func moreSevereOverrides() {
        let old = MapCell(status: .normal, elapsedMs: 5, blockIndex: 1)
        let merged = ScanEngine.mergedCell(old, status: .abnormal, elapsedMs: 300, blockIndex: 2)
        #expect(merged.status == .abnormal)
        #expect(merged.elapsedMs == 300)
        #expect(merged.blockIndex == 2)
    }

    @Test func lessSevereKeepsOld() {
        let old = MapCell(status: .error, elapsedMs: 900, blockIndex: 7)
        let merged = ScanEngine.mergedCell(old, status: .warning, elapsedMs: 120, blockIndex: 8)
        #expect(merged == old)
    }

    @Test func equalSeverityRefreshesSample() {
        let old = MapCell(status: .warning, elapsedMs: 120, blockIndex: 3)
        let merged = ScanEngine.mergedCell(old, status: .warning, elapsedMs: 150, blockIndex: 4)
        #expect(merged.status == .warning)
        #expect(merged.elapsedMs == 150)
        #expect(merged.blockIndex == 4)
    }

    @Test func unscannedCellYieldsToAnything() {
        let merged = ScanEngine.mergedCell(.unscanned, status: .normal, elapsedMs: 4, blockIndex: 0)
        #expect(merged.status == .normal)
    }
}

// MARK: 检测记录导出

@Suite struct ScanRecordExporterTests {
    let meta = ScanMeta(diskName: "WD Elements, 25A3", bsdName: "disk8",
                        diskSizeBytes: 4_000_787_030_016, blockSizeBytes: 131_072,
                        totalBlocks: 30_518, warnMs: 100, abnormalMs: 500,
                        startedAt: Date(timeIntervalSince1970: 1_785_000_000),
                        finishedAt: Date(timeIntervalSince1970: 1_785_000_900))
    let summary: ScanSummary = {
        var s = ScanSummary()
        s.normal = 30_500; s.warning = 10; s.abnormal = 6; s.error = 2; s.unscanned = 0
        return s
    }()
    let anomalies = [
        ScanRecord(blockIndex: 12, offsetBytes: 1_572_864, elapsedMs: 612.3,
                   status: .abnormal, errno: nil),
        ScanRecord(blockIndex: 15, offsetBytes: 1_966_080, elapsedMs: 1450.0,
                   status: .error, errno: 5),
    ]

    @Test func csvContainsMetaAndAnomalies() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, anomalies: anomalies)
        #expect(csv.hasPrefix("\u{FEFF}"))                       // Excel 需要 BOM
        #expect(csv.contains("块序号,偏移(字节),耗时(ms),状态,errno"))
        #expect(csv.contains("12,1572864,612.3,异常,"))
        #expect(csv.contains("15,1966080,1450.0,错误,5"))
        #expect(csv.contains("正常 30500 / 警告 10 / 异常 6 / 错误 2"))
    }

    @Test func csvEscapesCommasInDiskName() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, anomalies: [])
        #expect(csv.contains("\"WD Elements, 25A3 (/dev/disk8)\""))
    }

    @Test func jsonRoundTrips() throws {
        let data = try ScanRecordExporter.json(meta: meta, summary: summary,
                                               cells: [.unscanned, MapCell(status: .error, elapsedMs: 900, blockIndex: 15)],
                                               anomalies: anomalies)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["format"] as? String == "DiskProbe 扫描记录 v1")
        #expect((obj?["anomalies"] as? [[String: Any]])?.count == 2)
        #expect((obj?["mapCells"] as? [[String: Any]])?.count == 2)
    }

    @Test func emptyAnomaliesStillHasHeader() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, anomalies: [])
        #expect(csv.contains("块序号,偏移(字节),耗时(ms),状态,errno"))
    }
}
