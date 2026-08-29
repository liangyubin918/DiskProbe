import Foundation
import DiskProbeCore

// MARK: - 扫描引擎
//
// 只有一种模式：真实只读扫描。由 SMAppService 安装、签名校验的 XPC
// privileged helper（DiskProbeHelper，root 权限 launchd daemon）执行
// 只读裸设备扫描，本 actor 消费其批次流做分类/统计/地图/速度/ETA。
// 旧版 AuthorizationExecuteWithPrivileges 提权方案存在本地提权风险，已废弃。
//
// 注意：必须从 .app bundle 启动（SMAppService 要求），swift run 不可用。

actor ScanEngine {
    private(set) var state: ScanState = .idle
    private(set) var thresholds: ScanThresholds

    private var pauseRequested = false
    private var stopRequested = false
    private var task: Task<Void, Never>?
    private var currentRunID: UUID?

    private var progressStream: AsyncStream<ScanProgress>.Continuation?
    private var progressAsyncStream: AsyncStream<ScanProgress>?
    private var realSession: RealScanSession?

    private(set) var totalBlocks = 0
    private(set) var diskSize: Int64 = 0
    private(set) var blockSize: Int64 = 128 * 1024

    // 地图快照由引擎维护：每个进度事件都是完整快照，事件被丢弃/合并也不影响
    // 地图与统计的正确性（配合 bufferingNewest(1) 缓冲策略）
    private var map: [MapCell] = []
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

    /// 格子合并：更严重的状态覆盖；同级用最新采样刷新（悬停可见最新耗时）。
    static func mergedCell(_ old: MapCell, status: BlockStatus, elapsedMs: Double, blockIndex: Int) -> MapCell {
        if status.severityOrder >= old.status.severityOrder {
            return MapCell(status: status, elapsedMs: elapsedMs, blockIndex: blockIndex)
        }
        return old
    }

    func takeLastAuthError() -> String? {
        defer { lastAuthError = nil }
        return lastAuthError
    }

    /// 开始真实只读扫描（通过特权 XPC helper）。
    /// 返回 false 表示未能启动，原因见 takeLastAuthError()。
    @discardableResult
    func start(disk: DiskInfo, blockSize: Int64 = 128 * 1024, cellCount: Int = 6000) async -> Bool {
        guard state == .idle || state == .finished || state == .stopped || state == .error else {
            lastAuthError = "扫描正在进行中，请先停止当前扫描。"
            return false
        }
        guard disk.sizeBytes > 0, blockSize > 0 else {
            state = .error
            lastAuthError = "磁盘容量或块大小无效。"
            return false
        }

        let session = RealScanSession()
        guard let batchStream = await session.begin(bsdName: disk.bsdName, blockSize: UInt64(blockSize)) else {
            state = .error
            lastAuthError = session.lastError ?? "无法连接特权助手。若已安装仍失败，请在 app 内点「重装特权助手」重新注册后重试。"
            return false
        }
        realSession = session

        let quotient = disk.sizeBytes / blockSize
        let remainder = disk.sizeBytes % blockSize

        self.diskSize = disk.sizeBytes
        self.blockSize = blockSize
        self.totalBlocks = max(1, Int(quotient + (remainder == 0 ? 0 : 1)))
        self.cellCount = max(1, cellCount)
        self.cellsPerGroup = Self.cellsPerBlockGroup(totalBlocks: self.totalBlocks, cellCount: self.cellCount)
        self.map = Array(repeating: .unscanned, count: self.cellCount)
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
            await self?.runRealScan(runID: runID, scanStart: Date(), batches: batchStream)
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
        realSession?.stop()
        // 停止后立刻断开并释放会话，不让 XPC 连接悬到下次扫描
        realSession?.close()
        realSession = nil
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

    /// 真实扫描：消费 helper 回传的批次流，复用与演示扫描相同的
    /// 分类/统计/地图/速度逻辑。
    private func runRealScan(runID: UUID, scanStart: Date, batches: AsyncStream<ScanBatch>) async {
        var scanned = 0
        var summary = ScanSummary(unscanned: totalBlocks)
        var pausedTotal: TimeInterval = 0
        var pauseBegan: Date? = nil
        var pauseSentToHelper = false

        for await batch in batches {
            guard isCurrent(runID) else { return }
            if Task.isCancelled || stopRequested {
                finish(runID: runID, state: .stopped)
                return
            }
            if pauseRequested, !pauseSentToHelper {
                realSession?.pause()
                pauseSentToHelper = true
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
            if pauseBegan != nil {
                pausedTotal += Date().timeIntervalSince(pauseBegan!)
                pauseBegan = nil
            }
            if pauseSentToHelper, !pauseRequested {
                realSession?.resume()
                pauseSentToHelper = false
            }

            // 整批处理完只 yield 一次：进度是全量快照，逐块 yield 会把
            // 6000 格快照重复拷贝上百次
            var lastBlock: ScanBlock? = nil
            for k in 0..<batch.count {
                let i = batch.firstIndex + k
                guard i < totalBlocks else { continue }
                let elapsedMs = batch.elapsedMs[k]
                let failed = batch.errnos[k] != 0
                let (offset, overflow) = Int64(i).multipliedReportingOverflow(by: blockSize)
                guard !overflow, offset < diskSize else { continue }
                let size = min(blockSize, diskSize - offset)

                let block = ScanBlock(
                    id: i,
                    startOffset: offset,
                    size: size,
                    elapsedMs: elapsedMs,
                    status: thresholds.classify(elapsedMs: elapsedMs, failed: failed),
                    errnoValue: failed ? batch.errnos[k] : nil
                )
                scanned += 1
                switch block.status {
                case .normal:   summary.normal += 1
                case .warning:  summary.warning += 1
                case .abnormal: summary.abnormal += 1
                case .error:    summary.error += 1
                case .unscanned: break
                }
                let cellIndex = min(cellCount - 1, i / cellsPerGroup)
                map[cellIndex] = Self.mergedCell(map[cellIndex], status: block.status,
                                                 elapsedMs: block.elapsedMs, blockIndex: i)
                lastBlock = block
            }

            if let last = lastBlock {
                summary.unscanned = max(0, totalBlocks - scanned)
                let elapsed = Date().timeIntervalSince(scanStart) - pausedTotal
                let speed = updateSpeed(elapsed: elapsed, scanned: scanned)
                let remaining = max(0, totalBlocks - scanned)
                let eta = Double(remaining) * elapsed / Double(max(scanned, 1))
                progressStream?.yield(ScanProgress(
                    currentIndex: last.id,
                    totalBlocks: totalBlocks,
                    scannedCount: scanned,
                    elapsedSeconds: elapsed,
                    speedMBps: speed,
                    etaSeconds: eta,
                    lastBlock: last,
                    summary: summary,
                    mapCells: map
                ))
            }
        }

        guard isCurrent(runID) else { return }
        if let error = realSession?.lastError {
            lastAuthError = "扫描异常终止：\(error)"
            finish(runID: runID, state: .error)
        } else {
            finish(runID: runID, state: .finished)
        }
    }

    private func isCurrent(_ runID: UUID) -> Bool {
        currentRunID == runID
    }

    private func finish(runID: UUID, state: ScanState) {
        guard isCurrent(runID) else { return }
        self.state = state
        currentRunID = nil
        task = nil
        realSession?.close()
        realSession = nil
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
    let mapCells: [MapCell]

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
