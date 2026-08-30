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

            // 扫描地图占大部分空间：只显示属于当前选中盘的结果；
            // 后台扫描其他盘时这里显示空状态
            if appState.scanResultsBelong(to: disk) {
                ScanMapView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                emptyScanArea
            }

            Divider()
            ScanStatBar(forcedZero: !appState.scanResultsBelong(to: disk))
        }
        // confirmationDialog 是 macOS 12+；用老版 Alert（10.15+）等价实现
        .alert(isPresented: $showConfirm) {
            Alert(
                title: Text("确认开始扫描"),
                message: Text(confirmMessage),
                primaryButton: .default(Text("开始扫描（只读）")) {
                    appState.startScan(blockSizeKB: blockSizeKB)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    /// 切到未扫描的盘时的空状态；后台扫描仍在进行时给出提示
    private var emptyScanArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 44))
                .foregroundColor(.appQuaternary)
            Text("该磁盘暂无扫描结果")
                .font(.callout).foregroundColor(.appSecondary)
            if let name = appState.activeScanDiskName {
                Text("后台正在扫描「\(name)」，切回该盘可查看实时进度")
                    .font(.caption).foregroundColor(.appTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var confirmMessage: String {
        var s = "将以「只读」方式顺序读取整个磁盘的扇区，不会修改任何数据。\n"
        s += "目标：\(disk.displayName)（/dev/\(disk.bsdName)，\(disk.sizeDescription)）\n"
        s += "\n通过已安装的特权助手直接读取盘面，速度/进度/坏道均为真实数据。\n"
        s += "预计耗时：按 150 MB/s 估算约 \(estimateDuration(disk.sizeBytes))。"
        if disk.isInternal {
            s += "\n\n⚠️ 这是系统盘。扫描时系统会同时访问它，结果可能被干扰，且扫描时间较长。建议扫描时尽量减少其他操作。"
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
                .foregroundColor(disk.isExternalPhysical ? .accentColor : .appSecondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(disk.displayName).font(.headline)
                    if disk.isInternal {
                        Text("系统盘").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    } else if disk.isExternalPhysical {
                        Text("外置").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.2)))
                    }
                }
                Text("\(disk.sizeDescription) · \(disk.deviceProtocol ?? "未知接口") · /dev/\(disk.bsdName)")
                    .font(.caption).foregroundColor(.appSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
