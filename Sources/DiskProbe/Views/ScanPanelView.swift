import SwiftUI
import DiskProbeCore

// MARK: - 右侧扫描面板：头部信息 + 控制条 + 地图 + 统计

struct ScanPanelView: View {
    @EnvironmentObject var appState: AppState
    let disk: DiskInfo

    @State private var showConfirm = false
    @State private var blockSizeKB: Int = 128

    var body: some View {
        VStack(spacing: 0) {
            DiskHeaderBar(disk: disk)
            Divider()

            // SMART 摘要条（温度/健康/通电时间等）
            SMARTSummaryBar()
            Divider()

            ScanControlBar(
                state: appState.scanState,
                blockSizeKB: $blockSizeKB,
                onStart: { showConfirm = true },
                onPause: { appState.pauseScan() },
                onResume: { appState.resumeScan() },
                onStop: { appState.stopScan() }
            )
            Divider()

            // 扫描地图占大部分空间
            ScanMapView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()
            ScanStatBar()
        }
        .confirmationDialog(
            "确认开始扫描",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("开始扫描（只读）") { appState.startScan(blockSizeKB: blockSizeKB) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        var s = "将以**只读**方式顺序读取整个磁盘的扇区，不会修改任何数据。\n"
        s += "目标：\(disk.displayName)（/dev/\(disk.bsdName)，\(disk.sizeDescription)）\n"
        s += "\n通过已安装的特权助手直接读取盘面，速度/进度/坏道均为真实数据。\n"
        s += "预计耗时：按 150 MB/s 估算约 \(estimateDuration(disk.sizeBytes))。"
        if disk.isInternal {
            s += "\n\n⚠️ 这是**系统盘**。扫描时系统会同时访问它，结果可能被干扰，且扫描时间较长。建议扫描时尽量减少其他操作。"
        }
        s += "\n\n建议先在「磁盘工具」中卸载目标卷，以获得不被系统读写干扰的结果。"
        return s
    }

    private func estimateDuration(_ bytes: Int64) -> String {
        let seconds = Int(Double(bytes) / 150_000_000)
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(max(1, m)) 分钟"
    }
}

// MARK: - 头部：选中盘摘要

private struct DiskHeaderBar: View {
    let disk: DiskInfo
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: disk.isExternalPhysical ? "externaldrive.fill" : "internaldrive.fill")
                .font(.system(size: 28))
                .foregroundStyle(disk.isExternalPhysical ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(disk.displayName).font(.headline)
                    if disk.isInternal {
                        Text("系统盘").font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                    } else if disk.isExternalPhysical {
                        Text("外置").font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue.opacity(0.2), in: Capsule())
                    }
                }
                Text("\(disk.sizeDescription) · \(disk.deviceProtocol ?? "未知接口") · /dev/\(disk.bsdName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
