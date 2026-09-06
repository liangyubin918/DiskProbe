import Foundation
import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers
import DiskProbeCore

// MARK: - 前台也横幅展示通知的 delegate
//（不设 delegate 时 app 在前台，系统会静默吞掉通知——长扫描用户常在别的窗口）

final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // .alert 在 macOS 12+ 自动映射为横幅，11/12 原生支持
        completionHandler([.alert, .sound])
    }
}

// MARK: - 特权助手端到端健康状态

/// 安装状态（自有枚举，屏蔽双路径差异）：
///   macOS 13+ 走 SMAppService；11/12 走 SMJobBless（见 LegacyHelperInstaller）
enum HelperInstallStatus: Equatable {
    case registered         // 已注册/已安装
    case requiresApproval   // macOS 13+：等待用户在系统设置批准
    case notInstalled
    case notFound           // macOS 13+：从非 .app 环境启动等找不到 bundle 的情况
}

/// .registered 只表示"已注册"；重新打包后注册过期时
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
    // 注意：切盘不清数据——扫描结果绑定在 resultsDiskID 上，后台扫描继续进行；
    // 面板按 scanResultsBelong(to:) 决定显示实时结果还是空状态
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

    // 特权助手（13+ 用 SMAppService daemon，11/12 用 SMJobBless）
    @Published var helperStatus: HelperInstallStatus = .notInstalled
    /// 端到端健康：ping 通且版本匹配才算就绪。status=.enabled 只代表"已注册"，
    /// 重新打包后注册过期时 daemon 实际起不来，必须用 ping 区分。
    @Published var helperHealth: HelperHealth = .checking
    /// 安装/重装操作进行中
    @Published var helperOpInProgress = false
    /// 安装/重装操作的结果错误；成功或开始新操作时清空（避免旧错误粘滞显示）
    @Published var helperOpError: String? = nil
    private var pingGeneration = 0

    @available(macOS 13.0, *)
    private var modernService: SMAppService {
        .daemon(plistName: HelperIdentifiers.launchdPlistName)
    }

    /// 读取当前安装状态：13+ 查 SMAppService，11/12 查 SMJobBless 落地文件
    private func currentInstallStatus() -> HelperInstallStatus {
        if #available(macOS 13.0, *) {
            switch modernService.status {
            case .enabled:           return .registered
            case .requiresApproval:  return .requiresApproval
            case .notRegistered:     return .notInstalled
            case .notFound:          return .notFound
            @unknown default:        return .notInstalled
            }
        } else {
            return LegacyHelperInstaller.isInstalled ? .registered : .notInstalled
        }
    }

    // 扫描错误提示
    @Published var authError: String? = nil

    // SMART 请求序号（防陈旧结果覆盖）
    private var smartRequestID = 0

    // 扫描地图格子（引擎随进度事件附带完整快照，UI 只做赋值）
    @Published var mapCells: [MapCell] = []

    // 统计计数（从进度事件的累计 summary 取值）
    @Published var statNormal = 0
    @Published var statWarning = 0
    @Published var statAbnormal = 0
    @Published var statError = 0

    // 地图尺寸：列数固定，行数随盘容量（一格 = 一个逻辑柱面，见 CylinderGrid）
    let mapColumns = 100

    /// 本次扫描期望的地图格数（柱面数），用于校验进度快照
    private var expectedCellCount = 0

    // 进度监听任务（保证任意时刻只有一个消费者，避免事件被瓜分）
    private var listenerTask: Task<Void, Never>? = nil
    private var thresholdSyncTask: Task<Void, Never>? = nil

    let engine = ScanEngine()

    private let notificationDelegate = ForegroundNotificationDelegate()

    // MARK: 检查更新

    @Published var availableUpdate: UpdateInfo? = nil
    private static let updateLastCheckKey = "update.lastCheckAt"

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { await refreshDisks() }
        scheduleUpdateCheck()
        helperStatus = currentInstallStatus()
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

    // MARK: 检查更新

    /// 启动后延迟 3 秒静默检查，成功后 24 小时内不重复
    private func scheduleUpdateCheck() {
        let last = UserDefaults.standard.double(forKey: Self.updateLastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            try? await checkForUpdates(manual: false)
        }
    }

    /// 手动检查（菜单项）失败时弹窗提示；静默检查失败不声不响。
    /// 发现有更新：设置 availableUpdate（主窗口横幅展示）。
    func checkForUpdates(manual: Bool) async throws {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.updateLastCheckKey)
        do {
            guard let update = try await UpdateChecker.fetchLatest() else {
                if manual {
                    let alert = NSAlert()
                    alert.messageText = tr("当前已是最新版本", "You're up to date")
                    alert.informativeText = tr("DiskProbe v\(UpdateChecker.currentVersion) 已是最新版本。",
                                               "DiskProbe v\(UpdateChecker.currentVersion) is the latest version.")
                    alert.runModal()
                }
                return
            }
            availableUpdate = update
            if manual, let url = URL(string: update.url) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            if manual {
                let alert = NSAlert()
                alert.messageText = tr("检查更新失败", "Update check failed")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            } else {
                return
            }
        }
    }

    // MARK: 特权助手

    func refreshHelperStatus() {
        helperStatus = currentInstallStatus()
        refreshHelperHealth()
    }

    /// 已注册时用 ping 验证 daemon 真的能启动、且不是旧版本残留。
    /// 带代数序号：连续刷新时只有最后一次的 ping 结果生效。
    private func refreshHelperHealth() {
        guard helperStatus == .registered else {
            helperHealth = .checking
            return
        }
        pingGeneration += 1
        let gen = pingGeneration
        helperHealth = .checking
        Task {
            let version = await RealScanSession.ping()
            guard gen == self.pingGeneration, self.helperStatus == .registered else { return }
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

    /// 重装特权助手：先卸载旧注册再重新安装。
    /// app bundle 被替换后（重新打包/移动位置），launchd/BTM 缓存的旧注册会
    /// 反复 spawn 失败（launchctl 显示 last exit code = 78 EX_CONFIG），
    /// 表现为扫描时"特权助手未确认启动"。重装是唯一治本手段。
    func reinstallHelper() {
        runHelperOperation(reinstall: true)
    }

    /// 安装/重装操作的结构化结果（双路径共用）
    private struct HelperOpOutcome {
        var ok: Bool
        var unregisterError: String?
        var registerError: String?
        var attempts: Int
    }

    private func runHelperOperation(reinstall: Bool) {
        guard !helperOpInProgress else { return }
        helperOpInProgress = true
        helperOpError = nil
        authError = nil

        Task {
            // 安装调用是同步阻塞的（等用户输密码可能数秒），
            // 必须放后台线程，否则管理员确认期间整个 UI 冻结
            let outcome: HelperOpOutcome =
                await Task.detached(priority: .userInitiated) {
                    if #available(macOS 13.0, *) {
                        return await Self.runModernOperation(reinstall: reinstall)
                    } else {
                        return Self.runLegacyOperation(reinstall: reinstall)
                    }
                }.value

            helperStatus = currentInstallStatus()
            refreshHelperHealth()
            helperOpInProgress = false

            appendDiag("""
            === \(reinstall ? "重装" : "安装")特权助手 ===
            unregisterError: \(outcome.unregisterError ?? "无")
            registerError(尝试 \(outcome.attempts) 次): \(outcome.registerError ?? "无")
            最终 status: \(helperStatus)  health: \(helperHealth)
            """)

            // 结果呈现：成功清掉旧错误；失败区分"未完成"与"已成功但有小问题"
            if outcome.ok {
                if let unregErr = outcome.unregisterError {
                    helperOpError = tr("已重新注册，但注销旧注册时报错：\(unregErr)。若扫描仍报助手未确认启动，请再重装一次。", "Re-registered, but an error occurred while unregistering the old one: \(unregErr). If scans still report the helper did not start, reinstall once more.")
                } else {
                    helperOpError = nil
                }
            } else {
                let detail = outcome.registerError ?? "未知错误"
                if detail.contains("取消") {
                    helperOpError = tr("已取消，特权助手未做更改。", "Cancelled; the privileged helper was not changed.")
                } else if helperStatus == .registered {
                    helperOpError = tr("注册更新失败（\(detail)），当前仍是旧注册。请再试一次重装。", "Registration update failed (\(detail)); the old registration is still in place. Try reinstalling again.")
                } else {
                    helperOpError = tr("\(reinstall ? "重装" : "安装")特权助手失败：\(detail)", "\(reinstall ? "Reinstalling" : "Installing") the privileged helper failed: \(detail)")
                }
            }
        }
    }

    /// macOS 13+：SMAppService 注册/注销。
    /// register()/unregister() 是同步阻塞调用，只能跑在后台线程。
    @available(macOS 13.0, *)
    private nonisolated static func runModernOperation(reinstall: Bool) async -> HelperOpOutcome {
        let service = SMAppService.daemon(plistName: HelperIdentifiers.launchdPlistName)

        var unregisterError: String? = nil
        if reinstall {
            do { try await service.unregister() }
            catch { unregisterError = describe(error) }
        }
        // 迁移清理：从 macOS 11/12 升级上来的用户可能残留 SMJobBless 装的旧 helper，
        // 同名 launchd label 会与 SMAppService daemon 冲突（EX_CONFIG），先移除。
        // 只在用户主动安装/重装（已有密码弹窗预期）时执行，避免凭空弹授权框。
        if LegacyHelperInstaller.isInstalled {
            if let msg = LegacyHelperInstaller.remove() {
                unregisterError = unregisterError ?? "旧版 helper 清理失败：\(msg)"
            }
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
                registerError = describe(error)
            }
        }
        return HelperOpOutcome(ok: registerError == nil,
                               unregisterError: unregisterError,
                               registerError: registerError,
                               attempts: attempts)
    }

    /// macOS 11/12：SMJobBless 安装/卸载（同步调用，同样只跑后台线程）
    private nonisolated static func runLegacyOperation(reinstall: Bool) -> HelperOpOutcome {
        var unregisterError: String? = nil
        if reinstall {
            if let msg = LegacyHelperInstaller.remove() {
                unregisterError = msg
            }
        }
        var registerError: String? = nil
        if let msg = LegacyHelperInstaller.install() {
            registerError = msg
        }
        return HelperOpOutcome(ok: registerError == nil,
                               unregisterError: unregisterError,
                               registerError: registerError,
                               attempts: 1)
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

    /// 当前扫描结果（进度/地图/统计）属于哪块盘（nil = 无结果）。
    /// 切盘不清数据：后台扫描继续，面板按归属决定显示结果还是空状态。
    private(set) var resultsDiskID: String? = nil

    /// 选中盘是否拥有当前扫描结果（决定面板显示实时结果还是空状态）
    func scanResultsBelong(to disk: DiskInfo) -> Bool {
        disk.id == resultsDiskID
    }

    /// 后台正在扫描的盘名（用于切盘后的空状态提示）
    var activeScanDiskName: String? {
        guard scanState == .scanning || scanState == .paused,
              let id = resultsDiskID else { return nil }
        return disks.first(where: { $0.id == id })?.displayName
    }

    // MARK: 保存检测记录

    @Published var saveSuccessMessage: String? = nil

    // MARK: 检测记录对比

    @Published var showRecordDiff = false
    /// 对比结果（items 为空 = 没有任何差异）
    @Published var recordDiff: RecordDiff? = nil
    /// 被对比的历史记录文件（展示其时间/阈值等信息）
    @Published var recordDiffOldFile: ScanRecordFile? = nil
    /// 本次扫描的 meta（展示时间/阈值）
    @Published var recordDiffCurrentMeta: ScanMeta? = nil

    /// 弹出文件选择器，把选中的历史 JSON 报告与本次扫描结果对比
    func compareWithHistory() {
        guard let disk = selectedDisk, scanResultsBelong(to: disk), scanState == .finished else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json]
        panel.message = tr("选择之前导出的 JSON 完整报告，与本次扫描对比新增/加重/持续/恢复的异常块。", "Choose a previously exported JSON report to compare new/worsened/persistent/resolved bad blocks against this scan.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.runRecordCompare(url: url) }
        }
    }

    private func runRecordCompare(url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let old = try ScanRecordExporter.parseJSON(data)
            let snapshot = await engine.exportSnapshot()
            if let oldBSD = old.meta?.bsdName, oldBSD != snapshot.meta?.bsdName {
                authError = tr("所选记录属于 /dev/\(oldBSD)，与当前扫描盘不一致，无法对比。", "That report belongs to /dev/\(oldBSD), not the scanned disk; cannot compare.")
                return
            }
            recordDiff = RecordDiff.compute(old: old.anomalies, new: snapshot.anomalies)
            recordDiffOldFile = old
            recordDiffCurrentMeta = snapshot.meta
            showRecordDiff = true
        } catch {
            authError = tr("无法读取检测记录：\(error.localizedDescription)", "Cannot read the report file: \(error.localizedDescription)")
        }
    }

    /// 扫描完成后导出检测记录（CSV 便于表格分析 / JSON 完整报告）。
    /// 格式选择用自绘 accessory 弹出菜单：macOS 26 起 allowedContentTypes 传
    /// 多个类型不再显示系统"文件格式"下拉框；这里固定单类型 + 自绘菜单，
    /// macOS 11–26 表现一致，也避免老系统上两套下拉框并存。
    func saveScanRecord() {
        guard let disk = selectedDisk, scanResultsBelong(to: disk), scanState == .finished else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "CSV 适合表格分析；JSON 为完整报告（含地图快照）。在下方格式菜单中选择类型。"

        let extensions = ["csv", "json"]
        let baseName = Self.defaultRecordName(disk: disk)
        let formatHandler = FormatPopupHandler { [weak panel] index in
            guard let panel else { return }
            panel.allowedContentTypes = [index == 1 ? UTType.json : UTType.commaSeparatedText]
            panel.nameFieldStringValue = Self.applyingExtension(baseName, ext: extensions[index])
        }

        let label = NSTextField(labelWithString: "格式:")
        label.frame = NSRect(x: 0, y: 6, width: 38, height: 17)
        label.alignment = .right
        let popup = NSPopUpButton(frame: NSRect(x: 42, y: 2, width: 230, height: 26))
        popup.addItems(withTitles: ["CSV（表格分析）", "JSON（完整报告）"])
        popup.target = formatHandler
        popup.action = #selector(FormatPopupHandler.selectionChanged(_:))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        accessory.addSubview(label)
        accessory.addSubview(popup)
        panel.accessoryView = accessory

        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = baseName + ".csv"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // 弹出菜单是格式的唯一事实来源：扩展名与所选格式不符时以菜单为准补正
            let index = popup.indexOfSelectedItem
            let ext = extensions[index]
            let finalURL = url.pathExtension.lowercased() == ext
                ? url
                : url.deletingPathExtension().appendingPathExtension(ext)
            Task { await self?.writeRecord(to: finalURL, format: index == 1 ? .json : .csv) }
        }
    }

    /// 换格式时同步文件名扩展：只替换 .csv/.json 尾缀，其他自定义名直接追加
    private static func applyingExtension(_ name: String, ext: String) -> String {
        let lower = name.lowercased()
        guard lower.hasSuffix(".csv") || lower.hasSuffix(".json") else { return name + "." + ext }
        return (name as NSString).deletingPathExtension + "." + ext
    }

    enum RecordFormat { case csv, json }

    private func writeRecord(to url: URL, format: RecordFormat) async {
        let snapshot = await engine.exportSnapshot()
        do {
            switch format {
            case .json:
                let data = try ScanRecordExporter.json(meta: snapshot.meta, summary: snapshot.summary,
                                                       cells: snapshot.cells, anomalies: snapshot.anomalies)
                try data.write(to: url, options: .atomic)
            case .csv:
                let csv = ScanRecordExporter.csv(meta: snapshot.meta, summary: snapshot.summary,
                                                 cells: snapshot.cells, anomalies: snapshot.anomalies)
                try csv.write(to: url, atomically: true, encoding: .utf8)
            }
            saveSuccessMessage = tr("检测记录已保存：\(url.lastPathComponent)", "Report saved: \(url.lastPathComponent)")
        } catch {
            authError = tr("保存检测记录失败：\(error.localizedDescription)", "Failed to save the report: \(error.localizedDescription)")
        }
    }

    static func defaultRecordName(disk: DiskInfo) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "DiskProbe-\(disk.bsdName)-\(f.string(from: Date()))"
    }

    func startScan(blockSizeKB: Int = 128) {
        guard let d = selectedDisk else { return }
        resultsDiskID = d.id
        progress = nil
        authError = nil
        helperOpError = nil
        saveSuccessMessage = nil
        resetStats()

        // 初始化地图：一格 = 一个逻辑柱面，数量由盘容量决定
        expectedCellCount = CylinderGrid.count(forDiskSizeBytes: d.sizeBytes)
        mapCells = Array(repeating: .unscanned, count: expectedCellCount)

        // 取消旧监听，保证进度流始终只有一个消费者
        listenerTask?.cancel()
        requestScanNotificationPermission()
        listenerTask = Task {
            refreshHelperStatus()
            guard helperStatus == .registered else {
                authError = tr("真实扫描需要先安装特权助手（含 root 授权）。若已安装仍失败，请点「重装特权助手」。",
                            "A real scan requires the privileged helper (with root authorization). If it is installed but still failing, click Reinstall Privileged Helper.")
                await syncState()
                return
            }
            let started = await engine.start(
                disk: d,
                blockSize: Int64(blockSizeKB) * 1024
            )
            guard started else {
                authError = await engine.takeLastAuthError() ?? tr("无法开始扫描。", "Unable to start the scan.")
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
        // 停止 = 本次扫描作废：立即清空进度/地图/统计，不再显示停止前的残留
        listenerTask?.cancel()
        listenerTask = nil
        resetScanDisplay()
        Task {
            await engine.stop()
            await syncState()
        }
    }

    /// 清空扫描显示，并解除"结果属于某块盘"的绑定
    private func resetScanDisplay() {
        resultsDiskID = nil
        progress = nil
        saveSuccessMessage = nil
        expectedCellCount = 0
        mapCells = []
        resetStats()
    }

    private func listenProgress() async {
        for await p in await engine.progress() {
            applyProgress(p)
            await syncState()
        }
        await syncState()
        // 只有自然扫完才通知；用户主动停止（.stopped）不打扰
        if await engine.state == .finished {
            notifyScanFinished()
        }
    }

    // MARK: 扫描完成系统通知

    /// 首次扫描时静默请求通知权限（拒绝过也不再弹，不影响使用）
    private func requestScanNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    private func notifyScanFinished() {
        // 注意不用 activeScanDiskName：它只在 scanning/paused 态有值
        let diskName = disks.first(where: { $0.id == resultsDiskID })?.displayName
            ?? selectedDisk?.displayName ?? tr("磁盘", "disk")
        let content = UNMutableNotificationContent()
        content.title = tr("扫描完成", "Scan Finished")
        if statError > 0 || statAbnormal > 0 {
            content.body = tr("「\(diskName)」发现 \(statError + statAbnormal) 个坏块/异常块，建议立即备份重要数据。",
                              "“\(diskName)” has \(statError + statAbnormal) bad/abnormal blocks — back up important data now.")
            content.sound = .defaultCritical
        } else {
            content.body = tr("「\(diskName)」状态良好，未发现问题。",
                              "“\(diskName)” looks healthy; no issues found.")
        }
        let request = UNNotificationRequest(identifier: "diskprobe.scan.finished.\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: 进度应用

    /// 进度事件是引擎产生的完整快照（地图 + 累计统计），UI 直接取值。
    /// 即使事件被缓冲策略合并丢弃，下一次事件仍是正确状态。
    private func applyProgress(_ p: ScanProgress) {
        progress = p
        if p.mapCells.count == expectedCellCount {
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

/// 保存面板格式菜单的 target/action 转发（AppState 不是 NSObject，不能直接做 target）
private final class FormatPopupHandler: NSObject {
    private let onChange: (Int) -> Void

    init(onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
    }

    @objc func selectionChanged(_ sender: NSPopUpButton) {
        onChange(sender.indexOfSelectedItem)
    }
}
