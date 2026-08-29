import SwiftUI
import DiskProbeCore

// MARK: - 扫描地图（核心可视化：色块网格）

/// 类似 DiskGenius 的坏道图。固定网格（100×60 格），每格代表一组磁盘块，
/// 颜色取该组中最严重的状态：
///   绿=正常 黄=警告 红=异常 深红=错误 灰=未扫描
///
/// 实现：Canvas 一次绘制全部格子（固定 6000 格，性能好），
/// AppState 每收到一个进度事件就增量更新一格（见 AppState.updateMap）。
struct ScanMapView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            progressHeader

            GeometryReader { geo in
                Canvas { ctx, size in
                    drawCells(ctx: ctx, size: size)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            .frame(minHeight: 220)

            legend
        }
    }

    // MARK: 顶部进度行
    @ViewBuilder private var progressHeader: some View {
        if let p = appState.progress {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("进度").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f%%", p.fraction * 100)).font(.title3).monospacedDigit().bold()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("速度").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f MB/s", p.speedMBps)).font(.callout).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("已用").font(.caption).foregroundStyle(.secondary)
                    Text(formatDuration(p.elapsedSeconds)).font(.callout).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("预计剩余").font(.caption).foregroundStyle(.secondary)
                    Text(formatDuration(p.etaSeconds)).font(.callout).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("当前位置").font(.caption).foregroundStyle(.secondary)
                    Text(byteOffset(p.lastBlock.startOffset)).font(.caption).monospacedDigit()
                }
            }
            ProgressView(value: p.fraction).tint(progressTint)
        } else {
            HStack {
                Image(systemName: "rectangle.grid.3x3")
                let idleLike = appState.scanState == .idle || appState.scanState == .stopped
                    || appState.scanState == .error || appState.scanState == .finished
                Text(idleLike ? "点击「开始扫描」开始检测" : "准备中…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }

    // MARK: 图例
    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(BlockStatus.allCases, id: \.self) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(statusColor(s))
                        .frame(width: 12, height: 12)
                    Text(s.rawValue).font(.caption)
                }
            }
            Spacer()
        }
    }

    // MARK: Canvas 绘制（固定网格）
    private func drawCells(ctx: GraphicsContext, size: CGSize) {
        let cells = appState.mapCells
        let cols = appState.mapColumns
        guard !cells.isEmpty, cols > 0 else { return }

        let rows = (cells.count + cols - 1) / cols
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)

        // 单 pass 绘制全部格子；未扫描的格子自然为灰色
        for (i, status) in cells.enumerated() {
            let row = i / cols
            let col = i % cols
            let rect = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch,
                              width: cw, height: ch)
            ctx.fill(Path(rect), with: .color(statusColor(status)))
        }
    }

    // MARK: 颜色 / 文案 helpers
    private func statusColor(_ s: BlockStatus) -> Color {
        switch s {
        case .normal:    return .green
        case .warning:   return .yellow
        case .abnormal:  return .red
        case .error:     return StatusPalette.errorDark
        case .unscanned: return StatusPalette.unscanned
        }
    }

    private var progressTint: Color {
        if appState.statError > 0 || appState.statAbnormal > 0 { return .red }
        if appState.statWarning > 0 { return .yellow }
        return .green
    }

    private func byteOffset(_ b: Int64) -> String {
        ByteSizeFormatter.string(from: b)
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let s = Int(sec.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - 状态色板

enum StatusPalette {
    static let errorDark   = Color(red: 0.55, green: 0.0, blue: 0.0)
    static let unscanned   = Color(nsColor: .tertiaryLabelColor).opacity(0.35)
}
