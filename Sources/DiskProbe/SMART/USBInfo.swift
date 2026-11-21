import Foundation

// MARK: - USB 桥接芯片识别
//
// 外置盘的稳定性和桥接芯片强相关（同一块盘换个盒子表现可能天差地别）。
// 通过 system_profiler 的 USB 树找到挂载指定 BSD 磁盘的设备节点，
// 取 VID/PID 供详情面板展示；厂商名只做客观映射，不做任何评判。

struct USBBridgeInfo: Sendable, Equatable {
    var vendorID: String      // 形如 "0x0204"
    var productID: String     // 形如 "0x6025"
    var productName: String?  // 设备名（_name，如 "External"）
    var manufacturer: String? // 设备厂商字符串（system_profiler 提供时才有）

    /// 已知 USB 存储主控/桥接厂商的客观映射（VID → 厂商名）
    static let knownVendors: [Int: String] = [
        0x0204: "Chipsbank 芯邦",
        0x05E3: "Genesys 创惟",
        0x0781: "SanDisk",
        0x090C: "Silicon Motion 慧荣",
        0x0BC2: "Seagate 希捷",
        0x1058: "Western Digital",
        0x152D: "JMicron 智微",
        0x174C: "ASMedia 祥硕",
        0x2109: "VIA Labs 威盛",
        0x8564: "Transcend 创见",
    ]

    static func vendorName(for vendorID: String) -> String? {
        guard vendorID.lowercased().hasPrefix("0x"),
              let key = Int(vendorID.dropFirst(2), radix: 16) else { return nil }
        return knownVendors[key]
    }
}

enum USBInfo {
    /// 找到挂载指定 BSD 磁盘（如 "disk8"）的 USB 设备节点。内置盘/未找到返回 nil。
    /// system_profiler 首次运行可能 1–3 秒，调用方放后台线程。
    static func bridgeInfo(bsdName: String) -> USBBridgeInfo? {
        let (output, _) = SMARTReader.runProcess("/usr/sbin/system_profiler",
                                                 args: ["SPUSBDataType", "-json"])
        guard let data = output.data(using: .utf8) else { return nil }
        return parse(data: data, bsdName: bsdName)
    }

    /// 解析 system_profiler SPUSBDataType -json 的输出。
    /// 树形结构：SPUSBDataType → 总线 → Hub → 设备；设备节点带
    /// vendor_id/product_id 和 media 数组（其中 bsd_name 对应磁盘）。
    /// 纯函数，可测。
    static func parse(data: Data, bsdName: String) -> USBBridgeInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = root["SPUSBDataType"] as? [[String: Any]] else { return nil }
        for node in tree {
            if let hit = find(in: node, bsdName: bsdName) { return hit }
        }
        return nil
    }

    private static func find(in node: [String: Any], bsdName: String) -> USBBridgeInfo? {
        if let mediaList = node["media"] as? [[String: Any]],
           mediaList.contains(where: { ($0["bsd_name"] as? String) == bsdName }) {
            return makeInfo(from: node)
        }
        // 子节点键在不同系统上有 "items"/"_items" 两种形态
        for childKey in ["items", "_items"] {
            if let children = node[childKey] as? [[String: Any]] {
                for child in children {
                    if let hit = find(in: child, bsdName: bsdName) { return hit }
                }
            }
        }
        return nil
    }

    private static func makeInfo(from node: [String: Any]) -> USBBridgeInfo? {
        guard let vid = node["vendor_id"] as? String,
              let pid = node["product_id"] as? String else { return nil }
        return USBBridgeInfo(
            vendorID: vid,
            productID: pid,
            productName: node["_name"] as? String,
            manufacturer: node["manufacturer"] as? String
        )
    }
}
