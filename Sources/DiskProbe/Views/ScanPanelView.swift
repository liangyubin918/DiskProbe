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

            // 高危警告：本盘扫描中发现坏块/异常块时持续醒目提示（扫描中即出现，不等扫完）
            if appState.scanResultsBelong(to: disk),
               appState.statError > 0 || appState.statAbnormal > 0 {
                backupWarningBanner
                Divider()
            }

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
                title: Text(tr("确认开始扫描", "Confirm Scan")),
                message: Text(confirmMessage),
                primaryButton: .default(Text(tr("开始扫描（只读）", "Start Scan (Read-Only)"))) {
                    appState.startScan(blockSizeKB: blockSizeKB)
                },
                secondaryButton: .cancel(Text(tr("取消", "Cancel")))
            )
        }
        .sheet(isPresented: $appState.showRecordDiff) {
            RecordDiffSheet()
        }
    }

    /// 高危备份警告横幅
    private var backupWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("检测到 \(appState.statError + appState.statAbnormal) 个坏块/异常块",
                        "\(appState.statError + appState.statAbnormal) bad/abnormal blocks detected"))
                    .font(.callout.weight(.bold)).foregroundColor(.red)
                Text(tr("数据存在丢失风险：请立即备份重要文件；若备份过程中出现卡顿或失败，坏块可能在继续扩大。",
                        "Your data is at risk: back up important files now. If the backup stalls or fails, the damage may be spreading."))
                    .font(.caption).foregroundColor(.appSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    /// 切到未扫描的盘时的空状态；后台扫描仍在进行时给出提示
    private var emptyScanArea: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 44))
                .foregroundColor(.appQuaternary)
            Text(tr("该磁盘暂无扫描结果", "No scan results for this disk yet"))
                .font(.callout).foregroundColor(.appSecondary)
            if let name = appState.activeScanDiskName {
                Text(tr("后台正在扫描「\(name)」，切回该盘可查看实时进度",
                        "Scanning “\(name)” in the background — switch back to watch live progress"))
                    .font(.caption).foregroundColor(.appTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var confirmMessage: String {
        var s = tr("将以「只读」方式顺序读取整个磁盘的扇区，不会修改任何数据。\n",
                   "The whole disk will be read sequentially in read-only mode; nothing is modified.\n")
        s += tr("目标：\(disk.displayName)（/dev/\(disk.bsdName)，\(disk.sizeDescription)）\n",
                "Target: \(disk.displayName) (/dev/\(disk.bsdName), \(disk.sizeDescription))\n")
        s += tr("\n通过已安装的特权助手直接读取盘面，速度/进度/坏道均为真实数据。\n",
                "\nReads the disk surface directly through the installed privileged helper; speed, progress and bad blocks are all real data.\n")
        s += tr("预计耗时：按 150 MB/s 估算约 \(estimateDuration(disk.sizeBytes))。",
                "Estimated time at 150 MB/s: about \(estimateDuration(disk.sizeBytes)).")
        if disk.isInternal {
            s += tr("\n\n⚠️ 这是系统盘。扫描时系统会同时访问它，结果可能被干扰，且扫描时间较长。建议扫描时尽量减少其他操作。",
                    "\n\n⚠️ This is the system disk. macOS will access it during the scan, which may skew results and lengthen the scan. Minimize other activity while scanning.")
        }
        s += tr("\n\n建议先在「磁盘工具」中卸载目标卷，以获得不被系统读写干扰的结果。",
                "\n\nFor the cleanest results, unmount the target volumes in Disk Utility first.")
        return s
    }

    private func estimateDuration(_ bytes: Int64) -> String {
        let seconds = Int(Double(bytes) / 150_000_000)
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 {
            return tr("\(h) 小时 \(m) 分钟", "\(h) hr \(m) min")
        }
        return tr("\(max(1, m)) 分钟", "\(max(1, m)) min")
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
                        Text(tr("系统盘", "System")).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    } else if disk.isExternalPhysical {
                        Text(tr("外置", "External")).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.2)))
                    }
                }
                Text("\(disk.sizeDescription) · \(disk.deviceProtocol ?? tr("未知接口", "unknown interface")) · /dev/\(disk.bsdName)")
                    .font(.caption).foregroundColor(.appSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
