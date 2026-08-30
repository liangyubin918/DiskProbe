import SwiftUI
import DiskProbeCore

// MARK: - SMART 摘要条（头部下方）

/// 显示选中盘的 SMART 关键信息：健康状态、温度、通电时间、
/// HDD 重映射/待定扇区、SSD 寿命/写入量。
/// 不支持或读取失败时明确提示。
struct SMARTSummaryBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("SMART", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.appSecondary)

                if appState.isReadingSMART {
                    ProgressView().controlSize(.mini)
                    Text(tr("读取中…", "Reading…")).font(.caption).foregroundColor(.appSecondary)
                } else if let err = appState.smartError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.orange)
                    Button(tr("重试", "Retry")) {
                        Task { await appState.refreshSMART() }
                    }
                    .font(.caption)
                    .controlSize(.small)
                } else if let info = appState.smartInfo {
                    SMARTContent(info: info)
                } else {
                    Text(tr("未读取", "Not read")).font(.caption).foregroundColor(.appSecondary)
                    Button(tr("读取", "Read")) {
                        Task { await appState.refreshSMART() }
                    }
                    .font(.caption)
                    .controlSize(.small)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        // 切换磁盘时自动刷新：.task(id:)（macOS 12+）的等价实现——
        // 用 .id 改变视图身份触发 onAppear 重新执行
        .id(appState.selectedDisk?.id)
        .onAppear {
            Task { await appState.refreshSMART() }
        }
    }
}

// MARK: - SMART 内容展示

private struct SMARTContent: View {
    let info: SMARTInfo

    /// 风险指标（任一被盘支持才显示第二行）：
    /// ATA 重映射/待映射/无法校正扇区 + 接口 CRC；NVMe 介质错误。
    /// 非零即盘况警报（CRC 通常指向线缆/硬盘盒而非盘面）。
    private var riskMetrics: [(label: String, value: String, color: Color, hint: String)] {
        var items: [(String, String, Color, String)] = []
        if let r = info.reallocatedSectors {
            items.append((tr("重映射", "Reallocated"), "\(r)", r > 0 ? .red : .primary,
                          tr("已损坏并被备用扇区替换的扇区数，非零说明盘面出现过坏区",
                             "Sectors remapped to spares; non-zero means the surface has had bad areas")))
        }
        if let p = info.pendingSectors {
            items.append((tr("待映射", "Pending"), "\(p)", p > 0 ? .red : .primary,
                          tr("读取不稳定、等待替换的扇区数，非零是即将出现坏区的强烈信号",
                             "Unstable sectors awaiting remap; non-zero is a strong sign of upcoming bad areas")))
        }
        if let u = info.offlineUncorrectable {
            items.append((tr("无法校正", "Uncorrectable"), "\(u)", u > 0 ? .red : .primary,
                          tr("离线自检也无法读取的扇区数",
                             "Sectors unreadable even by offline self-tests")))
        }
        if let c = info.crcErrors {
            items.append((tr("CRC 错误", "CRC Errors"), "\(c)", c > 0 ? .orange : .primary,
                          tr("接口传输校验错误，通常由线缆/硬盘盒/接口接触不良引起，盘面未必有问题",
                             "Interface transfer errors, usually a cable/enclosure/contact issue rather than the disk surface")))
        }
        if let m = info.mediaErrors {
            items.append((tr("介质错误", "Media Errors"), "\(m)", m > 0 ? .red : .primary,
                          tr("闪存/盘面介质读错误计数",
                             "Count of media read errors on the flash/disk surface")))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                healthBadge
                if let t = info.temperatureC {
                    metric(tr("温度", "Temp"), String(format: "%.0f°C", t), t > 50 ? .orange : .primary)
                }
                if let h = info.powerOnHours {
                    metric(tr("通电", "Powered"), "\(h)h", .primary)
                }
                if let u = info.percentUsed {
                    metric(tr("寿命已用", "Used Life"), "\(u)%", u > 50 ? .orange : .primary)
                }
                if let w = info.dataUnitsWritten {
                    metric(tr("已写数据", "Written"), ByteSizeFormatter.string(from: w), .primary)
                }
                if let m = info.model, !m.isEmpty {
                    Spacer()
                    Text(m).font(.caption).foregroundColor(.appSecondary).lineLimit(1)
                }
            }

            let risks = riskMetrics
            if !risks.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "stethoscope")
                        .font(.caption2)
                        .foregroundColor(.appTertiary)
                    ForEach(risks, id: \.label) { item in
                        HStack(spacing: 3) {
                            Text(item.label).font(.caption2).foregroundColor(.appSecondary)
                            Text(item.value)
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundColor(item.color)
                        }
                        .help(item.hint)
                    }
                }
            }
        }
    }

    private var healthBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(info.isHealthy == true ? .green : (info.isHealthy == false ? .red : .gray))
                .frame(width: 8, height: 8)
            Text(info.isHealthy == true ? tr("健康", "Healthy")
                     : (info.isHealthy == false ? tr("异常", "Failing") : tr("未知", "Unknown")))
                .font(.caption.weight(.bold))
                .foregroundColor(info.isHealthy == true ? .green : (info.isHealthy == false ? .red : .appSecondary))
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.appSecondary)
            Text(value).font(.caption.monospacedDigit().weight(.bold)).foregroundColor(color)
        }
    }
}
