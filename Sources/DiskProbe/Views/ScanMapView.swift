import SwiftUI
import AppKit
import DiskProbeCore

// MARK: - 扫描地图（DiskGenius 式坏道图：一格 = 一个柱面，随扫描逐格点亮）
//
// 口径：一格 = 一个经典 LBA 逻辑柱面（255 磁头 × 63 扇区/道 × 512B ≈ 8.2MB，
// CylinderGrid；现代盘/SSD 不暴露真实 CHS 几何，DiskGenius 对 LBA 盘也按
// 逻辑柱面展示）。列数固定 100，行数随盘容量增长（500GB ≈ 6 万格）。
//
// 渲染：AppKit 直接绘制**可见区域**，未扫描柱面不画（留空）——扫描推进时
// 只把新增区间置为需要重绘，几十万柱面也只画屏上几千格，主线程开销恒定；
// 浏览/缩放交给 NSScrollView。
// 交互：悬停看柱面详情；滚轮/双指滚动；+- 缩放（格子像素大小）；复位按钮；
//       扫描中自动跟随扫描前沿（用户滚走时暂停跟随，滚回前沿附近即恢复）。

struct ScanMapView: View {
    @EnvironmentObject var appState: AppState

    // 视图状态
    @State private var cellSize: CGFloat = 6
    @State private var userZoomed = false
    @State private var hover: (index: Int, point: CGPoint)? = nil
    @State private var canvasSize: CGSize = .zero

    /// 是否已有任何已扫描柱面（DiskGenius 式：没扫过就不显示色块）
    private var hasScannedCells: Bool {
        appState.mapCells.contains { $0.status != .unscanned }
    }

