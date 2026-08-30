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
            statItem(tr("正常", "Normal"), count: statNormal,   color: .green)
            statItem(tr("警告", "Warning"), count: statWarning,  color: .yellow)
            statItem(tr("异常", "Abnormal"), count: statAbnormal, color: .red)
            statItem(tr("错误", "Error"), count: statError,    color: StatusPalette.errorDark)

            Spacer()

            healthVerdict

            if !forcedZero, appState.scanState == .finished {
                Button { appState.compareWithHistory() } label: {
                    Label(tr("对比历史记录", "Compare History"), systemImage: "arrow.left.arrow.right.square")
                }
                .controlSize(.small)
                .help(tr("导入之前导出的 JSON 报告，对比两次扫描的新增/加重/持续/恢复异常块",
                         "Import a previously exported JSON report and compare new/worsened/persistent/resolved bad blocks"))
                Button { appState.saveScanRecord() } label: {
                    Label(tr("保存检测记录", "Save Report"), systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .help(tr("导出 CSV（表格分析）或 JSON（完整报告）",
                         "Export CSV (for spreadsheets) or JSON (full report)"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var scannedTotal: Int {
        statNormal + statWarning + statAbnormal + statError
    }

    @ViewBuilder private var healthVerdict: some View {
        if scannedTotal == 0 {
            Text(tr("等待扫描", "Waiting to scan")).font(.caption).foregroundColor(.appSecondary)
        } else if statError > 0 {
            label(tr("⚠️ 发现 \(statError) 个读取错误块", "⚠️ \(statError) blocks failed to read"), .red)
        } else if statAbnormal > 0 {
            label(tr("⚠️ 发现 \(statAbnormal) 个异常块", "⚠️ \(statAbnormal) abnormal blocks"), .red)
        } else if statWarning > 0 {
            label(tr("Δ \(statWarning) 个慢速块", "Δ \(statWarning) slow blocks"), .orange)
        } else {
            label(tr("✓ 暂未发现问题", "✓ No issues found so far"), .green)
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
