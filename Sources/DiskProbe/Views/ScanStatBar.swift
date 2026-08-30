import SwiftUI
import DiskProbeCore

// MARK: - 底部统计栏：各类块计数 + 健康结论

struct ScanStatBar: View {
    /// 查看的盘不是正在扫描/有结果的盘时置 true：显示零值而不是别的盘的计数
    var forcedZero: Bool = false
    @EnvironmentObject var appState: AppState

    private var statNormal: Int { forcedZero ? 0 : appState.statNormal }
    private var statWarning: Int { forcedZero ? 0 : appState.statWarning }
    private var statAbnormal: Int { forcedZero ? 0 : appState.statAbnormal }
    private var statError: Int { forcedZero ? 0 : appState.statError }

    var body: some View {
        HStack(spacing: 18) {
            statItem("正常", count: statNormal,   color: .green)
            statItem("警告", count: statWarning,  color: .yellow)
            statItem("异常", count: statAbnormal, color: .red)
            statItem("错误", count: statError,    color: StatusPalette.errorDark)

            Spacer()

            healthVerdict

            if !forcedZero, appState.scanState == .finished {
                Button { appState.saveScanRecord() } label: {
                    Label("保存检测记录", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .help("导出 CSV（表格分析）或 JSON（完整报告）")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var scannedTotal: Int {
        statNormal + statWarning + statAbnormal + statError
    }

    @ViewBuilder private var healthVerdict: some View {
        if scannedTotal == 0 {
            Text("等待扫描").font(.caption).foregroundColor(.appSecondary)
        } else if statError > 0 {
            label("⚠️ 发现 \(statError) 个读取错误块", .red)
        } else if statAbnormal > 0 {
            label("⚠️ 发现 \(statAbnormal) 个异常块", .red)
        } else if statWarning > 0 {
            label("Δ \(statWarning) 个慢速块", .orange)
        } else {
            label("✓ 暂未发现问题", .green)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(.callout.weight(.bold)).foregroundColor(color)
    }

    private func statItem(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)").font(.callout.monospacedDigit().weight(.bold))
                Text(title).font(.caption2).foregroundColor(.appSecondary)
            }
        }
    }
}
