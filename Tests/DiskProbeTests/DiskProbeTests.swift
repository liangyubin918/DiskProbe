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
    /// 3 个格子覆盖 30518 块：per = ceil(30518/3) = 10173
    let cells = [
        MapCell(status: .normal, elapsedMs: 8.0, blockIndex: 0),
        MapCell(status: .warning, elapsedMs: 120.5, blockIndex: 12),
        MapCell(status: .unscanned, elapsedMs: 0, blockIndex: -1),
    ]

    // 断言通过与导出端同一个 tr() 构造，语言无关（CI runner 可能是英文环境），
    // 验证的是行结构与数据而非具体语言
    @Test func csvContainsMetaAndAnomalies() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, cells: cells, anomalies: anomalies)
        #expect(csv.hasPrefix("\u{FEFF}"))                       // Excel 需要 BOM
        #expect(csv.contains(tr("块序号,偏移(字节),耗时(ms),状态,errno",
                                "block index,offset (bytes),elapsed (ms),status,errno")))
        #expect(csv.contains("12,1572864,612.3,\(BlockStatus.abnormal.displayName),"))
        #expect(csv.contains("15,1966080,1450.0,\(BlockStatus.error.displayName),5"))
        #expect(csv.contains(tr("正常 30500 / 警告 10 / 异常 6 / 错误 2",
                                "normal 30500 / warning 10 / abnormal 6 / error 2")))
    }

    @Test func csvCellDetailCoversWholeDisk() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, cells: cells, anomalies: anomalies)
        #expect(csv.contains(tr("格子序号,起始块,结束块,起始偏移(字节),状态,采样耗时(ms),采样块序号",
                                "cell,start block,end block,start offset (bytes),status,sampled elapsed (ms),sampled block index")))
        #expect(csv.contains("0,0,10172,0,\(BlockStatus.normal.displayName),8.0,0"))
        #expect(csv.contains("1,10173,20345,1333395456,\(BlockStatus.warning.displayName),120.5,12"))
        #expect(csv.contains("2,20346,30517,2666790912,\(BlockStatus.unscanned.displayName),,"))  // 未扫描格无采样值
    }

    @Test func csvExplainsEmptyAnomalyDetail() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, cells: cells, anomalies: [])
        #expect(csv.contains(tr("块序号,偏移(字节),耗时(ms),状态,errno",
                                "block index,offset (bytes),elapsed (ms),status,errno")))
        #expect(csv.contains(tr("（本次无非正常块）", "(no non-normal blocks in this scan)")))
    }

    @Test func csvEscapesCommasInDiskName() {
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, cells: [], anomalies: [])
        #expect(csv.contains("\"WD Elements, 25A3 (/dev/disk8)\""))
    }

    @Test func csvEscapesCarriageReturnsAndQuoteContent() {
        // \r 与 \n 一样破坏行结构，必须触发加引号；引号本身双写
        #expect(ScanRecordExporter.escape("a\rb") == "\"a\rb\"")
        #expect(ScanRecordExporter.escape("a\"b") == "\"a\"\"b\"")
        #expect(ScanRecordExporter.escape("plain") == "plain")
    }

    @Test func csvNeutralizesFormulaInjection() {
        // Excel/LibreOffice 把 = + - @ 开头的单元格按公式求值（卷名可被
        // 任何人改写），加 ' 前缀无害化
        #expect(ScanRecordExporter.escape("=cmd|'/C calc'!A1") == "'=cmd|'/C calc'!A1")
        #expect(ScanRecordExporter.escape("+SUM(A1)") == "'+SUM(A1)")
        #expect(ScanRecordExporter.escape("-flag") == "'-flag")
        #expect(ScanRecordExporter.escape("@risk") == "'@risk")
    }

    @Test func csvNumberAlwaysUsesDotDecimal() {
        // 显式钉死 POSIX 区域：即使用户区域是逗号小数也不能输出 "12,5"
        #expect(ScanRecordExporter.csvNumber(120.5) == "120.5")
        #expect(ScanRecordExporter.csvNumber(0) == "0.0")
    }

    @Test func smallDiskCellRowsStopAtDiskEnd() {
        // totalBlocks < 格子数的小盘：尾部空格子的 firstBlock 已越盘尾，
        // 不导出"起始块 > 结束块"的反区间行
        let smallMeta = ScanMeta(diskName: "U盘", bsdName: "disk9",
                                 diskSizeBytes: 100 * 4096, blockSizeBytes: 4096,
                                 totalBlocks: 100, warnMs: 100, abnormalMs: 500,
                                 startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 finishedAt: nil)
        var cells = Array(repeating: MapCell(status: .normal, elapsedMs: 5, blockIndex: 0), count: 100)
        for i in 0..<100 { cells[i] = MapCell(status: .normal, elapsedMs: 5, blockIndex: min(i, 99)) }
        cells += Array(repeating: .unscanned, count: 20)
        let csv = ScanRecordExporter.csv(meta: smallMeta, summary: ScanSummary(normal: 100),
                                         cells: cells, anomalies: [])
        #expect(csv.contains("99,99,99,"))          // 最后一个有效格在
        #expect(!csv.contains("\n100,100,"))        // 越盘尾的反区间行不出现
        #expect(!csv.contains("\n119,119,"))
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
        let csv = ScanRecordExporter.csv(meta: meta, summary: summary, cells: [], anomalies: [])
        #expect(csv.contains(tr("块序号,偏移(字节),耗时(ms),状态,errno",
                                "block index,offset (bytes),elapsed (ms),status,errno")))
    }
}

