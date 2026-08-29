import SwiftUI
import DiskProbeCore

// MARK: - 设置窗口：阈值调整（Cmd+, 唤起）

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("扫描阈值（毫秒）") {
                LabeledContent("警告阈值") {
                    TextField("", value: $thresholdWarnMs, format: .number)
                        .frame(width: 80)
                        .onSubmit { commit() }
                }
                LabeledContent("异常阈值") {
                    TextField("", value: $thresholdAbnormalMs, format: .number)
                        .frame(width: 80)
                        .onSubmit { commit() }
                }
                Text("读取耗时 ≥ 警告阈值标记为黄色；≥ 异常阈值标记为红色；读取失败标记为错误。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
        .navigationTitle("DiskProbe 设置")
        .onAppear {
            // 打开窗口时与当前生效阈值同步（阈值已通过 UserDefaults 持久化）
            thresholdWarnMs = appState.thresholds.warnMs
            thresholdAbnormalMs = appState.thresholds.abnormalMs
        }
    }

    // @AppStorage 持久化到 UserDefaults，AppState 启动时读同一组 key
    @AppStorage("scan.warnMs") private var thresholdWarnMs: Double = 100
    @AppStorage("scan.abnormalMs") private var thresholdAbnormalMs: Double = 500

    private func commit() {
        // 保证 warn < abnormal
        let w = max(1, thresholdWarnMs)
        let a = max(w + 1, thresholdAbnormalMs)
        thresholdWarnMs = w
        thresholdAbnormalMs = a
        appState.thresholds = ScanThresholds(warnMs: w, abnormalMs: a)
    }
}
