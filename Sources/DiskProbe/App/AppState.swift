import Foundation
import SwiftUI
import DiskProbeCore

// MARK: - 全局 AppState（@MainActor，UI 持有）

@MainActor
final class AppState: ObservableObject {

    @Published var disks: [DiskInfo] = []
    @Published var selectedDisk: DiskInfo? = nil
    @Published var isEnumerating = false
    @Published var enumerateError: String? = nil

    // SMART 信息（选中盘）
    @Published var smartInfo: SMARTInfo? = nil
    @Published var smartError: String? = nil
    @Published var isReadingSMART = false

    @Published var thresholds: ScanThresholds = {
        let defaults = UserDefaults.standard
        return ScanThresholds(
            warnMs: defaults.object(forKey: "scan.warnMs") as? Double ?? 100,
            abnormalMs: defaults.object(forKey: "scan.abnormalMs") as? Double ?? 500
        )
    }() {
        didSet {
            // 去抖同步给引擎：快速连续调整时只有最后一次生效，避免乱序覆盖
            thresholdSyncTask?.cancel()
            thresholdSyncTask = Task { [thresholds] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                await engine.updateThresholds(thresholds)
            }
        }
    }

    @Published var progress: ScanProgress? = nil
    @Published var scanState: ScanState = .idle
    @Published var useRealScan: Bool = false // 真实读取待安全的特权 XPC helper 实现后再开放

    // 认证状态
    @Published var isAuthenticating = false
    @Published var authError: String? = nil

    // SMART 请求序号（防陈旧结果覆盖）
    private var smartRequestID = 0

    // 扫描地图格子（引擎随进度事件附带完整快照，UI 只做赋值）
    @Published var mapCells: [BlockStatus] = []

    // 统计计数（从进度事件的累计 summary 取值）
    @Published var statNormal = 0
    @Published var statWarning = 0
    @Published var statAbnormal = 0
    @Published var statError = 0

    // 地图尺寸
    let mapColumns = 100
    let mapRows = 60

    // 进度监听任务（保证任意时刻只有一个消费者，避免事件被瓜分）
    private var listenerTask: Task<Void, Never>? = nil
    private var thresholdSyncTask: Task<Void, Never>? = nil

    let engine = ScanEngine()

    init() {
        Task { await refreshDisks() }
    }

    // MARK: 磁盘列表
    func refreshDisks() async {
        isEnumerating = true
        enumerateError = nil
        let result = await Task.detached(priority: .userInitiated) { DiskEnumerator.enumerate() }.value
        disks = result
        // 选中盘可能已被拔掉：只有在结果里仍存在时才保留，否则回退到默认选择
        if let current = selectedDisk, result.contains(current) {
            // 保留当前选择
        } else {
            selectedDisk = result.first(where: { $0.isExternalPhysical }) ?? result.first
        }
        isEnumerating = false
    }

    // MARK: SMART
    func refreshSMART() async {
        guard let disk = selectedDisk else {
            smartInfo = nil
            smartError = nil
            isReadingSMART = false
            return
        }
        // 请求序号：切换磁盘后，旧请求的慢结果不允许覆盖新盘的数据
        smartRequestID += 1
        let requestID = smartRequestID
        isReadingSMART = true
        smartError = nil

        let result = await Task.detached(priority: .userInitiated) {
            await SMARTReader.read(bsdName: disk.bsdName)
        }.value

        guard requestID == smartRequestID, disk.id == selectedDisk?.id else { return }
        isReadingSMART = false
        switch result {
        case .success(let info):
            smartInfo = info
            smartError = nil
        case .failure(let err):
            // 保留上一次成功的数据，瞬时失败不至于闪空
            smartError = err.localizedDescription
        }
    }

    // MARK: 扫描控制

    func startScan(blockSizeKB: Int = 128) {
        guard let d = selectedDisk else { return }
        progress = nil
        authError = nil
        resetStats()

        // 初始化地图
        mapCells = Array(repeating: .unscanned, count: mapColumns * mapRows)

        // 取消旧监听，保证进度流始终只有一个消费者
        listenerTask?.cancel()
        listenerTask = Task {
            if useRealScan {
                isAuthenticating = true
                let ok = await engine.authenticate(disk: d, blockSize: Int64(blockSizeKB) * 1024)
                isAuthenticating = false
                if !ok {
                    authError = await engine.takeLastAuthError() ?? "未能以管理员权限启动读取程序。可能取消了密码输入。"
                    return
                }
            }
            let started = await engine.start(
                disk: d,
                blockSize: Int64(blockSizeKB) * 1024,
                cellCount: mapColumns * mapRows,
                useReal: useRealScan
            )
            guard started else {
                authError = await engine.takeLastAuthError() ?? "无法开始扫描。"
                await syncState()
                return
            }
            await listenProgress()
        }
    }

    func pauseScan() {
        Task { await engine.pause(); await syncState() }
    }
    func resumeScan() {
        Task { await engine.resume(); await syncState() }
    }
    func stopScan() {
        Task {
            await engine.stop()
            await syncState()
        }
    }

    private func listenProgress() async {
        for await p in await engine.progress() {
            applyProgress(p)
            await syncState()
        }
        await syncState()
    }

    // MARK: 进度应用

    /// 进度事件是引擎产生的完整快照（地图 + 累计统计），UI 直接取值。
    /// 即使事件被缓冲策略合并丢弃，下一次事件仍是正确状态。
    private func applyProgress(_ p: ScanProgress) {
        progress = p
        if p.mapCells.count == mapColumns * mapRows {
            mapCells = p.mapCells
        }
        statNormal = p.summary.normal
        statWarning = p.summary.warning
        statAbnormal = p.summary.abnormal
        statError = p.summary.error
    }

    private func resetStats() {
        statNormal = 0
        statWarning = 0
        statAbnormal = 0
        statError = 0
    }

    private func syncState() async {
        // AppState 已在 MainActor，await 回来后直接赋值即可
        scanState = await engine.state
    }
}
