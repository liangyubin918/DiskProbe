import SwiftUI
import DiskProbeCore

// MARK: - 设置窗口：阈值调整（Cmd+, 唤起）

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
        Form {
            Section(header: Text("扫描阈值（毫秒）")) {
                HStack {
                    Text("警告阈值")
                    Spacer()
                    TextField("", text: $warnText, onCommit: commit)
                        .frame(width: 80)
                }
                HStack {
                    Text("异常阈值")
                    Spacer()
                    TextField("", text: $abnormalText, onCommit: commit)
                        .frame(width: 80)
                }
                Text("读取耗时 ≥ 警告阈值标记为黄色；≥ 异常阈值标记为红色；读取失败标记为错误。")
                    .font(.caption).foregroundColor(.appSecondary)
            }
            Section(header: Text("特权助手")) {
                HStack {
                    Text("状态")
                    Spacer()
                    switch appState.helperStatus {
                    case .registered: Text("已注册").foregroundColor(.green)
                    case .requiresApproval: Text("待系统设置批准").foregroundColor(.orange)
                    case .notInstalled: Text("未安装")
                    case .notFound: Text("未找到（请从 .app 启动）")
                    }
                }
                Button("重装特权助手（疑难修复）") { appState.reinstallHelper() }
                Text("重新打包或移动 app 后注册会失效，届时扫描面板会出现重装入口；此处是备用通道。")
                    .font(.caption).foregroundColor(.appSecondary)
            }
            Section(header: Text("支持作者")) {
                Button {
                    showDonate = true
                } label: {
                    Label("赞赏作者", systemImage: "heart.fill")
                        .foregroundColor(.pink)
                }
                Text("DiskProbe 完全免费。如果它帮你找回了数据或排查了问题，欢迎请作者喝杯咖啡。")
                    .font(.caption).foregroundColor(.appSecondary)
                HStack {
                    Text("DiskProbe v\(appVersion)")
                        .font(.caption2.monospacedDigit()).foregroundColor(.appTertiary)
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .navigationTitle("DiskProbe 设置")
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
