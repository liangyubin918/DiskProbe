import Foundation

// MARK: - USB 桥接芯片识别
//
// 外置盘的稳定性和桥接芯片强相关（同一块盘换个盒子表现可能天差地别）。
// 这里取 VID/PID 供详情面板展示；厂商名只做客观映射，不做任何评判。
//
// 数据源踩坑记录（2026-11 实测 macOS 26.4）：
//   - system_profiler SPUSBDataType 在部分环境下返回空树（退出码 0 但
//     SPUSBDataType: []），不可依赖；
//   - USB 设备节点的类名是 IOUSBHostDevice（旧系统为 AppleUSBHostDevice，
//     两种都要兼容）；
//   - IOUSB 平面里没有 IOMedia（BSD Name 在全量树里才有）。
//
// 因此用全量 ioreg：注册表输出是 DFS 先序，"BSD Name" 行之前最近的
// USBHostDevice 节点就是该磁盘所在的 USB 设备——即使前面有 Hub 或
// 兄弟设备，先序保证离得最近的一定是盘自己的设备节点。

struct USBBridgeInfo: Sendable, Equatable {
    var vendorID: String      // 形如 "0x0204"
    var productID: String     // 形如 "0x6025"
    var productName: String?  // 设备名（kUSBProductString，如 "External"）
    var manufacturer: String? // 设备厂商字符串（kUSBVendorString，多数桥接没有）

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
    /// 找到挂载指定 BSD 磁盘（如 "disk8"）的 USB 设备节点。未找到返回 nil。
    /// 全量 ioreg 输出有数 MB，调用方放后台线程（自带 15 秒超时）。
    static func bridgeInfo(bsdName: String) -> USBBridgeInfo? {
        let (output, _) = SMARTReader.runProcess("/usr/sbin/ioreg", args: ["-l", "-w", "0"])
        return parseText(output, bsdName: bsdName)
    }

    /// 从 ioreg -l 文本里定位磁盘的 USB 设备。纯函数，可测。
    static func parseText(_ output: String, bsdName: String) -> USBBridgeInfo? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let marker = "\"BSD Name\" = \"\(bsdName)\""

        // 1) 定位磁盘的 BSD Name 行（磁盘枚举节点）
        var matchLine: Int? = nil
        for (i, line) in lines.enumerated() where line.contains(marker) {
            matchLine = i
            break
        }
        guard let matchLine else { return nil }

        // 2) 向前找最近的 USBHostDevice 节点（兼容 AppleUSBHostDevice /
        //    IOUSBHostDevice 两种类名；先序保证最近的是盘自己的设备节点）
        var deviceLine: Int? = nil
        for i in stride(from: matchLine, through: 0, by: -1) {
            if lines[i].contains("+-o"), lines[i].contains("USBHostDevice") {
                deviceLine = i
                break
            }
        }
        guard let deviceLine else { return nil }

        // 3) 从设备节点向后收集属性，遇到下一个节点行即止（子节点会重复
        //    携带 idVendor，不能吃到）
        var vid: Int? = nil
        var pid: Int? = nil
        var name: String? = nil
        let upper = min(lines.count, deviceLine + 400)
        for i in (deviceLine + 1)..<upper {
            let line = String(lines[i])
            // 遇到下一个节点行即止——设备自身属性先于任何子节点出现
            if line.contains("+-o") { break }
            if vid == nil { vid = intValue("idVendor", in: line) }
            if pid == nil { pid = intValue("idProduct", in: line) }
            if name == nil { name = quotedValue("kUSBProductString", in: line) }
        }
        guard let vid, let pid else { return nil }
        return USBBridgeInfo(vendorID: hex4(vid), productID: hex4(pid),
                             productName: name, manufacturer: nil)
    }

    private static func intValue(_ key: String, in line: String) -> Int? {
        guard let range = line.range(of: "\"\(key)\" = ") else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func quotedValue(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\"\(key)\" = \"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func hex4(_ v: Int) -> String {
        String(format: "0x%04X", v)
    }
}
