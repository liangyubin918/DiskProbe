import Foundation
import DiskProbeCore

// MARK: - 扫描引擎
//
// 真实裸设备读取必须由经 SMAppService/SMJobBless 安装、签名校验的 XPC
// privileged helper 提供。旧版将普通用户可写 bundle 内的二进制通过
// AuthorizationExecuteWithPrivileges 提升为 root，存在本地提权风险，已移除。
// 当前发行版只保留不接触设备的演示扫描；请求真实读取会明确失败，绝不降级为
// 不受保护的提权执行。

actor ScanEngine {
    private(set) var state: ScanState = .idle
    private(set) var thresholds: ScanThresholds
    private(set) var useRealReader = false

    private var pauseRequested = false
    private var stopRequested = false
    private var task: Task<Void, Never>?
    private var currentRunID: UUID?

    private var progressStream: AsyncStream<ScanProgress>.Continuation?
    private var progressAsyncStream: AsyncStream<ScanProgress>?

    private(set) var totalBlocks = 0
    private(set) var diskSize: Int64 = 0
    private(set) var blockSize: Int64 = 128 * 1024

    // 地图快照由引擎维护：每个进度事件都是完整快照，事件被丢弃/合并也不影响
    // 地图与统计的正确性（配合 bufferingNewest(1) 缓冲策略）
    private var map: [BlockStatus] = []
    private var cellCount = 0
    private var cellsPerGroup = 1

    private var speedSamples: [(elapsed: TimeInterval, blocksDone: Int)] = []

    private(set) var lastAuthError: String?

    init(thresholds: ScanThresholds = .init()) {
        self.thresholds = thresholds
    }

    /// 把块数分组映射到固定格子数：向上取整，保证任何容量都能覆盖全部格子。
    static func cellsPerBlockGroup(totalBlocks: Int, cellCount: Int) -> Int {
        guard totalBlocks > 0, cellCount > 0 else { return 1 }
        return (totalBlocks + cellCount - 1) / cellCount
    }

    func authenticate(disk: DiskInfo, blockSize: Int64 = 128 * 1024) async -> Bool {
        guard disk.sizeBytes > 0, blockSize > 0 else {
            lastAuthError = "磁盘容量或块大小无效。"
            return false
        }
        lastAuthError = "真实裸设备读取已暂时禁用：旧版特权 helper 存在本地提权与路径竞态风险。请在签名校验的 XPC privileged helper 完成后再启用该功能。"
        return false
    }

    func takeLastAuthError() -> String? {
        defer { lastAuthError = nil }
        return lastAuthError
    }

    /// 开始演示扫描。返回 false 表示未能启动，原因见 takeLastAuthError()。
    @discardableResult
    func start(disk: DiskInfo, blockSize: Int64 = 128 * 1024, cellCount: Int = 6000, useReal: Bool = false) -> Bool {
        guard state == .idle || state == .finished || state == .stopped || state == .error else {
            lastAuthError = "扫描正在进行中，请先停止当前扫描。"
            return false
        }
        guard disk.sizeBytes > 0, blockSize > 0 else {
            state = .error
            lastAuthError = "磁盘容量或块大小无效。"
            return false
        }
        guard !useReal else {
            state = .error
            lastAuthError = "真实裸设备读取未启用。"
            return false
        }

        let quotient = disk.sizeBytes / blockSize
        let remainder = disk.sizeBytes % blockSize

        self.diskSize = disk.sizeBytes
        self.blockSize = blockSize
        self.totalBlocks = max(1, Int(quotient + (remainder == 0 ? 0 : 1)))
        self.cellCount = max(1, cellCount)
        self.cellsPerGroup = Self.cellsPerBlockGroup(totalBlocks: self.totalBlocks, cellCount: self.cellCount)
        self.map = Array(repeating: .unscanned, count: self.cellCount)
        self.useRealReader = false
        self.stopRequested = false
        self.pauseRequested = false
        self.speedSamples = []

        // 只保留最新事件：进度是全量快照，丢弃旧事件不影响正确性，
        // 也避免消费端卡顿时 unbounded 缓冲无限增长
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        progressAsyncStream = stream
        progressStream = continuation
        state = .scanning

        let runID = UUID()
        currentRunID = runID
        task = Task { [weak self] in
            await self?.runMockScan(disk: disk, runID: runID, scanStart: Date())
        }
        return true
    }

    func pause() {
        guard state == .scanning else { return }
        pauseRequested = true
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        pauseRequested = false
        state = .scanning
    }

    func stop() {
        guard currentRunID != nil else { return }
        stopRequested = true
        pauseRequested = false
        task?.cancel()
        task = nil
        currentRunID = nil
        state = .stopped
        progressStream?.finish()
        progressStream = nil
    }

    func updateThresholds(_ thresholds: ScanThresholds) {
        self.thresholds = thresholds
    }

    func progress() -> AsyncStream<ScanProgress> {
        progressAsyncStream ?? AsyncStream { $0.finish() }
    }

    private func runMockScan(disk: DiskInfo, runID: UUID, scanStart: Date) async {
        var scanned = 0
        var summary = ScanSummary(unscanned: totalBlocks)
        // 暂停时长不计入 elapsed，否则 ETA 会被暂停时间永久推高
        var pausedTotal: TimeInterval = 0
        var pauseBegan: Date? = nil
        for i in 0..<totalBlocks {
            guard isCurrent(runID) else { return }
            if Task.isCancelled || stopRequested {
                finish(runID: runID, state: .stopped)
                return
            }
            while pauseRequested {
                if pauseBegan == nil { pauseBegan = Date() }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard isCurrent(runID) else { return }
                if Task.isCancelled || stopRequested {
                    finish(runID: runID, state: .stopped)
                    return
                }
            }
            if let began = pauseBegan {
                pausedTotal += Date().timeIntervalSince(began)
                pauseBegan = nil
            }

            let (offset, overflow) = Int64(i).multipliedReportingOverflow(by: blockSize)
            guard !overflow, offset >= 0, offset < diskSize else {
                finish(runID: runID, state: .error)
                return
            }
            let size = min(blockSize, diskSize - offset)
            let random = Double.random(in: 0..<1)
            var elapsedMs = Double.random(in: 3..<20)
            var failed = false
            if random < 0.0005 {
                elapsedMs = Double.random(in: 800..<2000)
                failed = true
            } else if random < 0.003 {
                elapsedMs = Double.random(in: 120..<900)
            }

            let block = ScanBlock(
                id: i,
                startOffset: offset,
                size: size,
                elapsedMs: elapsedMs,
                status: thresholds.classify(elapsedMs: elapsedMs, failed: failed),
                errnoValue: failed ? 5 : nil
            )
            scanned += 1
            // 引擎侧累计统计与地图快照（UI 直接取值，不依赖每个事件都被消费）
            switch block.status {
            case .normal:   summary.normal += 1
            case .warning:  summary.warning += 1
            case .abnormal: summary.abnormal += 1
            case .error:    summary.error += 1
            case .unscanned: break
            }
            summary.unscanned -= 1
            let cellIndex = min(cellCount - 1, i / cellsPerGroup)
            if block.status.severityOrder > map[cellIndex].severityOrder {
                map[cellIndex] = block.status
            }
            let elapsed = Date().timeIntervalSince(scanStart) - pausedTotal
            let speed = updateSpeed(elapsed: elapsed, scanned: scanned)
            let remaining = max(0, totalBlocks - scanned)
            let eta = Double(remaining) * elapsed / Double(max(scanned, 1))
            let progress = ScanProgress(
                currentIndex: i,
                totalBlocks: totalBlocks,
                scannedCount: scanned,
                elapsedSeconds: elapsed,
                speedMBps: speed,
                etaSeconds: eta,
                lastBlock: block,
                summary: summary,
                mapCells: map
            )
            guard isCurrent(runID) else { return }
            progressStream?.yield(progress)
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        finish(runID: runID, state: .finished)
    }

    private func isCurrent(_ runID: UUID) -> Bool {
        currentRunID == runID
    }

    private func finish(runID: UUID, state: ScanState) {
        guard isCurrent(runID) else { return }
        self.state = state
        currentRunID = nil
        task = nil
        progressStream?.finish()
        progressStream = nil
    }

    private func updateSpeed(elapsed: TimeInterval, scanned: Int) -> Double {
        speedSamples.append((elapsed, scanned))
        // 样本按 elapsed 有序，从队首逐个剔除过期样本即可
        while let first = speedSamples.first, elapsed - first.elapsed > 8.0 {
            speedSamples.removeFirst()
        }
        guard let first = speedSamples.first, speedSamples.count > 1 else { return 0 }
        let duration = elapsed - first.elapsed
        let blocks = scanned - first.blocksDone
        return duration > 0.05 ? Double(blocks) * Double(blockSize) / 1024 / 1024 / duration : 0
    }
}

// MARK: - 扫描状态与进度模型

enum ScanState: Equatable, Sendable {
    case idle
    case scanning
    case paused
    case stopped
    case finished
    case error
}

struct ScanProgress: Sendable {
    let currentIndex: Int
    let totalBlocks: Int
    let scannedCount: Int
    let elapsedSeconds: TimeInterval
    let speedMBps: Double
    let etaSeconds: TimeInterval
    let lastBlock: ScanBlock
    /// 引擎累计的分类统计（含未扫描数）
    let summary: ScanSummary
    /// 完整地图快照，与引擎内部维护的 map 一致
    let mapCells: [BlockStatus]

    var fraction: Double {
        totalBlocks == 0 ? 0 : min(1, Double(scannedCount) / Double(totalBlocks))
    }
}

struct ScanSummary: Sendable {
    var normal = 0
    var warning = 0
    var abnormal = 0
    var error = 0
    var unscanned = 0

    var total: Int { normal + warning + abnormal + error + unscanned }
    var hasIssues: Bool { warning + abnormal + error > 0 }
}
