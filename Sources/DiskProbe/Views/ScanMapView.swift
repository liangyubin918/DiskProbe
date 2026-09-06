import SwiftUI
import AppKit
import DiskProbeCore

// MARK: - 扫描地图（核心可视化：色块网格，支持悬停查看 / 缩放 / 平移）

/// 类 DiskGenius 坏道图。固定网格（100×60 格），每格代表一组磁盘块：
///   绿=正常 黄=警告 红=异常 深红=错误 灰=未扫描
///
/// 交互：
///   - 悬停：显示格子编号、块编号与采样耗时
///   - 触控板二指滑动 / 滚轮：平移（本地事件监听，不遮挡任何 SwiftUI 手势）
///   - 双指捏合 / +- 按钮：缩放（1×–16×）；鼠标拖动平移；双击：复位
///
/// macOS 11 兼容说明：原实现依赖 Canvas / onContinuousHover / onChange（12+/14+），
/// 现统一改为 Path 绘制 + NSView 追踪区 + 布局回调，所有系统版本共用一条代码路径。
struct ScanMapView: View {
    @EnvironmentObject var appState: AppState

    // 视图变换状态
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var magBase: CGFloat = 1
    @State private var dragBase: CGSize = .zero
    @State private var hover: (index: Int, point: CGPoint)? = nil
    @State private var lastCursor: CGPoint? = nil   // 最后光标位置（画布局部坐标）
    @State private var canvasSize: CGSize = .zero

    // 二指滚动平移：宿主 NSView 仅用于标定地图区域的窗口坐标；
    // scrollWheel 事件由本地监听器截获，事件不经过它，因此不遮挡 SwiftUI 手势
    private final class ScrollRegionRef {
        weak var view: NSView?
    }
    @State private var scrollRegion = ScrollRegionRef()
    @State private var scrollMonitor: Any? = nil

    static let maxZoom: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            progressHeader

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // 地图区域宿主：窗口坐标标定（二指平移用）+ 悬停追踪 + 尺寸回调
                    MapHostView(
                        onAttach: { scrollRegion.view = $0 },
                        onResize: { canvasSize = $0 },
                        onHoverMoved: { point in
                            if let point = point {
                                updateHover(at: point, size: geo.size)
                            } else {
                                hover = nil
                            }
                        }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)