// MARK: 检查更新：版本比较（逐段数值比较，2.10 > 2.9）

@Suite struct UpdateVersionTests {
    @Test func patchBumpIsNewer() {
        #expect(UpdateChecker.isNewer("2.9", than: "2.8"))
        #expect(!UpdateChecker.isNewer("2.8", than: "2.8"))
        #expect(!UpdateChecker.isNewer("2.7", than: "2.8"))
    }

    @Test func twoDigitSegmentComparesNumerically() {
        #expect(UpdateChecker.isNewer("2.10", than: "2.9"))
        #expect(!UpdateChecker.isNewer("2.10", than: "2.10"))
    }

    @Test func vPrefixAndMissingSegments() {
        #expect(UpdateChecker.isNewer("v3", than: "2.9.1"))
        #expect(!UpdateChecker.isNewer("2", than: "2.0"))
    }
}

// MARK: 检测记录对比（按偏移对齐）

@Suite struct RecordDiffTests {
    private func rec(_ block: Int, _ offset: Int64, _ status: BlockStatus) -> ScanRecord {
        ScanRecord(blockIndex: block, offsetBytes: offset, elapsedMs: 10, status: status, errno: nil)
    }

    @Test func newWorsenedImprovedPersistentResolved() {
        let old = [
            rec(1, 128_000, .warning),    // 持续
            rec(2, 256_000, .warning),    // 加重（本次 abnormal）
            rec(3, 384_000, .abnormal),   // 好转（本次 warning，仍异常但更轻）
            rec(4, 512_000, .abnormal),   // 恢复（本次无异常）
        ]
        let new = [
            rec(1, 128_000, .warning),    // 持续
            rec(2, 256_000, .abnormal),   // 加重
            rec(3, 384_000, .warning),    // 好转
            rec(9, 768_000, .error),      // 新增
        ]
        let d = RecordDiff.compute(old: old, new: new)
        #expect(d.newCount == 1)
        #expect(d.worsenedCount == 1)
        #expect(d.improvedCount == 1)
        #expect(d.persistentCount == 1)
        #expect(d.resolvedCount == 1)
        // 排序：新增 > 加重 > 好转 > 持续 > 恢复
        #expect(d.items.map(\.kind) == [.new, .worsened, .improved, .persistent, .resolved])
    }

    @Test func severityDecreaseCountsAsImproved() {
        let old = [rec(1, 0, .abnormal)]
        let new = [rec(1, 0, .warning)]
        let d = RecordDiff.compute(old: old, new: new)
        #expect(d.improvedCount == 1)
        #expect(d.worsenedCount == 0)
        #expect(d.resolvedCount == 0)
        #expect(d.persistentCount == 0)
    }

    @Test func emptyInputs() {
        let d = RecordDiff.compute(old: [], new: [])
        #expect(d.items.isEmpty)
        #expect(d.newCount == 0)
    }
}

// MARK: 记录 JSON 解析（与导出端互为镜像）

@Suite struct RecordFileRoundTripTests {
    @Test func parseExportedJSON() throws {
        let meta = ScanMeta(diskName: "盘A", bsdName: "disk9", diskSizeBytes: 1024, blockSizeBytes: 128,
                            totalBlocks: 8, warnMs: 100, abnormalMs: 500,
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            finishedAt: Date(timeIntervalSince1970: 1_700_000_060))
        let anomalies = [ScanRecord(blockIndex: 3, offsetBytes: 384, elapsedMs: 600, status: .abnormal, errno: nil)]
        let data = try ScanRecordExporter.json(meta: meta, summary: ScanSummary(normal: 7, abnormal: 1),
                                               cells: [], anomalies: anomalies)
        let parsed = try ScanRecordExporter.parseJSON(data)
        #expect(parsed.meta?.bsdName == "disk9")
        #expect(parsed.anomalies.count == 1)
        #expect(parsed.anomalies[0].status == .abnormal)
        #expect(parsed.anomalies[0].offsetBytes == 384)
    }
}

