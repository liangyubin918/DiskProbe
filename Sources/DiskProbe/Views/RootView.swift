import SwiftUI
import DiskProbeCore

// MARK: - 根布局：左侧磁盘列表 + 右侧扫描区

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let update = appState.availableUpdate {
                UpdateBanner(update: update)
            }
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
                            title: tr("未选择磁盘", "No Disk Selected"),
                            message: tr("请从左侧选择要检测的磁盘", "Choose a disk to inspect from the sidebar")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await appState.refreshDisks() }
                } label: {
                    Label(tr("刷新磁盘列表", "Refresh Disk List"), systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

// MARK: - 新版本横幅

struct UpdateBanner: View {
    let update: UpdateInfo
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.blue)
            Text(tr("DiskProbe v\(update.version) 已发布（当前 v\(UpdateChecker.currentVersion)）",
                    "DiskProbe v\(update.version) is available (current: v\(UpdateChecker.currentVersion))"))
                .font(.callout)
            Button(tr("查看新版", "What's New")) {
                if let url = URL(string: update.url) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            Spacer()
            Button {
                appState.availableUpdate = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.appTertiary)
            }
            .buttonStyle(.plain)
            .help(tr("关闭提醒", "Dismiss"))
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color.blue.opacity(0.10))
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
