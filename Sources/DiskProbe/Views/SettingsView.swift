import SwiftUI
import DiskProbeCore

// MARK: - 设置窗口：阈值调整（Cmd+, 唤起）
//
// 不用 Form/Section：macOS 15 起 Settings 场景里的 Form 会按理想宽度排版内容列，
// 长文案把表单撑到远超窗口宽度，内容整体溢出窗口两侧被裁（GitHub issue #2）。
// 这里手工排版（标题 + 标签/控件行 + 说明），各系统版本渲染一致。

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showDonate = false

    // @AppStorage 持久化到 UserDefaults，AppState 启动时读同一组 key。
    // TextField 的 value:format: 初始化器是 macOS 12+，这里退回 text: 绑定，
    // 回车（onCommit）时解析并提交。
    @AppStorage("scan.warnMs") private var thresholdWarnMs: Double = 100
    @AppStorage("scan.abnormalMs") private var thresholdAbnormalMs: Double = 500
    @State private var warnText: String = "100"
    @State private var abnormalText: String = "500"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(tr("扫描阈值（毫秒）", "Scan Thresholds (ms)"))
            keyValueRow(tr("警告阈值", "Warning above")) {
                TextField("", text: $warnText, onCommit: commit)
                    .frame(width: 80)
            }
            keyValueRow(tr("异常阈值", "Abnormal above")) {
                TextField("", text: $abnormalText, onCommit: commit)
                    .frame(width: 80)
            }
            caption(tr("读取耗时 ≥ 警告阈值标记为黄色；≥ 异常阈值标记为红色；读取失败标记为错误。",
                       "Reads at or above the warning threshold are marked yellow; at or above the abnormal threshold, red; failed reads are marked as errors."))

            sectionDivider

            sectionHeader(tr("特权助手", "Privileged Helper"))
            keyValueRow(tr("状态", "Status")) {
                switch appState.helperStatus {
                case .registered: Text(tr("已注册", "Registered")).foregroundColor(.green)
                case .requiresApproval: Text(tr("待系统设置批准", "Awaiting approval")).foregroundColor(.orange)
                case .notInstalled: Text(tr("未安装", "Not installed"))
                case .notFound: Text(tr("未找到（请从 .app 启动）", "Not found (launch from the .app)"))
                }
            }
            Button(tr("重装特权助手（疑难修复）", "Reinstall Privileged Helper (Advanced Repair)")) { appState.reinstallHelper() }
                .padding(.bottom, 10)
            caption(tr("重新打包或移动 app 后注册会失效，届时扫描面板会出现重装入口；此处是备用通道。",
                       "Re-registering expires when the app is rebuilt or moved; the scan panel will offer a reinstall entry then. This is a fallback."))

            sectionDivider

            sectionHeader(tr("支持作者", "Support the Author"))
            Button {
                showDonate = true
            } label: {
                Label(tr("赞赏作者", "Donate"), systemImage: "heart.fill")
                    .foregroundColor(.pink)
            }
            .padding(.bottom, 10)
            caption(tr("DiskProbe 完全免费。如果它帮你找回了数据或排查了问题，欢迎请作者喝杯咖啡。",
                       "DiskProbe is completely free. If it helped you recover data or diagnose a problem, consider buying the author a coffee."))
            Text("DiskProbe v\(appVersion)")
                .font(.caption2.monospacedDigit()).foregroundColor(.appTertiary)
        }
        .padding(20)
        .frame(width: 420)
        .navigationTitle(tr("DiskProbe 设置", "DiskProbe Settings"))
        .sheet(isPresented: $showDonate) {
            DonateSheet()
        }
        .onAppear {
            // 打开窗口时与当前生效阈值同步（阈值已通过 UserDefaults 持久化）
            thresholdWarnMs = appState.thresholds.warnMs
            thresholdAbnormalMs = appState.thresholds.abnormalMs
            warnText = String(format: "%.0f", thresholdWarnMs)
            abnormalText = String(format: "%.0f", thresholdAbnormalMs)
        }
    }

    // MARK: 排版组件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .padding(.bottom, 10)
    }

    private func keyValueRow<Content: View>(_ label: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
        .padding(.bottom, 10)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundColor(.appSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.appSeparator)
            .frame(height: 1)
            .padding(.vertical, 12)
    }

    private func commit() {
        // 保证 warn < abnormal；非法输入回退到当前生效值
        guard let w = Double(warnText), let a = Double(abnormalText) else {
            warnText = String(format: "%.0f", thresholdWarnMs)
            abnormalText = String(format: "%.0f", thresholdAbnormalMs)
            return
        }
        let clampedWarn = max(1, w)
        let clampedAbnormal = max(clampedWarn + 1, a)
        thresholdWarnMs = clampedWarn
        thresholdAbnormalMs = clampedAbnormal
        appState.thresholds = ScanThresholds(warnMs: clampedWarn, abnormalMs: clampedAbnormal)
        warnText = String(format: "%.0f", clampedWarn)
        abnormalText = String(format: "%.0f", clampedAbnormal)
    }
}
