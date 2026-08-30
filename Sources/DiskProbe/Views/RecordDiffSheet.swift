import SwiftUI
import DiskProbeCore

// MARK: - 检测记录对比结果弹窗
//
// 展示「本次扫描 vs 历史记录」的异常块差异：新增/加重/持续/恢复。
// 核心结论：有新增或加重 → 盘正在恶化，红色劝备份。

struct RecordDiffSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) private var presentationMode

    private var diff: RecordDiff? { appState.recordDiff }
    private var oldFile: ScanRecordFile? { appState.recordDiffOldFile }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题与对比双方
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("对比结果", "Comparison Result")).font(.title3.weight(.bold))
                if let old = oldFile?.meta, let cur = appState.recordDiffCurrentMeta {
                    Text(tr("历史：\(old.diskName)（\(Self.dateText(old.finishedAt ?? old.startedAt))，阈值 \(Int(old.warnMs))/\(Int(old.abnormalMs))ms）",
                            "History: \(old.diskName) (\(Self.dateText(old.finishedAt ?? old.startedAt)), thresholds \(Int(old.warnMs))/\(Int(old.abnormalMs)) ms)"))
                        .font(.caption).foregroundColor(.appSecondary)
                    Text(tr("本次：\(cur.diskName)（\(Self.dateText(cur.finishedAt ?? cur.startedAt))，阈值 \(Int(cur.warnMs))/\(Int(cur.abnormalMs))ms）",
                            "Current: \(cur.diskName) (\(Self.dateText(cur.finishedAt ?? cur.startedAt)), thresholds \(Int(cur.warnMs))/\(Int(cur.abnormalMs)) ms)"))
                        .font(.caption).foregroundColor(.appSecondary)
                }
            }

            if let d = diff {
                countsRow(d)
                verdict(d)

                Divider()

                // 明细列表（新增的排最前，见 RecordDiff 排序）
                if d.items.isEmpty {
                    Text(tr("两次扫描的异常块完全一致。", "Both scans show exactly the same bad blocks."))
                        .font(.callout).foregroundColor(.appSecondary)
                } else {
                    Text(tr("明细（\(d.items.count) 项）", "Details (\(d.items.count) items)"))
                        .font(.caption.weight(.bold)).foregroundColor(.appSecondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(d.items) { item in
                                itemRow(item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)
                }

                Text(tr("按字节偏移对齐对比，块大小不同的两次扫描同样可比。两次阈值不同时，「警告」数量会受影响。",
                        "Compared by byte offset, so scans with different block sizes are still comparable. Different thresholds between runs affect the “warning” counts."))
                    .font(.caption2).foregroundColor(.appTertiary)
            }

            HStack {
                Spacer()
                Button(tr("关闭", "Close")) { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }

    private func countsRow(_ d: RecordDiff) -> some View {
        HStack(spacing: 18) {
            countBadge(tr("新增", "New"), d.newCount, color: .red)
            countBadge(tr("加重", "Worse"), d.worsenedCount, color: .orange)
            countBadge(tr("持续", "Same"), d.persistentCount, color: .gray)
            countBadge(tr("恢复", "Healed"), d.resolvedCount, color: .green)
        }
    }

    private func countBadge(_ title: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)").font(.title3.monospacedDigit().weight(.bold))
            Text(title).font(.caption).foregroundColor(.appSecondary)
        }
    }

    @ViewBuilder private func verdict(_ d: RecordDiff) -> some View {
        if d.newCount > 0 || d.worsenedCount > 0 {
            Label(tr("磁盘正在恶化：出现 \(d.newCount) 个新问题块、\(d.worsenedCount) 个加重块，建议立即备份数据。",
                     "The disk is degrading: \(d.newCount) new and \(d.worsenedCount) worsened problem blocks. Back up your data now."),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.bold)).foregroundColor(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        } else {
            Label(tr("与上次相比没有新增或加重的问题块。",
                     "No new or worsened problem blocks compared with the previous scan."),
                  systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.bold)).foregroundColor(.green)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
        }
    }

    private func itemRow(_ item: RecordDiff.Item) -> some View {
        HStack(spacing: 10) {
            Text(kindText(item.kind))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(kindColor(item.kind).opacity(0.15)))
                .foregroundColor(kindColor(item.kind))
                .frame(width: 44)
            Text(ByteSizeFormatter.string(from: item.offsetBytes))
                .font(.caption.monospacedDigit())
                .frame(width: 90, alignment: .leading)
            Text(tr("块 #\(item.newBlockIndex ?? item.oldBlockIndex ?? -1)",
                    "Block #\(item.newBlockIndex ?? item.oldBlockIndex ?? -1)"))
                .font(.caption.monospacedDigit())
                .foregroundColor(.appSecondary)
            Spacer()
            statusText(old: item.oldStatus, new: item.newStatus)
                .font(.caption.monospacedDigit())
        }
    }

    private func kindText(_ kind: RecordDiff.Kind) -> String {
        switch kind {
        case .new: return tr("新增", "NEW")
        case .worsened: return tr("加重", "WORSE")
        case .persistent: return tr("持续", "SAME")
        case .resolved: return tr("恢复", "HEALED")
        }
    }

    private func kindColor(_ kind: RecordDiff.Kind) -> Color {
        switch kind {
        case .new: return .red
        case .worsened: return .orange
        case .persistent: return .gray
        case .resolved: return .green
        }
    }

    @ViewBuilder private func statusText(old: BlockStatus?, new: BlockStatus?) -> some View {
        if let o = old, let n = new {
            Text("\(o.displayName) → \(n.displayName)")
        } else if let o = old {
            Text("\(o.displayName) → \(tr("正常", "normal"))").foregroundColor(.green)
        } else if let n = new {
            Text("\(tr("正常", "normal")) → \(n.displayName)").foregroundColor(kindColor(.new))
        } else {
            EmptyView()
        }
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
