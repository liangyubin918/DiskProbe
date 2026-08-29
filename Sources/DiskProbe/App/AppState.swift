import Foundation
import SwiftUI
import ServiceManagement
import DiskProbeCore

// MARK: - 特权助手端到端健康状态

/// SMAppService 的 .enabled 只表示"已注册"；重新打包后注册过期时
/// daemon 实际 spawn 失败。此枚举用 ping 结果区分真实可用性。
enum HelperHealth: Equatable {
    case checking                       // ping 进行中
    case ready                          // ping 通且版本与 app 一致
    case stale(reported: String)        // ping 通但版本旧（注册的是旧版 helper）
    case unreachable                    // ping 不通（daemon 起不来/被拒）
}

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

    // 特权助手（SMAppService daemon）
    @Published var helperStatus: SMAppService.Status = .notRegistered
    /// 端到端健康：ping 通且版本匹配才算就绪。status=.enabled 只代表"已注册"，
    /// 重新打包后注册过期时 daemon 实际起不来，必须用 ping 区分。
    @Published var helperHealth: HelperHealth = .checking
    /// 安装/重装操作进行中
    @Published var helperOpInProgress = false
    /// 安装/重装操作的结果错误；成功或开始新操作时清空（避免旧错误粘滞显示）
    @Published var helperOpError: String? = nil
    private var pingGeneration = 0

    private var helperService: SMAppService {
        .daemon(plistName: HelperIdentifiers.launchdPlistName)
    }

    // 扫描错误提示
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
        helperStatus = helperService.status
        // 无头模式：`open DiskProbe.app --args --register-helper` 注册完自动退出，
        // 用于脚本化安装/诊断（与点击"安装特权助手"完全同一条代码路径）
        if CommandLine.arguments.contains("--register-helper") {
            headlessRegister()
        }
    }

    private func headlessRegister() {
        Task {
            runHelperOperation(reinstall: true)
            while helperOpInProgress {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    // MARK: 特权助手

    func refreshHelperStatus() {
        helperStatus = helperService.status
        refreshHelperHealth()
    }

    /// 已注册时用 ping 验证 daemon 真的能启动、且不是旧版本残留。
    /// 带代数序号：连续刷新时只有最后一次的 ping 结果生效。
    private func refreshHelperHealth() {
        guard helperStatus == .enabled else {
            helperHealth = .checking
            return
        }
        pingGeneration += 1
        let gen = pingGeneration
        helperHealth = .checking
        Task {
            let version = await RealScanSession.ping()
            guard gen == self.pingGeneration, self.helperStatus == .enabled else { return }
            switch version {
            case .some(let v) where v == "DiskProbeHelper \(HelperIdentifiers.helperVersion)":
                self.helperHealth = .ready
            case .some(let v):
                self.helperHealth = .stale(reported: v)
            case .none:
                self.helperHealth = .unreachable
            }
        }
    }

    /// 安装特权助手（系统会弹管理员密码确认）。必须从 .app bundle 运行。
    func installHelper() {
        runHelperOperation(reinstall: false)
    }

    /// 重装特权助手：先注销旧注册再重新注册。
    /// app bundle 被替换后（重新打包/移动位置），launchd/BTM 缓存的旧注册会
    /// 反复 spawn 失败（launchctl 显示 last exit code = 78 EX_CONFIG），
    /// 表现为扫描时"特权助手未确认启动"。重装是唯一治本手段。
    func reinstallHelper() {
        runHelperOperation(reinstall: true)
    }

    private func runHelperOperation(reinstall: Bool) {
        guard !helperOpInProgress else { return }
        helperOpInProgress = true
        helperOpError = nil
        authError = nil

        let service = helperService
        Task {
            // register()/unregister() 是同步阻塞调用（等用户输密码可能数秒），
            // 必须放后台线程，否则管理员确认期间整个 UI 冻结
            let outcome: (ok: Bool, unregisterError: String?, registerError: String?, registerAttempts: Int) =
                await Task.detached(priority: .userInitiated) {
                    var unregisterError: String? = nil
                    if reinstall {
                        do { try await service.unregister() }
                        catch { unregisterError = Self.describe(error) }
                    }
                    var registerError: String? = nil
                    var attempts = 0
                    // BTM 数据库在注销/注册之间偶有传播延迟，失败后短暂等待重试一次
                    for wait in [0, 1_500_000_000] {
                        if attempts > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(wait))
                        }
                        attempts += 1
                        do {
                            try service.register()
                            registerError = nil
                            break
                        } catch {
                            registerError = Self.describe(error)
                        }
                    }
                    return (registerError == nil, unregisterError, registerError, attempts)
                }.value

            helperStatus = helperService.status
            refreshHelperHealth()
            helperOpInProgress = false

            appendDiag("""
            === \(reinstall ? "重装" : "安装")特权助手 ===
            unregisterError: \(outcome.unregisterError ?? "无")
            registerError(尝试 \(outcome.registerAttempts) 次): \(outcome.registerError ?? "无")
            最终 status: \(helperStatus)  health: \(helperHealth)
            """)

            // 结果呈现：成功清掉旧错误；失败区分"未完成"与"已成功但有小问题"
            if outcome.ok {
                if let unregErr = outcome.unregisterError {
                    helperOpError = "已重新注册，但注销旧注册时报错：\(unregErr)。若扫描仍报助手未确认启动，请再重装一次。"
                } else {
                    helperOpError = nil
                }
            } else {
                let detail = outcome.registerError ?? "未知错误"
                if detail.contains("取消") {
                    helperOpError = "已取消，特权助手未做更改。"
                } else if helperStatus == .enabled {
                    helperOpError = "注册更新失败（\(detail)），当前仍是旧注册。请再试一次重装。"
                } else {
                    helperOpError = "\(reinstall ? "重装" : "安装")特权助手失败：\(detail)"
                }
            }
        }
    }

    // MARK: 诊断日志

    /// 安装/重装过程的完整错误写入 Application Support，便于远程排查
    /// （SMAppService 的 localizedDescription 常丢失 domain/code）。
    private static let diagLogURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("install-log.txt")
    }()

    private nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "[\(ns.domain) code=\(ns.code)] \(ns.localizedDescription) userInfo=\(ns.userInfo)"
    }

    private func appendDiag(_ text: String) {
        let stamped = "---- \(Date()) ----\n\(text)\n"
        NSLog("[DiskProbe] %@", text.replacingOccurrences(of: "\n", with: " | "))
        if let handle = try? FileHandle(forWritingTo: Self.diagLogURL) {
            handle.seekToEndOfFile()
            handle.write(stamped.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? stamped.data(using: .utf8)?.write(to: Self.diagLogURL)
        }
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
        helperOpError = nil
        resetStats()

        // 初始化地图
        mapCells = Array(repeating: .unscanned, count: mapColumns * mapRows)

        // 取消旧监听，保证进度流始终只有一个消费者
        listenerTask?.cancel()
        listenerTask = Task {
            refreshHelperStatus()
            guard helperStatus == .enabled else {
                authError = "真实扫描需要先安装特权助手（含 root 授权）。若已安装仍失败，请点「重装特权助手」。"
                await syncState()
                return
            }
            let started = await engine.start(
                disk: d,
                blockSize: Int64(blockSizeKB) * 1024,
                cellCount: mapColumns * mapRows
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
