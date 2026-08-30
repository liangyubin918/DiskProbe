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
                    Text("读取中…").font(.caption).foregroundColor(.appSecondary)
                } else if let err = appState.smartError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.orange)
                    Button("重试") {
                        Task { await appState.refreshSMART() }
                    }
                    .font(.caption)
                    .controlSize(.small)
                } else if let info = appState.smartInfo {
                    SMARTContent(info: info)
                } else {
                    Text("未读取").font(.caption).foregroundColor(.appSecondary)
                    Button("读取") {
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

    var body: some View {
        HStack(spacing: 16) {
            // 健康状态
            healthBadge

            // 温度
            if let t = info.temperatureC {
                metric("温度", String(format: "%.0f°C", t), t > 50 ? .orange : .primary)
            }

            // 通电时间
            if let h = info.powerOnHours {
                metric("通电", "\(h)h", .primary)
            }

            // HDD 特有
            if let r = info.reallocatedSectors {
                metric("重映射扇区", "\(r)", r > 0 ? .red : .primary)
            }
            if let p = info.pendingSectors {
                metric("待定扇区", "\(p)", p > 0 ? .red : .primary)
            }

            // SSD 特有
            if let u = info.percentUsed {
                metric("寿命已用", "\(u)%", u > 50 ? .orange : .primary)
            }
            if let w = info.dataUnitsWritten {
                metric("已写数据", ByteSizeFormatter.string(from: w), .primary)
            }

            // 型号（过长则省略）
            if let m = info.model, !m.isEmpty {
                Text(m).font(.caption).foregroundColor(.appSecondary).lineLimit(1)
            }
        }
    }

    private var healthBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(info.isHealthy == true ? .green : (info.isHealthy == false ? .red : .gray))
                .frame(width: 8, height: 8)
            Text(info.isHealthy == true ? "健康" : (info.isHealthy == false ? "异常" : "未知"))
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