                    mapCellsView(size: geo.size)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.appSeparator))
                        .contentShape(Rectangle())
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
                            .font(.caption.monospacedDigit())
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
                    .background(BlurBackground(cornerRadius: 8))
                    .help(tr("双指滑动平移，捏合或加减缩放，双击复位",
                             "Two-finger scroll to pan, pinch or +/- to zoom, double-click to reset"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                }
                .onAppear { installScrollPan() }
                .onDisappear { removeScrollPan() }
            }
            .frame(minHeight: 220)

            legend
        }
    }

    // MARK: 地图绘制（Path 版，Canvas 的 macOS 11 等价实现）

    /// 按状态分组构建路径，应用视图变换后逐层填充。
    /// Path 先在"内容坐标系"里构建（与旧 Canvas 相同的坐标），再 applying 变换，
    /// 因此描边线宽保持屏幕恒定（旧实现用 lineWidth 2/zoom 达到同样效果）。
    private func mapCellsView(size: CGSize) -> some View {
        let transform = viewTransform(size: size)
        return ZStack {
            ForEach(statusPaths(size: size, transform: transform)) { group in
                if group.status == .unscanned {
                    // 淡轮廓表示未扫描（DiskGenius 式淡格），不再整屏灰色色块
                    group.path.stroke(Color.appSeparator.opacity(0.28), lineWidth: 0.7)
                } else {
                    group.path.fill(group.color)
                }
            }
            if let h = hover {
                hoverOutline(index: h.index, size: size)
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
            }
        }
    }

    private struct StatusPath: Identifiable {
        let status: BlockStatus
        let path: Path
        let color: Color
        var id: BlockStatus { status }
    }

    private func statusPaths(size: CGSize, transform: CGAffineTransform) -> [StatusPath] {
        let cells = appState.mapCells
        let cols = appState.mapColumns
        guard !cells.isEmpty, cols > 0 else { return [] }
        let rows = (cells.count + cols - 1) / cols
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        // DiskGenius 式格间隙（内容坐标系，放大时可见）
        let gap = min(2.0, max(0.5, cw * 0.10))
        let corner = min(1.5, gap / 2)

        var grouped: [BlockStatus: Path] = [:]
        for (i, cell) in cells.enumerated() {
            let row = i / cols, col = i % cols
            let rect = CGRect(x: CGFloat(col) * cw + gap / 2, y: CGFloat(row) * ch + gap / 2,
                              width: cw - gap, height: ch - gap)
            grouped[cell.status, default: Path()]
                .addRoundedRect(in: rect, cornerSize: CGSize(width: corner, height: corner))
        }

        // 固定按 BlockStatus 顺序输出，保证 ForEach 身份稳定
        return BlockStatus.allCases.compactMap { status in
            guard var path = grouped[status] else { return nil }
            path = path.applying(transform)
            return StatusPath(status: status, path: path, color: statusColor(status))
        }
    }

    /// 悬停格高亮描边（线宽不随缩放变化）
    private func hoverOutline(index: Int, size: CGSize) -> Path {
        let cols = appState.mapColumns
        let total = appState.mapCells.count
        guard cols > 0, total > 0 else { return Path() }
        let rows = (total + cols - 1) / cols
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        let row = index / cols, col = index % cols
        let rect = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch, width: cw, height: ch)
        return Path(rect).applying(viewTransform(size: size))
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
                refreshHover()
            }
            .onEnded { _ in dragBase = offset }
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                zoom = min(Self.maxZoom, max(1, magBase * v))
                clampOffset(size: size)
                refreshHover()
            }
            .onEnded { _ in magBase = zoom }
    }

    private func stepZoom(_ direction: Int, size: CGSize) {
        magBase = zoom
        zoom = min(Self.maxZoom, max(1, zoom * (direction > 0 ? 2 : 0.5)))
        clampOffset(size: size)
        magBase = zoom
        refreshHover()
    }

    private func resetView(size: CGSize) {
        zoom = 1
        magBase = 1
        offset = .zero
        dragBase = .zero
        refreshHover()
    }

    // MARK: 二指滑动 / 滚轮平移 + 悬停追踪宿主

    /// 地图区域宿主 NSView，负责三件依赖"自身几何"的事：
    ///   1. 给二指滚动平移提供窗口坐标标定
    ///   2. 追踪区上报鼠标移动（onContinuousHover 的 macOS 11 等价实现）
    ///   3. 尺寸变化回调（onChange(of: geo.size) 的 macOS 11 等价实现）
    private struct MapHostView: NSViewRepresentable {
        let onAttach: (NSView) -> Void
        let onResize: (CGSize) -> Void
        let onHoverMoved: (CGPoint?) -> Void

        func makeNSView(context: Context) -> MapHostNSView {
            let v = MapHostNSView()
            onAttach(v)
            v.onResize = onResize
            v.onHoverMoved = onHoverMoved
            return v
        }
        func updateNSView(_ nsView: MapHostNSView, context: Context) {
            nsView.onResize = onResize
            nsView.onHoverMoved = onHoverMoved
        }
    }

    private final class MapHostNSView: NSView {
        var onResize: ((CGSize) -> Void)? = nil
        var onHoverMoved: ((CGPoint?) -> Void)? = nil

        // SwiftUI 内容左上角为原点，翻转坐标系保持一致
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            onResize?(bounds.size)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            onHoverMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHoverMoved?(nil)
        }
    }

    /// 本地监听 scrollWheel：光标在地图区域内且已放大时截获用于平移，
    /// 其余事件原样放行。宿主 NSView 只提供命中范围，不参与事件分发，
    /// 因此悬停 / 捏合 / 拖动 / 双击等 SwiftUI 手势完全不受影响。
    private func installScrollPan() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard zoom > 1, let view = scrollRegion.view, view.window != nil else { return event }
            let local = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(local) else { return event }
            // 触控板二指滑动：纵向按"抓取内容"方向（手指向哪地图向哪），
            // 横向按标准滚动方向（右滑内容左移，左滑内容右移）
            offset = CGSize(width: offset.width + event.scrollingDeltaX,
                            height: offset.height + event.scrollingDeltaY)
            clampOffset(size: canvasSize)
            dragBase = offset
            refreshHover()
            return nil
        }
    }

    private func removeScrollPan() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: 悬停

    /// 平移/缩放后地图在光标下滑动，用最后光标位置重算悬停格，
    /// 保证移动过程中与停止后 tooltip 都实时更新
    private func refreshHover() {
        guard let p = lastCursor, canvasSize != .zero else { return }
        updateHover(at: p, size: canvasSize)
    }

    private func updateHover(at p: CGPoint, size: CGSize) {
        lastCursor = p
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
            Text(tr("格子 #\(index)", "Cell #\(index)"))
                .font(.caption.monospacedDigit().weight(.bold))
            if cell.blockIndex >= 0 {
                Text(tr("块 #\(cell.blockIndex)", "Block #\(cell.blockIndex)"))
                    .font(.caption2.monospacedDigit()).foregroundColor(.appSecondary)
                HStack(spacing: 4) {
                    Circle().fill(statusColor(cell.status)).frame(width: 7, height: 7)
                    Text("\(String(format: "%.1f", cell.elapsedMs)) ms · \(cell.status.displayName)")
                        .font(.caption2.monospacedDigit())
                }
            } else {
                Text(tr("未扫描", "Unscanned")).font(.caption2).foregroundColor(.appSecondary)
            }
        }
        .padding(7)
        .background(BlurBackground(cornerRadius: 7))
        .fixedSize()
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: 顶部进度行

    @ViewBuilder private var progressHeader: some View {
        if let p = appState.progress {
            HStack(alignment: .lastTextBaseline, spacing: 22) {
                Text(String(format: "%.2f%%", p.fraction * 100))
                    .font(.system(size: 28, weight: .bold).monospacedDigit())
                HStack(spacing: 18) {
                    progressMetric(tr("速度", "Speed"), String(format: "%.1f MB/s", p.speedMBps))
                    progressMetric(tr("已用", "Elapsed"), formatDuration(p.elapsedSeconds))
                    progressMetric(tr("预计剩余", "Remaining"), formatDuration(p.etaSeconds))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tr("当前位置", "Position")).font(.caption).foregroundColor(.appSecondary)
                    Text(byteOffset(p.lastBlock.startOffset)).font(.caption.monospacedDigit())
                }
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appSeparator.opacity(0.5))
                GeometryReader { geo in
                    Capsule().fill(progressTint)
                        .frame(width: max(6, geo.size.width * CGFloat(p.fraction)))
                }
            }
            .frame(height: 6)
            .padding(.vertical, 4)
        } else {
            HStack {
                Image(systemName: "rectangle.grid.3x3")
                let idleLike = appState.scanState == .idle || appState.scanState == .stopped
                    || appState.scanState == .error || appState.scanState == .finished
                Text(idleLike ? tr("点击「开始扫描」开始检测", "Click Start Scan to begin")
                              : tr("准备中…", "Preparing…"))
                    .foregroundColor(.appSecondary)
                Spacer()
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }

    private func progressMetric(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundColor(.appSecondary)
            Text(v).font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: 图例

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(BlockStatus.allCases, id: \.self) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(s == .unscanned ? Color.clear : statusColor(s))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(s == .unscanned ? Color.appSeparator : Color.clear, lineWidth: 1)
                        )
                        .frame(width: 12, height: 12)
                    Text(s.displayName).font(.caption)
                }
            }
            Spacer()
            Text(tr("悬停查看格子详情，双指滑动平移，捏合缩放，双击复位",
                    "Hover for cell details · two-finger scroll to pan · pinch to zoom · double-click to reset"))
                .font(.caption2).foregroundColor(.appTertiary)
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
    static let unscanned   = Color(NSColor.tertiaryLabelColor).opacity(0.35)
}