// MARK: SMART 详情解析（smartctl -j -a JSON → SMARTDetails）

@Suite struct SMARTDetailsParsingTests {
    /// 结构对照真实抓取：外置 SATA 盘（Seagate Momentus，含 UNC 错误日志）
    private let ataJSON = """
    {
      "device": {"name": "/dev/disk8", "type": "ata", "protocol": "ATA"},
      "model_name": "ST9500325AS",
      "serial_number": "S2WE7EY2",
      "firmware_version": "0005HPM1",
      "user_capacity": {"blocks": 976773168, "bytes": 500107862016},
      "rotation_rate": 5400,
      "form_factor": {"ata_value": 2, "name": "2.5 inches"},
      "smart_status": {"passed": true},
      "ata_smart_attributes": {
        "revision": 16,
        "table": [
          {"id": 1, "name": "Raw_Read_Error_Rate", "value": 112, "worst": 93, "thresh": 6,
           "when_failed": "", "flags": {"value": 15, "string": "POSR--", "prefailure": true},
           "raw": {"value": 149211375, "string": "149211375"}},
          {"id": 5, "name": "Reallocated_Sector_Ct", "value": 99, "worst": 99, "thresh": 36,
           "when_failed": "", "flags": {"value": 50, "string": "PO--CK", "prefailure": true},
           "raw": {"value": 40, "string": "40"}},
          {"id": 187, "name": "Reported_Uncorrect", "value": 90, "worst": 95, "thresh": 100,
           "when_failed": "", "flags": {"value": 18, "string": "-O--C-", "prefailure": false},
           "raw": {"value": 5, "string": "5"}},
          {"id": 198, "name": "Offline_Uncorrectable", "value": 100, "worst": 100, "thresh": 0,
           "when_failed": "FAILING_NOW", "flags": {"value": 0, "string": "----C-", "prefailure": false},
           "raw": {"value": 0, "string": "0"}}
        ]
      },
      "ata_smart_error_log": {
        "revision": 1,
        "summary": {
          "revision": 1,
          "device_error_count": 6,
          "logged_error_count": 1,
          "table": [
            {"error_number": 6, "lifetime_hours": 8853,
             "error_description": "Error: UNC at LBA = 0x0fffffff = 268435455",
             "completion_registers": {"error": 64, "status": 81, "count": 0, "lba": 16777215}}
          ]
        }
      },
      "ata_smart_self_testlog": {
        "revision": 1,
        "table": [
          {"index": 1, "type": {"value": 1, "string": "Offline"},
           "status": {"value": 0, "string": "Completed without error", "passed": true},
           "lifetime_hours": 900},
          {"index": 2, "type": {"value": 2, "string": "Short offline"},
           "status": {"value": 1, "string": "Completed: read failure", "passed": false},
           "lifetime_hours": 910, "lba_first_error": {"value": 268435455, "string": "268435455"}},
          {"index": 3, "type": {"value": 0, "string": ""},
           "status": {"value": 0, "string": ""}, "lifetime_hours": 0}
        ]
      }
    }
    """

    /// 内置 NVMe 盘（无 smart_status，健康度由 critical_warning 兜底）
    private let nvmeJSON = """
    {
      "device": {"name": "/dev/disk0", "type": "nvme", "protocol": "NVMe"},
      "model_name": "APPLE SSD AP0512Z",
      "serial_number": "060231093ca3a02e",
      "nvme_smart_health_information_log": {
        "critical_warning": 0, "temperature": 32, "available_spare": 100,
        "available_spare_threshold": 99, "percentage_used": 0,
        "data_units_read": 18947871, "data_units_written": 19483178,
        "host_reads": 192186738, "host_writes": 1185996852,
        "power_cycles": 116, "power_on_hours": 196, "unsafe_shutdowns": 6,
        "media_errors": 0, "num_err_log_entries": 0
      }
    }
    """

    private func parse(_ json: String) throws -> SMARTDetails {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let dict = obj as? [String: Any] else {
            struct NotDict: Error {}
            throw NotDict()
        }
        return SMARTDetails.parse(json: dict, bsdName: "disk8")
    }

    @Test func ataDetailsParsedFully() throws {
        let d = try parse(ataJSON)
        #expect(d.model == "ST9500325AS")
        #expect(d.serial == "S2WE7EY2")
        #expect(d.capacityBytes == 500_107_862_016)
        #expect(d.rotationRate == 5400)
        #expect(d.formFactorName == "2.5 inches")
        #expect(d.health == "PASSED")
        #expect(d.isNVMe == false)
        #expect(d.attributes.count == 4)
    }

