import Testing
@testable import DiskProbeCore
@testable import DiskProbe

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
