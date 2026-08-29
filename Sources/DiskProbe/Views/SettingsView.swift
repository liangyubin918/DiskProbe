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
    }

    // 用 @State 做输入缓冲，提交时再写回 thresholds
    @State private var thresholdWarnMs: Double = 100
    @State private var thresholdAbnormalMs: Double = 500

    private func commit() {
        // 保证 warn < abnormal
        let w = max(1, thresholdWarnMs)
        let a = max(w + 1, thresholdAbnormalMs)
        appState.thresholds = ScanThresholds(warnMs: w, abnormalMs: a)
    }
}
