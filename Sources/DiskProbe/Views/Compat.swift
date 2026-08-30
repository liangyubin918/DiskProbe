import SwiftUI
import AppKit

// MARK: - macOS 11 兼容层
//
// 最低部署目标为 macOS 11，这里集中提供新系统 SwiftUI 能力的等价实现，
// 视图代码统一走这些入口，避免散落 #available 分支：
//   - .foregroundStyle(.secondary) 等（12+/14+）→ 层级文字色的 NSColor 等价
//   - .ultraThinMaterial（12+）→ NSVisualEffectView 毛玻璃
//   - Canvas / onContinuousHover（12+/14+）→ 见 ScanMapView 的 Path + 追踪区实现

extension Color {
    /// 对应 .foregroundStyle(.secondary)：次级文字色
    static let appSecondary = Color(NSColor.secondaryLabelColor)
    /// 对应 .foregroundStyle(.tertiary)：三级文字色
    static let appTertiary = Color(NSColor.tertiaryLabelColor)
    /// 对应 .foregroundStyle(.quaternary)：四级文字色
    static let appQuaternary = Color(NSColor.quaternaryLabelColor)
    /// 对应 .stroke(.separator)：分隔线色
    static let appSeparator = Color(NSColor.separatorColor)
}

/// 对应 .background(.ultraThinMaterial, in: shape)：窗口内毛玻璃背景
struct BlurBackground: View {
    var cornerRadius: CGFloat

    var body: some View {
        VisualEffect()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.appSeparator))
    }

    private struct VisualEffect: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = .underWindowBackground
            v.blendingMode = .withinWindow
            v.state = .active
            return v
        }
        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }
}
