import SwiftUI
import DiskProbeCore

// MARK: - 根布局：左侧磁盘列表 + 右侧扫描区

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HSplitView {
            // 左侧：磁盘列表
            DiskListView()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            // 右侧：选中盘的扫描地图 + 控制
            VStack(spacing: 0) {
                if let disk = appState.selectedDisk {
                    ScanPanelView(disk: disk)
                } else {
                    EmptyStateView(
                        icon: "externaldrive",
                        title: "未选择磁盘",
                        message: "请从左侧选择要检测的磁盘"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await appState.refreshDisks() }
                } label: {
                    Label("刷新磁盘列表", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

// MARK: - 空状态占位（ContentUnavailableView 的 macOS 11 等价实现）

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.appQuaternary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundColor(.appSecondary)
        }
    }
}
