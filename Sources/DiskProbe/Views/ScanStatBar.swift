import SwiftUI
import DiskProbeCore

// MARK: - 底部统计栏：各类块计数 + 健康结论

struct ScanStatBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 18) {
            statItem("正常", count: appState.statNormal,   color: .green)
            statItem("警告", count: appState.statWarning,  color: .yellow)
            statItem("异常", count: appState.statAbnormal, color: .red)
            statItem("错误", count: appState.statError,    color: StatusPalette.errorDark)

            Spacer()

            healthVerdict
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var scannedTotal: Int {
        appState.statNormal + appState.statWarning + appState.statAbnormal + appState.statError
    }

    @ViewBuilder private var healthVerdict: some View {
        if scannedTotal == 0 {
            Text("等待扫描").font(.caption).foregroundStyle(.secondary)
        } else if appState.statError > 0 {
            label("⚠️ 发现 \(appState.statError) 个读取错误块", .red)
        } else if appState.statAbnormal > 0 {
            label("⚠️ 发现 \(appState.statAbnormal) 个异常块", .red)
        } else if appState.statWarning > 0 {
            label("Δ \(appState.statWarning) 个慢速块", .orange)
        } else {
            label("✓ 暂未发现问题", .green)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(.callout).bold().foregroundStyle(color)
    }

    private func statItem(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)").font(.callout).monospacedDigit().bold()
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
