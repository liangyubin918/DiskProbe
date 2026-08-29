import Foundation
import IOKit
import DiskProbeCore

// MARK: - 磁盘枚举器

/// 枚举当前连接的所有**物理整盘**（whole disk, physical）。
/// 过滤掉：APFS 合成容器（disk3 这类 Virtual）、磁盘镜像（disk6 这类 Disk Image）。
///
/// 策略：IOKit 找 Whole=true 的 Media → diskutil info -plist 读详细信息，
/// 只保留 `VirtualOrPhysical == "Physical"` 的盘（这是 diskutil 判断物理盘的标准字段）。
///
/// 安全性：只读元数据，不需要特殊权限。
enum DiskEnumerator {

    // IOKit storage 常量（来自 IOKit/storage/IOMedia.h，Swift 无自动宏导入）
    private static let mediaClass = "IOMedia"
    private static let wholeKey   = "Whole"

    /// 返回所有物理整盘，按"外置物理盘 → 内置物理盘"排序。
    static func enumerate() -> [DiskInfo] {
        var results: [DiskInfo] = []

        // 1) IOKit 枚举所有 IOMedia 对象
        guard let matching = IOServiceMatching(mediaClass) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        // 2) 遍历，只取 Whole=true 的整盘
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            guard let whole = ioBool(entry, wholeKey), whole else { continue }
            guard let bsdName = ioString(entry, "BSD Name") else { continue }

            // 3) diskutil info -plist 获取完整信息，并过滤非物理盘
            let detail = diskUtilInfo(bsdName: bsdName)

            // 关键过滤：只过滤明确的"虚拟"盘（APFS 合成容器 / 磁盘镜像 / 虚拟卷）。
            // "Physical" 和 "Unknown"（内置盘常见）都保留。
            guard detail.virtualOrPhysical != .virtual else { continue }
            // diskutil 失败时返回空 detail，容量为 0 的盘没有扫描意义，直接跳过
            guard detail.sizeBytes > 0 else { continue }

            results.append(DiskInfo(
                id: bsdName,
                bsdName: bsdName,
                displayName: detail.volumeName?.isEmpty == false
                    ? detail.volumeName!
                    : (detail.mediaName ?? bsdName),
                sizeBytes: detail.sizeBytes,
                deviceProtocol: detail.busProtocol,
                isInternal: detail.isInternal,
                isRemovable: detail.isRemovable,
                isVirtual: false
            ))
        }

        return results.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ d: DiskInfo) -> Int {
        if d.isExternalPhysical { return 0 }
        if d.isInternal { return 1 }
        return 2
    }

    // MARK: diskutil info -plist 解析

    /// 物理性判断。注意：Apple Silicon 内置盘（Apple Fabric）diskutil 返回
    /// "Unknown"（无法判断），必须保留；只有明确的 "Virtual" 才过滤。
    private enum VirtualOrPhysical {
        case physical   // 明确物理盘（外置 USB/SATA 等）
        case virtual    // 明确虚拟（APFS 容器 / 磁盘镜像）
        case unknown    // 无法判断（内置盘常见）—— 保留
    }

    private struct DiskUtilDetail {
        var sizeBytes: Int64 = 0
        var volumeName: String? = nil
        var mediaName: String? = nil
        var busProtocol: String? = nil
        var isInternal = false
        var isRemovable = false
        var virtualOrPhysical: VirtualOrPhysical = .unknown
    }

    /// 同步调用 `diskutil info -plist <bsdName>` 并解析输出。
    /// diskutil 是 macOS 内置命令，不需要特殊权限。
    private static func diskUtilInfo(bsdName: String) -> DiskUtilDetail {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(bsdName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            // 先读取管道，让 diskutil 的输出始终有消费者，避免 waitUntilExit()
            // 与子进程写满 pipe 形成死锁。
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .init() }
            guard let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] else { return .init() }

            var d = DiskUtilDetail()
            d.sizeBytes = (plist["Size"] as? NSNumber)?.int64Value ?? 0
            d.volumeName = plist["VolumeName"] as? String
            d.mediaName = plist["MediaName"] as? String
            d.busProtocol = plist["BusProtocol"] as? String ?? plist["DiskProtocol"] as? String
            d.isInternal = (plist["Internal"] as? Bool) ?? false
            d.isRemovable = (plist["RemovableMedia"] as? Bool) ?? false
            if let v = plist["VirtualOrPhysical"] as? String {
                switch v {
                case "Physical": d.virtualOrPhysical = .physical
                case "Virtual":  d.virtualOrPhysical = .virtual
                default:         d.virtualOrPhysical = .unknown
                }
            } else {
                d.virtualOrPhysical = .unknown
            }
            return d
        } catch {
            return .init()
        }
    }

    // MARK: IOKit registry 属性读取（只用来过滤 Whole=true 和取 BSD Name）

    private static func ioBool(_ obj: io_object_t, _ key: String) -> Bool? {
        guard let v = IORegistryEntryCreateCFProperty(obj, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return v
    }

    private static func ioString(_ obj: io_object_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(obj, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