    @Test func ataAttributeValuesAndFlags() throws {
        let d = try parse(ataJSON)
        let reallocated = d.attributes.first { $0.id == 5 }
        #expect(reallocated?.rawString == "40")
        #expect(reallocated?.value == 99)
        #expect(reallocated?.threshold == 36)
        #expect(reallocated?.isPrefail == true)
        #expect(reallocated?.isFailed == false)
        #expect(reallocated?.isCritical == false)

        // 原始值带后缀的形态（如温度 "24 (0 1 0 0 0)"）原样保留字符串
        #expect(d.attributes.first { $0.id == 1 }?.rawString == "149211375")
    }

    @Test func failingAndCriticalRowsAreDetected() throws {
        let d = try parse(ataJSON)
        // when_failed = FAILING_NOW → isFailed
        let uncorrectable = d.attributes.first { $0.id == 198 }
        #expect(uncorrectable?.isFailed == true)

        // 当前值 90 ≤ 阈值 100 → isCritical（多数盘 when_failed 为空，靠数值兜底）
        let reported = d.attributes.first { $0.id == 187 }
        #expect(reported?.isCritical == true)
        #expect(reported?.isFailed == false)
    }

    @Test func ataErrorLogAndSelfTestParsed() throws {
        let d = try parse(ataJSON)
        #expect(d.errorLog.count == 1)
        #expect(d.errorLog[0].errorNumber == 6)
        #expect(d.errorLog[0].lifetimeHours == 8853)
        #expect(d.errorLog[0].description.contains("UNC at LBA"))
        #expect(d.errorLogTotalCount == 6)  // 日志只留 5 条，累计 6 次

        // 空槽位（type 为空串）被过滤
        #expect(d.selfTestLog.count == 2)
        #expect(d.selfTestLog[0].passed == true)
        #expect(d.selfTestLog[1].passed == false)
        #expect(d.selfTestLog[1].lbaFirstError == 268_435_455)
    }

    @Test func nvmeDetailsParsedWithHealthFallback() throws {
        let d = try parse(nvmeJSON)
        #expect(d.isNVMe == true)
        #expect(d.model == "APPLE SSD AP0512Z")
        #expect(d.attributes.isEmpty)
        #expect(d.errorLog.isEmpty)
        let h = try #require(d.nvmeHealth)
        #expect(h.temperatureC == 32)
        #expect(h.percentageUsed == 0)
        #expect(h.dataUnitsWritten == 19_483_178)
        #expect(h.unsafeShutdowns == 6)
        #expect(h.mediaErrors == 0)
        // JSON 无 smart_status：critical_warning == 0 → PASSED 兜底
        #expect(d.health == "PASSED")
    }

    @Test func missingDeviceYieldsEmptyDetails() throws {
        // 设备不存在/刚拔出：smartctl 仍输出合法 JSON 但无有效字段
        let d = try parse("""
        {
          "smartctl": {
            "exit_status": 1,
            "messages": [{"string": "/dev/disk8: Unable to detect device type", "severity": "error"}]
          }
        }
        """)
        #expect(d.attributes.isEmpty)
        #expect(d.nvmeHealth == nil)
        #expect(d.model == nil)
        // readDetails() 会据此返回 .failure 并透传 smartctl 报错文本
    }
}

// MARK: SMART 详情展示格式化（原始值千分位等）

@Suite struct SMARTRawDisplayTests {
    @Test func groupsOnlyLeadingNumbers() {
        #expect(SMARTDetailsSheet.formatLeadingNumber("149211375") == "149,211,375")
        #expect(SMARTDetailsSheet.formatLeadingNumber("8866") == "8,866")
        // 前导数字不足 4 位不加分组符
        #expect(SMARTDetailsSheet.formatLeadingNumber("40") == "40")
        #expect(SMARTDetailsSheet.formatLeadingNumber("24") == "24")
        // 带后缀注释的原始值：只格式化前导部分，后缀原样保留
        #expect(SMARTDetailsSheet.formatLeadingNumber("24 (0 1 0 0 0)") == "24 (0 1 0 0 0)")
        #expect(SMARTDetailsSheet.formatLeadingNumber("2263 (168 229 0)") == "2,263 (168 229 0)")
        // 空串与非数字开头原样返回
        #expect(SMARTDetailsSheet.formatLeadingNumber("") == "")
        #expect(SMARTDetailsSheet.formatLeadingNumber("abc123") == "abc123")
    }
}
