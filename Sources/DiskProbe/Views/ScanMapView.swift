import SwiftUI
import DiskProbeCore

// MARK: - 扫描地图（核心可视化：色块网格，支持悬停查看 / 缩放 / 平移）

/// 类 DiskGenius 坏道图。固定网格（100×60 格），每格代表一组磁盘块：
///   绿=正常 黄=警告 红=异常 深红=错误 灰=未扫描
///
/// 交互：
///   - 悬停：显示格子编号、块编号与采样耗时
///   - 双指捏合 / +- 按钮：缩放（1×–16×）
///   - 拖动：平移；双击：复位
struct ScanMapView: View {
    @EnvironmentObject var appState: AppState

    // 视图变换状态
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var magBase: CGFloat = 1
    @State private var dragBase: CGSize = .zero
    @State private var hover: (index: Int, point: CGPoint)? = nil

    static let maxZoom: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            progressHeader

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        drawCells(ctx: ctx, size: size)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): updateHover(at: p, size: geo.size)
                        case .ended: hover = nil
                        @unknown default: break
                        }
                    }
                    .gesture(dragGesture(size: geo.size))
                    .simultaneousGesture(magnifyGesture(size: geo.size))
                    .onTapGesture(count: 2) { resetView(size: geo.size) }

                    if let h = hover, let cell = cell(at: h.index) {
                        hoverTooltip(cell: cell, index: h.index)
                            .position(x: min(geo.size.width - 90, max(90, h.point.x + 8)),
                                      y: max(30, h.point.y - 42))
                    }

                    // 缩放控件
                    HStack(spacing: 10) {
                        Button { stepZoom(-1, size: geo.size) } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        Text("\(Int((zoom * 100).rounded()))%")
                            .font(.caption).monospacedDigit()
                            .frame(minWidth: 40)
                        Button { stepZoom(1, size: geo.size) } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        Button { resetView(size: geo.size) } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .padding(8)
                    .help("双指捏合或加减缩放，拖动平移，双击复位")
                }
            }
            .frame(minHeight: 220)

            legend
        }
    }

    // MARK: 视图变换

    private func viewTransform(size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    private func contentPoint(from p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - (size.width / 2 + offset.width)) / zoom + size.width / 2,
                y: (p.y - (size.height / 2 + offset.height)) / zoom + size.height / 2)
    }

    private func clampOffset(size: CGSize) {
        let maxX = (zoom - 1) * size.width / 2
        let maxY = (zoom - 1) * size.height / 2
        offset = CGSize(width: min(maxX, max(-maxX, offset.width)),
                        height: min(maxY, max(-maxY, offset.height)))
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard zoom > 1 else { return }
                offset = CGSize(width: dragBase.width + v.translation.width,
                                height: dragBase.height + v.translation.height)
                clampOffset(size: size)
            }
            .onEnded { _ in dragBase = offset }
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                zoom = min(Self.maxZoom, max(1, magBase * v))
                clampOffset(size: size)
            }
            .onEnded { _ in magBase = zoom }
    }

    private func stepZoom(_ direction: Int, size: CGSize) {
        magBase = zoom
        zoom = min(Self.maxZoom, max(1, zoom * (direction > 0 ? 2 : 0.5)))
        clampOffset(size: size)
        magBase = zoom
    }

    private func resetView(size: CGSize) {
        zoom = 1
        magBase = 1
        offset = .zero
        dragBase = .zero
    }

    // MARK: 悬停

    private func updateHover(at p: CGPoint, size: CGSize) {
        let cols = appState.mapColumns
        let total = appState.mapCells.count
        guard total > 0, cols > 0 else { hover = nil; return }
        let rows = (total + cols - 1) / cols
        let cp = contentPoint(from: p, size: size)
        let col = Int(cp.x / (size.width / CGFloat(cols)))
        let row = Int(cp.y / (size.height / CGFloat(rows)))
        guard row >= 0, row < rows, col >= 0, col < cols else { hover = nil; return }
        let idx = row * cols + col
        guard idx < total else { hover = nil; return }
        hover = (idx, p)
    }

    private func cell(at index: Int) -> MapCell? {
        guard index >= 0, index < appState.mapCells.count else { return nil }
        return appState.mapCells[index]
    }

    @ViewBuilder private func hoverTooltip(cell: MapCell, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("格子 #\(index)")
                .font(.caption).bold().monospacedDigit()
            if cell.blockIndex >= 0 {
                Text("块 #\(cell.blockIndex)")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(statusColor(cell.status)).frame(width: 7, height: 7)
                    Text("\(String(format: "%.1f", cell.elapsedMs)) ms · \(cell.status.rawValue)")
                        .font(.caption2).monospacedDigit()
                }
            } else {
                Text("未扫描").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
        .fixedSize()
        .allowsHitTesting(false)
        .transition(.opacity)
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
            Text("悬停查看格子详情，双指捏合缩放，拖动平移，双击复位")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Canvas 绘制

    private func drawCells(ctx ctxIn: GraphicsContext, size: CGSize) {
        var ctx = ctxIn
        let cells = appState.mapCells
        let cols = appState.mapColumns
        guard !cells.isEmpty, cols > 0 else { return }
        let rows = (cells.count + cols - 1) / cols
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        // DiskGenius 式格间隙（内容坐标系，放大时可见）
        let gap = min(2.0, max(0.5, cw * 0.10))

        ctx.concatenate(viewTransform(size: size))

        for (i, cell) in cells.enumerated() {
            let row = i / cols, col = i % cols
            let rect = CGRect(x: CGFloat(col) * cw + gap / 2, y: CGFloat(row) * ch + gap / 2,
                              width: cw - gap, height: ch - gap)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, gap / 2)),
                     with: .color(statusColor(cell.status)))
        }

        // 悬停格高亮描边（线宽除以 zoom 保持屏幕恒定）
        if let h = hover {
            let row = h.index / cols, col = h.index % cols
            let rect = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch, width: cw, height: ch)
            ctx.stroke(Path(rect), with: .color(.white.opacity(0.85)), lineWidth: 2 / zoom)
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
