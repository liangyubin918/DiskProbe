import Foundation

// MARK: - 磁盘信息（列表里每一行）

/// 描述一块"整盘"（whole disk）。不关心分区，只关心整盘读写性能。
/// 这个结构跨 UI / 未来特权助手通用（Codable + Sendable）。
public struct DiskInfo: Identifiable, Hashable, Sendable {
    public let id: String        // 用 BSD name（"disk4"）做唯一 id
    public let bsdName: String   // "disk4" -> 设备 /dev/disk4、裸设备 /dev/rdisk4
    public let displayName: String // "Westen Digital"
    public let sizeBytes: Int64
    public let deviceProtocol: String? // "USB" / "SATA" / "PCI"（来自 DiskArbitration）
    public let isInternal: Bool        // 系统盘 = true
    public let isRemovable: Bool       // 可移动介质（光盘等）
    public let isVirtual: Bool         // 磁盘镜像 / 虚拟（不参与坏道扫描）

    public var isExternalPhysical: Bool { !isInternal && !isVirtual }

    public init(id: String, bsdName: String, displayName: String, sizeBytes: Int64,
                deviceProtocol: String?, isInternal: Bool, isRemovable: Bool, isVirtual: Bool) {
        self.id = id; self.bsdName = bsdName; self.displayName = displayName
        self.sizeBytes = sizeBytes; self.deviceProtocol = deviceProtocol
        self.isInternal = isInternal; self.isRemovable = isRemovable; self.isVirtual = isVirtual
    }

    /// 人类可读容量，例如 "500.1 GB"
    public var sizeDescription: String { ByteSizeFormatter.string(from: sizeBytes) }
}

// MARK: - 字节大小格式化（1000 进制，符合 macOS 习惯）

public enum ByteSizeFormatter {
    public static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file      // 1000 进制
        formatter.includesUnit = true
        formatter.allowsNonnumericFormatting = true
        return formatter.string(fromByteCount: bytes)
    }
}
