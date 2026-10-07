import SwiftUI
import AppKit
import DiskProbeCore

// MARK: - SMART 详细信息弹窗
//
// 展示 smartctl 的完整数据：ATA 全量属性表（当前/最差/阈值/原始值）、
// NVMe 健康日志全字段、ATA 错误日志与自检日志。
// 数据每次打开实时读取（不缓存）；macOS 11 无 Table/Grid，属性表用自绘行。

struct SMARTDetailsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) private var presentationMode

    @State private var copyFeedback = false

    private var details: SMARTDetails? { appState.smartDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let err = appState.smartDetailsError {
                errorBanner(err)
            }
            if appState.isLoadingSMARTDetails && details == nil {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.regular)
                    Text(tr("正在读取 SMART 详细信息…", "Reading SMART details…"))
                        .font(.callout).foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = details {
                content(d)
            } else if appState.smartDetailsError == nil {
                Text(tr("尚未读取。", "Not read yet."))
                    .font(.callout).foregroundColor(.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            HStack {
                Spacer()
                Button(tr("关闭", "Close")) { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 640)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Label(tr("SMART 详细信息", "SMART Details"), systemImage: "waveform.path.ecg")
                .font(.title3.weight(.bold))
            if let health = details?.health {
                healthBadge(health)
            }
            Spacer()
            if appState.isLoadingSMARTDetails {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await appState.loadSMARTDetails() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help(tr("重新读取", "Refresh"))
            Button {
                Task { await copyDiagnostics() }
            } label: {
                Label(copyFeedback ? tr("已复制", "Copied") : tr("复制诊断文本", "Copy Diagnostics"),
                      systemImage: copyFeedback ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(appState.selectedDisk == nil)
            .help(tr("把 smartctl 的完整文本输出复制到剪贴板，可直接发给他人或 AI 协助分析。",
                      "Copy smartctl's full text output to the clipboard for sharing or AI-assisted analysis."))
        }
    }

    private func healthBadge(_ health: String) -> some View {
        let ok = health.localizedCaseInsensitiveContains("passed")
        return HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(ok ? tr("健康", "Healthy") : tr("异常", "Failing"))
                .font(.caption.weight(.bold))
                .foregroundColor(ok ? .green : .red)
        }
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            Text(err).font(.caption).foregroundColor(.orange)
            Button(tr("重试", "Retry")) {
                Task { await appState.loadSMARTDetails() }
            }
            .font(.caption).controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    // MARK: 主体

    @ViewBuilder private func content(_ d: SMARTDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                deviceSection(d)
                if d.isNVMe, let h = d.nvmeHealth {
                    nvmeSection(h)
                } else if !d.attributes.isEmpty {
                    ataSection(d)
                } else {
                    Text(tr("此设备未提供可显示的 SMART 明细（部分 USB 桥接方案不支持透传）。",
                            "This device does not expose SMART details (some USB bridge chips do not support passthrough)."))
                        .font(.callout).foregroundColor(.appSecondary)
                }
                if !d.errorLog.isEmpty {
                    ataErrorLogSection(d)
                }
                if !d.selfTestLog.isEmpty {
                    selfTestSection(d)
                }
                footnote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 设备信息

    private func deviceSection(_ d: SMARTDetails) -> some View {
        var items: [(String, String)] = []
        if let m = d.model { items.append((tr("型号", "Model"), m)) }
        if let s = d.serial { items.append((tr("序列号", "Serial"), s)) }
        if let f = d.firmware { items.append((tr("固件", "Firmware"), f)) }
        items.append((tr("接口", "Interface"), (d.deviceType ?? "").uppercased()))
        if let cap = d.capacityBytes {
            items.append((tr("容量", "Capacity"), ByteSizeFormatter.string(from: cap)))
        }
        if let rr = d.rotationRate {
            items.append((tr("转速", "Rotation"), "\(rr) RPM"))
        }
        if let ff = d.formFactorName {
            items.append((tr("形态", "Form Factor"), ff))
        }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                   GridItem(.flexible(), spacing: 16),
                                   GridItem(.flexible())],
                         alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.caption2).foregroundColor(.appSecondary)
                    Text(item.1).font(.caption.monospacedDigit().weight(.medium))
                        .lineLimit(1).help(item.1)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.appSecondary.opacity(0.06)))
    }

    // MARK: ATA 属性表

    private func ataSection(_ d: SMARTDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("ATA 属性表（\(d.attributes.count) 项）", "ATA Attributes (\(d.attributes.count))"))
                .font(.caption.weight(.bold)).foregroundColor(.appSecondary)
            attributeHeader
            ForEach(d.attributes) { row in
                attributeRow(row)
            }
            Text(tr("列名的 ⓘ 可查看各列含义；悬停属性名可查看该指标的定义。",
                    "Tap the ⓘ next to a column title for its meaning; hover an attribute name for its definition."))
                .font(.caption2).foregroundColor(.appTertiary)
        }
    }

    private var attributeHeader: some View {
        HStack(spacing: 8) {
            Text("#").font(.caption2.weight(.bold)).foregroundColor(.appSecondary)
                .frame(width: 24, alignment: .leading)
            Text(tr("属性", "Attribute")).font(.caption2.weight(.bold)).foregroundColor(.appSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle(tr("当前", "Value"), width: 48, info: Self.infoValue)
            columnTitle(tr("最差", "Worst"), width: 48, info: Self.infoWorst)
            columnTitle(tr("阈值", "Thresh"), width: 48, info: Self.infoThreshold)
            columnTitle(tr("原始值", "Raw"), width: 132, info: Self.infoRaw)
        }
        .padding(.horizontal, 6)
    }

    /// 列名 + ⓘ。点击（而非悬停）弹出该列含义的科普。
    private func columnTitle(_ title: String, width: CGFloat, info: String) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.caption2.weight(.bold)).foregroundColor(.appSecondary)
            ColumnInfoButton(text: info)
        }
        .frame(width: width, alignment: .trailing)
    }

    private func attributeRow(_ row: SMARTAttributeRow) -> some View {
        let failed = row.isFailed || row.isCritical
        let known = Self.attributeDescriptions[row.id]
        return HStack(spacing: 8) {
            Text("\(row.id)").font(.caption.monospacedDigit()).foregroundColor(.appSecondary)
                .frame(width: 24, alignment: .leading)
            Text(known?.zh ?? row.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.value.map(String.init) ?? "–")
                .font(.caption.monospacedDigit().weight(failed ? .bold : .regular))
                .foregroundColor(failed ? .red : .primary)
                .frame(width: 48, alignment: .trailing)
            Text(row.worst.map(String.init) ?? "–")
                .font(.caption.monospacedDigit()).foregroundColor(.appSecondary)
                .frame(width: 48, alignment: .trailing)
            Text(row.threshold.map(String.init) ?? "–")
                .font(.caption.monospacedDigit()).foregroundColor(.appSecondary)
                .frame(width: 48, alignment: .trailing)
            Text(Self.rawDisplay(row))
                .font(.caption.monospacedDigit()).foregroundColor(.appSecondary)
                .lineLimit(1).truncationMode(.head)
                .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(failed ? Color.red.opacity(0.08) : Color.clear))
        .help(Self.rowTooltip(row, known: known))
    }

    private static func rowTooltip(_ row: SMARTAttributeRow,
                                   known: (zh: String, hint: String)?) -> String {
        var lines: [String] = []
        lines.append(row.name)
        if row.isFailed {
            lines.append(tr("smartctl 标记：当前正在失败（FAILING_NOW）。", "smartctl flag: FAILING_NOW."))
        } else if row.whenFailed == "In_the_past" {
            lines.append(tr("smartctl 标记：曾经失败过（In_the_past）。", "smartctl flag: failed in the past."))
        }
        if let hint = known?.hint {
            lines.append(hint)
        }
        lines.append(tr("原始值：\(row.rawString)", "Raw value: \(row.rawString)"))
        return lines.joined(separator: "\n")
    }

    // MARK: 列名 ⓘ 的科普文案

    private static let infoValue = tr(
        "厂商把原始数据换算成的健康评分，出厂通常是 100（个别厂商 200），越低越差。它不是物理量，也不是百分比——想了解实际情况请看「原始值」。",
        "A normalized health score computed by the vendor, usually starting at 100 (some start at 200); lower is worse. It is not a physical quantity or a percentage — check the raw value for what actually happened.")
    private static let infoWorst = tr(
        "这块盘有史以来该评分跌到过的最低点，不是平均值。最差值明显低于当前值，说明它曾一度恶化（例如一次过热或一段不稳定期）。",
        "The lowest score the drive has ever recorded — not an average. A worst value well below the current one means it degraded at some point (e.g. an overheating event).")
    private static let infoThreshold = tr(
        "厂商划定的失败线：当前值 ≤ 阈值时，该项被厂商判定为失败。0 表示未设线，不代表永远安全。",
        "The vendor's failure line: at or below it the attribute counts as failed. 0 means no line is set — which does not mean forever safe.")
    private static let infoRaw = tr(
        "盘固件记录的真实物理计数（坏扇区数、通电小时数等），通常是最有用的数字。注意编码是厂商私有的：个别属性（如 Seagate 的读取错误率）把多个字段打包在一个数里，数字大不一定代表问题。",
        "Real physical counters recorded by the firmware (bad sectors, power-on hours…), usually the most useful numbers. Encodings are vendor-specific: some attributes (e.g. Seagate read error rate) pack several fields into one number, so a big value is not automatically bad.")

    /// 列名旁的 ⓘ：点击弹出该列含义的科普（用户要求点击而非悬停）。
    private struct ColumnInfoButton: View {
        let text: String
        @State private var show = false

        var body: some View {
            Button {
                show = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundColor(.appTertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text)
                    .font(.caption)
                    .lineSpacing(3)
                    .padding(12)
                    .frame(width: 300, alignment: .leading)
            }
        }
    }

    // MARK: 数值展示格式化

    /// 原始值单元格文本：千分位之外，只对个别属性做客观换算——
    /// 9 通电小时（≈天/年）、190/194 温度（°C）。其余原样保留。
    private static func rawDisplay(_ row: SMARTAttributeRow) -> String {
        if row.id == 9, let h = SMARTReader.parseInt(row.rawString) {
            if h >= 8760 {
                return formatLeadingNumber(row.rawString)
                    + String(format: tr("（约 %.1f 年）", " (≈ %.1f yr)"), Double(h) / 8760.0)
            }
            return formatLeadingNumber(row.rawString) + tr("（约 \(h / 24) 天）", " (≈ \(h / 24) d)")
        }
        if (row.id == 190 || row.id == 194), let t = SMARTReader.parseInt(row.rawString) {
            return "\(t)°C"
        }
        return formatLeadingNumber(row.rawString)
    }

    /// 给字符串开头的连续数字加千分位（"149211375" → "149,211,375"；
    /// "24 (0 1 0 0 0)" 的前导 "24" 不足 4 位保持不变）。固定 en_US 分组符，
    /// 避免不同系统区域出现空格/异形分组。
    static func formatLeadingNumber(_ s: String) -> String {
        let digits = s.prefix { $0.isNumber }
        guard digits.count > 3, let n = Int(digits) else { return s }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        let grouped = f.string(from: NSNumber(value: n)) ?? String(digits)
        return grouped + s.dropFirst(digits.count)
    }

    // MARK: NVMe 健康日志

    private func nvmeSection(_ h: SMARTNVMeHealth) -> some View {
        var items: [(String, String, Color)] = []
        items.append((tr("关键警告", "Critical Warning"),
                      h.criticalWarning == 0 ? tr("无", "None") : "0x\(String(h.criticalWarning, radix: 16))",
                      h.criticalWarning == 0 ? .primary : .red))
        if let t = h.temperatureC {
            items.append((tr("温度", "Temp"), String(format: "%.0f°C", t), t > 70 ? .orange : .primary))
        }
        if let p = h.percentageUsed {
            items.append((tr("寿命已用", "Used Life"), "\(p)%", p > 80 ? .orange : .primary))
        }
        if let spare = h.availableSpare, let threshold = h.availableSpareThreshold {
            items.append((tr("可用备用空间", "Available Spare"), "\(spare)%",
                          spare <= threshold ? .red : .primary))
            items.append((tr("备用空间阈值", "Spare Threshold"), "\(threshold)%", .appSecondary))
        }
        if let v = h.dataUnitsRead, let bytes = unitBytes(v) {
            items.append((tr("已读数据", "Data Read"), ByteSizeFormatter.string(from: bytes), .primary))
        }
        if let v = h.dataUnitsWritten, let bytes = unitBytes(v) {
            items.append((tr("已写数据", "Data Written"), ByteSizeFormatter.string(from: bytes), .primary))
        }
        if let v = h.hostReads {
            items.append((tr("主机读取", "Host Reads"), Self.thousands(v), .primary))
        }
        if let v = h.hostWrites {
            items.append((tr("主机写入", "Host Writes"), Self.thousands(v), .primary))
        }
        if let v = h.powerOnHours {
            items.append((tr("通电时间", "Powered On"), "\(v) h", .primary))
        }
        if let v = h.powerCycles {
            items.append((tr("通电次数", "Power Cycles"), Self.thousands(v), .primary))
        }
        if let v = h.unsafeShutdowns {
            items.append((tr("非正常断电", "Unsafe Shutdowns"), Self.thousands(v),
                          v > 0 ? .appSecondary : .primary))
        }
        if let v = h.mediaErrors {
            items.append((tr("介质错误", "Media Errors"), Self.thousands(v), v > 0 ? .red : .primary))
        }
        if let v = h.numErrLogEntries {
            items.append((tr("错误日志条目", "Error Log Entries"), Self.thousands(v),
                          v > 0 ? .appSecondary : .primary))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(tr("NVMe 健康日志", "NVMe Health Log"))
                .font(.caption.weight(.bold)).foregroundColor(.appSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible())],
                      alignment: .leading, spacing: 10) {
                ForEach(items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.0).font(.caption2).foregroundColor(.appSecondary)
                        Text(item.1).font(.caption.monospacedDigit().weight(.medium))
                            .foregroundColor(item.2)
                    }
                }
            }
            Text(tr("数据量按 NVMe 规范换算（1 数据单元 = 1000 × 512B）。",
                    "Data units follow the NVMe spec (1 unit = 1000 × 512 B)."))
                .font(.caption2).foregroundColor(.appTertiary)
        }
    }

    /// NVMe 数据单元 → 字节（1000 × 512B；溢出时返回 nil 不显示）
    private func unitBytes(_ units: Int64) -> Int64? {
        let (thousands, o1) = units.multipliedReportingOverflow(by: 1000)
        guard !o1 else { return nil }
        let (bytes, o2) = thousands.multipliedReportingOverflow(by: 512)
        return o2 ? nil : bytes
    }

    private static func thousands(_ v: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    // MARK: ATA 错误日志 / 自检日志

    private func ataErrorLogSection(_ d: SMARTDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(tr("ATA 错误日志", "ATA Error Log"))
                    .font(.caption.weight(.bold)).foregroundColor(.appSecondary)
                if let total = d.errorLogTotalCount, total > d.errorLog.count {
                    Text(tr("历史共 \(total) 次，盘内仅保留最近 5 条",
                            "\(total) in total; the drive keeps only the last 5"))
                        .font(.caption2).foregroundColor(.appTertiary)
                }
            }
            ForEach(d.errorLog) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text("#\(entry.errorNumber)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundColor(.orange)
                        .frame(width: 34, alignment: .leading)
                    Text("\(entry.lifetimeHours) h")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.appSecondary)
                        .frame(width: 64, alignment: .leading)
                    Text(entry.description)
                        .font(.caption.monospacedDigit())
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.06)))
            }
            Text(tr("UNC（不可纠正读取）通常指向盘面/介质问题；接口类错误多为线缆、硬盘盒或接触不良。",
                    "UNC (unrecoverable read) usually indicates a surface/media problem; interface errors point to cables, enclosures or contacts."))
                .font(.caption2).foregroundColor(.appTertiary)
        }
    }

    private func selfTestSection(_ d: SMARTDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("ATA 自检日志", "ATA Self-Test Log"))
                .font(.caption.weight(.bold)).foregroundColor(.appSecondary)
            ForEach(d.selfTestLog) { entry in
                HStack(spacing: 8) {
                    Text(entry.typeDescription)
                        .font(.caption).frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    Text(entry.statusDescription)
                        .font(.caption)
                        .foregroundColor(entry.passed ? .green : .red)
                        .lineLimit(1)
                    Spacer()
                    if let lba = entry.lbaFirstError, !entry.passed {
                        Text(tr("首个出错 LBA: \(lba)", "First failing LBA: \(lba)"))
                            .font(.caption.monospacedDigit()).foregroundColor(.red)
                    }
                    if let h = entry.lifetimeHours {
                        Text("\(h) h").font(.caption.monospacedDigit()).foregroundColor(.appSecondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Text(tr("数据来源：smartctl（smartmontools），每次打开实时读取。诊断文本可直接粘贴给 AI 或技术支持分析。",
                "Source: smartctl (smartmontools), read live each time. The diagnostics text can be pasted to AI or support for analysis."))
            .font(.caption2).foregroundColor(.appTertiary)
    }

    // MARK: 复制诊断文本

    private func copyDiagnostics() async {
        guard let disk = appState.selectedDisk else { return }
        let result = await Task.detached(priority: .userInitiated) {
            await SMARTReader.readPlainText(bsdName: disk.bsdName)
        }.value
        switch result {
        case .success(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyFeedback = true
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copyFeedback = false
        case .failure(let err):
            appState.smartDetailsError = err.localizedDescription
        }
    }

    // MARK: 常见 ATA 属性的中文名与说明

    /// ID → (中文名, 定义)。只写"计的是什么"，不做预测或建议。
    private static let attributeDescriptions: [Int: (zh: String, hint: String)] = [
        1: (tr("底层读取错误率", "Raw Read Error Rate"),
            tr("盘面读取的原始错误计数。Seagate 盘此值包含已被 ECC 纠正的读操作。",
               "Raw read error count; on Seagate drives it includes ECC-corrected reads.")),
        3: (tr("主轴起转时间", "Spin-Up Time"),
            tr("主轴从静止到额定转速所需的时间。", "Time for the spindle to reach rated speed.")),
        4: (tr("启停次数", "Start/Stop Count"),
            tr("主轴电机启动/停止的总次数。", "Total motor start/stop cycles.")),
        5: (tr("重映射扇区数", "Reallocated Sectors"),
            tr("已损坏并被备用扇区替换的扇区数。", "Sectors that were damaged and replaced with spares.")),
        7: (tr("寻道错误率", "Seek Error Rate"),
            tr("寻道错误计数；Seagate 盘此值多为正常寻道统计。",
               "Seek error count; on Seagate drives mostly benign seek statistics.")),
        9: (tr("通电时间", "Power-On Hours"),
            tr("累计通电小时数。", "Total power-on hours.")),
        10: (tr("起转重试", "Spin Retry Count"),
             tr("主轴一次未启动成功、需要重试的次数。", "Count of spin-ups that needed a retry.")),
        12: (tr("通电次数", "Power Cycle Count"),
             tr("完整上电/断电周期的次数。", "Full power on/off cycles.")),
        183: (tr("运行时坏块", "Runtime Bad Block"),
              tr("运行中发现的坏块计数。", "Bad blocks found at runtime.")),
        184: (tr("端到端校验错误", "End-to-End Error"),
              tr("盘内缓存到介质的传输校验错误计数。", "Transfer parity errors between cache and media.")),
        187: (tr("不可纠正错误", "Reported Uncorrectable"),
              tr("无法由 ECC 恢复的读取错误计数。", "Read errors that ECC could not recover.")),
        188: (tr("命令超时", "Command Timeout"),
              tr("命令执行超时的计数。", "Count of commands that timed out.")),
        190: (tr("气流温度", "Airflow Temperature"),
              tr("盘内气流温度（摄氏度）。", "Internal airflow temperature in Celsius.")),
        191: (tr("震动感知", "G-Sense Error Rate"),
              tr("震动/冲击感知事件的计数。", "Count of detected shock/vibration events.")),
        192: (tr("断电缩回", "Power-Off Retract"),
              tr("断电时磁头紧急缩回的次数。", "Emergency head retracts at power loss.")),
        193: (tr("磁头加载次数", "Load Cycle Count"),
              tr("磁头加载/卸载的次数。", "Head load/unload cycles.")),
        194: (tr("温度", "Temperature"),
              tr("盘体当前温度（摄氏度）。", "Current drive temperature in Celsius.")),
        195: (tr("ECC 硬件校正", "Hardware ECC Recovered"),
              tr("由硬件 ECC 纠正的读错误计数。", "Read errors corrected by hardware ECC.")),
        196: (tr("重映射事件", "Reallocated Event Count"),
              tr("发生重映射操作的次数。", "Count of remap operations.")),
        197: (tr("待映射扇区", "Current Pending Sector"),
              tr("读取不稳定、等待验证或替换的扇区数。", "Unstable sectors awaiting verification or remap.")),
        198: (tr("离线不可校正", "Offline Uncorrectable"),
              tr("离线自检也无法读取的扇区数。", "Sectors unreadable even by offline self-tests.")),
        199: (tr("CRC 接口错误", "UDMA CRC Error Count"),
              tr("接口传输的 CRC 校验错误计数。", "CRC checksum errors on the interface.")),
    ]
}
