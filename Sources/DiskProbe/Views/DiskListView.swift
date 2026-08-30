import SwiftUI
import DiskProbeCore

// MARK: - 磁盘列表（左侧栏）

struct DiskListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $appState.selectedDisk) {
                // 分组：外置 / 内置 / 其他
                let external = appState.disks.filter { $0.isExternalPhysical }
                let internal_ = appState.disks.filter { $0.isInternal }
                let others = appState.disks.filter { !$0.isExternalPhysical && !$0.isInternal }

                if !external.isEmpty {
                    Section(header: Text(tr("外置硬盘", "External"))) {
                        ForEach(external) { DiskRow(disk: $0) }
                    }
                }
                if !internal_.isEmpty {
                    Section(header: Text(tr("内置硬盘", "Internal"))) {
                        ForEach(internal_) { DiskRow(disk: $0) }
                    }
                }
                if !others.isEmpty {
                    Section(header: Text(tr("其他", "Other"))) {
                        ForEach(others) { DiskRow(disk: $0) }
                    }
                }
            }
            .listStyle(.sidebar)

            if appState.isEnumerating {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("正在枚举磁盘…", "Enumerating disks…")).font(.caption).foregroundColor(.appSecondary)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(tr("磁盘", "Disks"))
    }
}

private struct DiskRow: View {
    let disk: DiskInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: disk.isExternalPhysical ? "externaldrive" : "internaldrive")
                .font(.title3)
                .foregroundColor(disk.isExternalPhysical ? .accentColor : .appSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.displayName.isEmpty ? disk.bsdName : disk.displayName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(disk.sizeDescription)
                    if let p = disk.deviceProtocol { Text("· \(p)") }
                    Text("· /dev/\(disk.bsdName)")
                }
                .font(.caption)
                .foregroundColor(.appSecondary)
            }
            Spacer()
        }
        .tag(disk)
        .padding(.vertical, 2)
    }
}