    private var isScanRunning: Bool {
        appState.scanState == .scanning || appState.scanState == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            progressHeader

            if hasScannedCells {
                mapArea
            } else {
                emptyMapHint
            }

            legend
        }
    }

    // MARK: 地图区域

    private var mapArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CylinderMapRepresentable(
                    cells: appState.mapCells,
                    columns: appState.mapColumns,
                    cellSize: $cellSize,
                    autoFollow: isScanRunning,
                    onViewportResize: { size in
                        canvasSize = size
                        // 用户没手动缩放过时，跟随窗口宽度自适应格子大小
                        if !userZoomed, let fit = fitCellSize(width: size.width) {
                            cellSize = fit
                        }
                    },
                    onHover: { hover = $0 },
                    onZoom: { newSize in
                        userZoomed = true
                        cellSize = newSize
                    }
                )
                .background(Color(NSColor.textBackgroundColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.appSeparator))

                if let h = hover, let cell = cell(at: h.index) {
                    hoverTooltip(cell: cell, index: h.index)
                        .position(x: min(geo.size.width - 90, max(90, h.point.x + 8)),
                                  y: max(30, h.point.y - 42))
                }

                zoomControls
            }
        }
        .frame(minHeight: 220)
    }

    private var zoomControls: some View {
        HStack(spacing: 10) {
            Button { stepZoom(-1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Button { stepZoom(1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button { resetZoom() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(BlurBackground(cornerRadius: 8))
        .padding(8)
        .help(tr("拖动平移，滚轮/双指滚动，捏合或加减缩放格子大小，圆圈按钮复位自适应",
                 "Drag to pan, scroll to browse, pinch or +/- to resize cells, circular button to reset"))
    }

    private func stepZoom(_ direction: Int) {
        // 离散档位，避免浮点缩放糊掉
        let steps: [CGFloat] = [3, 4, 5, 6, 8, 10, 13, 16, 20, 26]
        let current = cellSize
        let next: CGFloat
        if direction > 0 {
            next = steps.first { $0 > current } ?? current
        } else {
            next = steps.last { $0 < current } ?? current
        }
        if next != current {
            userZoomed = true
            cellSize = next
        }
    }

    private func resetZoom() {
        userZoomed = false
        if let fit = fitCellSize(width: canvasSize.width) {
            cellSize = fit
        }
    }

    /// 按地图区宽度自适应：100 列精确铺满整个宽度
    private func fitCellSize(width: CGFloat) -> CGFloat? {
        guard width > 40 else { return nil }
        return max(3, min(26, width / CGFloat(appState.mapColumns)))
    }

    /// 未扫描时的提示（DiskGenius 式：扫到哪亮到哪，此时尚无色块）
    private var emptyMapHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 44))
                .foregroundColor(.appQuaternary)
            Text(isScanRunning
                 ? tr("扫描已开始，色块将随扫描进度逐柱面点亮", "Scanning — cells light up cylinder by cylinder")
                 : tr("点击「开始扫描」开始检测；色块将随扫描进度逐柱面点亮", "Click Start Scan; cells light up cylinder by cylinder as scanning progresses"))
                .font(.callout).foregroundColor(.appSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: 悬停

    private func cell(at index: Int) -> MapCell? {
        guard index >= 0, index < appState.mapCells.count else { return nil }
        return appState.mapCells[index]
    }

    @ViewBuilder private func hoverTooltip(cell: MapCell, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr("柱面 #\(index)", "Cylinder #\(index)"))
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
    }

    // MARK: 顶部进度行

    @ViewBuilder private var progressHeader: some View {
        if let p = appState.progress {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("进度", "Progress")).font(.caption).foregroundColor(.appSecondary)
                    Text(String(format: "%.2f%%", p.fraction * 100))
                        .font(.title3.monospacedDigit().weight(.bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("速度", "Speed")).font(.caption).foregroundColor(.appSecondary)
                    Text(String(format: "%.1f MB/s", p.speedMBps)).font(.callout.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("已用", "Elapsed")).font(.caption).foregroundColor(.appSecondary)
                    Text(formatDuration(p.elapsedSeconds)).font(.callout.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("预计剩余", "Remaining")).font(.caption).foregroundColor(.appSecondary)
                    Text(formatDuration(p.etaSeconds)).font(.callout.monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tr("当前位置", "Position")).font(.caption).foregroundColor(.appSecondary)
                    Text(byteOffset(p.lastBlock.startOffset)).font(.caption.monospacedDigit())
                }
            }
            ProgressView(value: p.fraction).accentColor(progressTint)
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

    // MARK: 图例

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(BlockStatus.allCases, id: \.self) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(statusColor(s))
                        .frame(width: 12, height: 12)
                    Text(s.displayName).font(.caption)
                }
            }
            Spacer()
            Text(tr("每格 = 1 柱面（约 8.2MB）· 淡格 = 未扫描 · 拖动平移，捏合缩放，悬停看详情",
                    "1 cell = 1 cylinder (~8.2MB) · faint cells unscanned · drag to pan, pinch to zoom, hover for details"))
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

// MARK: - NSView 桥接

private struct CylinderMapRepresentable: NSViewRepresentable {
    let cells: [MapCell]
    let columns: Int
    @Binding var cellSize: CGFloat
    let autoFollow: Bool
    let onViewportResize: (CGSize) -> Void
    let onHover: ((index: Int, point: CGPoint)?) -> Void
    /// 捏合缩放在 NSView 内直接生效后，把新值推回 SwiftUI（userZoomed/cellSize）
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let doc = CylinderGridDocumentView()
        doc.columns = columns
        doc.cellSize = cellSize
        doc.onHover = onHover
        doc.onViewportResize = onViewportResize
        doc.onZoom = onZoom
        scroll.documentView = doc
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let doc = scroll.documentView as? CylinderGridDocumentView else { return }
        doc.columns = columns
        doc.autoFollow = autoFollow
        if doc.cellSize != cellSize {
            doc.setCellSize(cellSize)
        }
        doc.apply(cells: cells)
    }
}

// MARK: - 柱面网格文档视图（直接绘制可见区，增量重绘）

private final class CylinderGridDocumentView: NSView {
    private(set) var cells: [MapCell] = []
    var columns = 100
    var cellSize: CGFloat = 6
    var autoFollow = false
    var onHover: ((index: Int, point: CGPoint)?) -> Void = { _ in }
    var onViewportResize: (CGSize) -> Void = { _ in }
    var onZoom: (CGFloat) -> Void = { _ in }

    private var userScrolledAway = false
    private var scrollObserver: NSObjectProtocol? = nil
    private var lastReportedViewport: CGSize = .zero

    override var isFlipped: Bool { true }

    private var rows: Int {
        max(1, (max(cells.count, 1) + columns - 1) / columns)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columns) * cellSize + 2, height: CGFloat(rows) * cellSize + 2)
    }

    // MARK: 数据更新

    /// 应用新快照：只把发生变化的格区间标记为需要重绘。
    /// 扫描顺序推进，变化通常是一段连续区间；即使个别格子被更严重的
    /// 状态改写，diff 也能覆盖。
    func apply(cells newCells: [MapCell]) {
        let old = cells
        cells = newCells

        var lo = Int.max, hi = -1
        let common = min(old.count, newCells.count)
        var i = 0
        // 前缀跳过：扫描顺序推进，前面已定稿的格子绝大多数不变
        while i < common, old[i] == newCells[i] { i += 1 }
        while i < common {
            if old[i] != newCells[i] { lo = min(lo, i); hi = max(hi, i) }
            i += 1
        }
        if newCells.count > old.count {
            lo = min(lo, old.count)
            hi = max(hi, newCells.count - 1)
        }

        if old.count != newCells.count {
            invalidateIntrinsicContentSize()
        }
        if hi >= 0 {
            setNeedsDisplay(rectForCells(lo...hi))
        }
        scheduleSyncPass()
    }

    /// 缩放：保持内容纵向居中比例，避免缩放后跳到别处。
    /// 几何调整延迟到 scheduleSyncPass（见其注释）。
    func setCellSize(_ newSize: CGFloat) {
        guard newSize != cellSize else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? .zero
        pendingZoomCenterRatio = frame.height > 0 ? visible.midY / frame.height : nil
        cellSize = newSize
        invalidateIntrinsicContentSize()
        // 注意不要在这里 needsDisplay：此刻 bounds 还是旧尺寸，若 AppKit
        // 抢在 setFrameSize 前重绘，脏区会越过新格子范围（重绘由
        // performSyncPass 里的 setFrameSize 自动触发，且 draw 已全函数化兜底）
        scheduleSyncPass()
    }

    /// 几何变更（frameSize / 滚动）统一延迟到本轮 SwiftUI 更新结束后执行：
    /// 在 updateNSView 或布局过程中改几何会同步触发 AppKit 布局，重入
    /// SwiftUI 视图更新——实测轻则视图刷新停摆（进度冻结在第一个事件），
    /// 重则视图图损坏直接 SIGSEGV。
    private var syncScheduled = false
    private var pendingZoomCenterRatio: CGFloat? = nil

    private func scheduleSyncPass() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.performSyncPass()
        }
    }

    private func performSyncPass() {
        let desired = intrinsicContentSize
        if frame.size != desired { setFrameSize(desired) }
        if let ratio = pendingZoomCenterRatio {
            pendingZoomCenterRatio = nil
            let visible = enclosingScrollView?.documentVisibleRect ?? .zero
            if frame.height > visible.height, let clip = enclosingScrollView {
                let y = max(0, ratio * frame.height - visible.height / 2)
                clip.contentView.scroll(to: NSPoint(x: 0, y: y))
                clip.reflectScrolledClipView(clip.contentView)
            }
        } else {
            followLeadingIfNeeded()
        }
    }

    private func rectForCells(_ range: ClosedRange<Int>) -> NSRect {
        let firstRow = range.lowerBound / columns
        let lastRow = range.upperBound / columns
        let y = CGFloat(firstRow) * cellSize
        let height = CGFloat(lastRow - firstRow + 1) * cellSize
        return NSRect(x: 0, y: y, width: frame.width, height: height)
    }

    // MARK: 绘制（只画可见区；未扫描柱面不画）

    override func draw(_ dirtyRect: NSRect) {
        // 本函数必须是"全函数"：AppKit 可能在 cellSize 已变、frame 还是旧值
        // 的窗口里（延迟几何模式）用越界脏区调用 draw，dirtyRect 的行列
        // 范围可能完全落在当前格子范围之外——任何区间/下标假设都不成立。
        guard !cells.isEmpty, cellSize > 0, columns > 0 else { return }
        let cols = columns
        let total = cells.count

        let c0 = max(0, min(cols - 1, Int(dirtyRect.minX / cellSize)))
        let c1 = max(0, min(cols - 1, Int(dirtyRect.maxX / cellSize)))
        let maxRow = max(0, (total - 1) / cols)
        let r0 = max(0, min(maxRow, Int(dirtyRect.minY / cellSize)))
        let r1 = max(0, min(maxRow, Int(dirtyRect.maxY / cellSize)))
        guard r0 <= r1, c0 <= c1 else { return }

        let gap: CGFloat = cellSize >= 6 ? 1.0 : 0.5
        let useRounded = cellSize >= 6
        let corner = max(0.5, min(1.5, gap / 2))

        let outline = NSColor.separatorColor.withAlphaComponent(0.16)
        for row in r0...r1 {
            let y = CGFloat(row) * cellSize
            for col in c0...c1 {
                let index = row * cols + col
                guard index < total else { break }
                let cell = cells[index]

                let rect = NSRect(x: CGFloat(col) * cellSize + gap / 2,
                                  y: y + gap / 2,
                                  width: cellSize - gap,
                                  height: cellSize - gap)
                if cell.status == .unscanned {
                    // 未扫描：只画淡轮廓（不是色块），让全盘范围可见
                    outline.setStroke()
                    NSBezierPath(rect: rect).stroke()
                } else {
                    nsColor(cell.status).setFill()
                    if useRounded {
                        NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
                    } else {
                        rect.fill()
                    }
                }
            }
        }
    }

    private func nsColor(_ s: BlockStatus) -> NSColor {
        switch s {
        case .normal:    return .systemGreen
        case .warning:   return .systemYellow
        case .abnormal:  return .systemRed
        case .error:     return NSColor(red: 0.55, green: 0.0, blue: 0.0, alpha: 1)
        case .unscanned: return .clear
        }
    }

    // MARK: 布局 / 视口回调

    override func layout() {
        super.layout()
        guard let clip = enclosingScrollView else { return }
        let size = clip.contentSize
        guard size != lastReportedViewport else { return }
        // 注意：不能在布局过程中同步回调（回调里会设置 SwiftUI @State，
        // 触发布局重入，直接崩溃于 NSApplication _crashOnException），甩到下一轮
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  size == self.enclosingScrollView?.contentSize,
                  size != self.lastReportedViewport else { return }
            self.lastReportedViewport = size
            self.onViewportResize(size)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrollIfNeeded()
    }

    private func observeScrollIfNeeded() {
        guard scrollObserver == nil, let clip = enclosingScrollView else { return }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.noteUserScrolled()
        }
    }

    /// 用户滚动时判断是否离开了扫描前沿附近；离开则暂停自动跟随
    private func noteUserScrolled() {
        guard autoFollow, let clip = enclosingScrollView else { return }
        let visible = clip.documentVisibleRect
        if let rect = leadingRect(), visible.intersects(rect.insetBy(dx: 0, dy: -visible.height)) {
            userScrolledAway = false
        } else {
            userScrolledAway = true
        }
    }

    /// 扫描前沿（最后一个已扫描柱面）所在行
    private func leadingRect() -> NSRect? {
        guard let index = cells.lastIndex(where: { $0.status != .unscanned }) else { return nil }
        let row = index / columns
        return NSRect(x: 0, y: CGFloat(row) * cellSize, width: frame.width, height: cellSize)
    }

    private func followLeadingIfNeeded() {
        guard autoFollow, !userScrolledAway,
              let clip = enclosingScrollView,
              let rect = leadingRect() else { return }
        let visible = clip.documentVisibleRect
        guard !visible.intersects(rect) else { return }
        let target = NSPoint(x: 0, y: max(0, rect.midY - visible.height / 2))
        clip.contentView.scroll(to: target)
        clip.reflectScrolledClipView(clip.contentView)
    }

    // MARK: 捏合缩放 / 拖拽平移
    //
    // 这两个都发生在事件处理上下文（不在 SwiftUI 更新/布局过程中），
    // 直接改几何是安全的；缩放以光标为锚点，缩放前后光标下的内容点不动。

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0, abs(event.magnification) > 0.001 else { return }
        let newSize = max(3, min(26, cellSize * factor))
        guard abs(newSize - cellSize) > 0.01 else { return }
        let anchor = convert(event.locationInWindow, from: nil)
        applyZoomNow(newSize, anchorDocPoint: anchor)
        onZoom(newSize)
    }

    private func applyZoomNow(_ newSize: CGFloat, anchorDocPoint: CGPoint?) {
        let scale = newSize / cellSize
        let visible = enclosingScrollView?.documentVisibleRect ?? .zero
        var newOrigin = visible.origin
        if let a = anchorDocPoint {
            let viewportOffset = CGPoint(x: a.x - visible.minX, y: a.y - visible.minY)
            newOrigin = CGPoint(x: a.x * scale - viewportOffset.x,
                                y: a.y * scale - viewportOffset.y)
        }
        cellSize = newSize
        invalidateIntrinsicContentSize()
        setFrameSize(intrinsicContentSize)
        needsDisplay = true
        if let clip = enclosingScrollView {
            clip.contentView.scroll(to: newOrigin)
            clip.reflectScrolledClipView(clip.contentView)
        }
    }

    private var dragLastPoint: NSPoint? = nil

    override func mouseDown(with event: NSEvent) {
        dragLastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = dragLastPoint, let clip = enclosingScrollView else { return }
        let nowPoint = convert(event.locationInWindow, from: nil)
        let dx = nowPoint.x - last.x
        let dy = nowPoint.y - last.y
        dragLastPoint = nowPoint
        let visible = clip.documentVisibleRect
        var origin = visible.origin
        origin.x = max(0, min(max(0, frame.width - visible.width), origin.x - dx))
        origin.y = max(0, min(max(0, frame.height - visible.height), origin.y - dy))
        clip.contentView.scroll(to: origin)
        clip.reflectScrolledClipView(clip.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragLastPoint = nil
    }

    // MARK: 悬停

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
        let docPoint = convert(event.locationInWindow, from: nil)
        let clipPoint = NSPoint(x: docPoint.x - (enclosingScrollView?.documentVisibleRect.minX ?? 0),
                                y: docPoint.y - (enclosingScrollView?.documentVisibleRect.minY ?? 0))
        let col = Int(docPoint.x / cellSize)
        let row = Int(docPoint.y / cellSize)
        guard col >= 0, col < columns, row >= 0 else { onHover(nil); return }
        let index = row * columns + col
        guard index < cells.count, cells[index].status != .unscanned else {
            onHover(nil)
            return
        }
        onHover((index, CGPoint(x: clipPoint.x, y: clipPoint.y)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }

    deinit {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
