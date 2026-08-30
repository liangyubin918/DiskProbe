import Foundation

// MARK: - App ↔ 特权 helper 的 XPC 协议（两个 target 共用）

/// App 希望连接的 mach service 与自身 identifier。
/// helper 用它校验调用方身份（identifier + 同一签名团队）。
public enum HelperIdentifiers {
    public static let machServiceName = "local.diskprobe.helper"
    public static let launchdPlistName = "local.diskprobe.helper.plist"
    public static let appIdentifier = "local.diskprobe"
    /// helper 只接受整盘裸设备节点，杜绝分区/文件/符号链接
    public static let devicePathPattern = "^/dev/rdisk[0-9]+$"
    /// helper 版本。ping 回传用于识别"注册的是旧版 helper"（重新打包后未重装的典型症状）。
    /// 与 make_app.sh 里的 CFBundleShortVersionString 保持一致。
    public static let helperVersion = "2.8"
}

/// helper 暴露给 app 的接口（root 权限运行）
@objc public protocol HelperScanProtocol: NSObjectProtocol {
    /// 健康检查：reply 传 helper 编译进二进制的版本号。
    /// 用于验证 daemon 真的能被 launchd 拉起、且不是旧版本残留。
    func ping(reply: @escaping (String?) -> Void)
    /// 打开设备并开始只读扫描。reply 传 nil 表示已开始；非 nil 为错误信息。
    /// 批量结果通过客户端实现的 HelperClientProtocol 回传。
    func startScan(devicePath: String, blockSize: UInt64,
                   reply: @escaping (String?) -> Void)
    func pauseScan()
    func resumeScan()
    func stopScan()
}

/// app 暴露给 helper 的回调接口
@objc public protocol HelperClientProtocol: NSObjectProtocol {
    /// 一批块结果（二进制编码，布局见 BatchCodec）
    func onBatch(_ data: Data)
    /// 扫描结束。errorMessage 非 nil 表示异常终止。
    func onDone(_ errorMessage: String?)
}

// MARK: - 批次结果与二进制编解码

/// 一批块的读取结果。offset 由 firstIndex × blockSize 推出，
/// 这里只传必要数据，把 IPC 开销压到最低。
public struct ScanBatch: Sendable {
    public let firstIndex: Int
    public let offsets: [Int64]
    public let elapsedMs: [Double]
    public let errnos: [Int32]

    public var count: Int { offsets.count }

    public init(firstIndex: Int, offsets: [Int64], elapsedMs: [Double], errnos: [Int32]) {
        self.firstIndex = firstIndex
        self.offsets = offsets
        self.elapsedMs = elapsedMs
        self.errnos = errnos
    }
}

/// 二进制批次编码。
/// 布局（全部小端）：magic(4) | count(4) | firstIndex(8) | offsets(8×n) | elapsedMs(8×n) | errnos(4×n)
/// x86_64 / arm64 均为小端，直接内存拷贝。
public enum BatchCodec {
    static let magic: UInt32 = 0x44_50_42_31  // "DPB1"

    public static func encode(firstIndex: Int, offsets: [Int64],
                              elapsedMs: [Double], errnos: [Int32]) -> Data {
        var data = Data(capacity: 16 + offsets.count * 20)
        withValue(magic) { data.append(contentsOf: $0) }
        withValue(UInt32(offsets.count)) { data.append(contentsOf: $0) }
        withValue(Int64(firstIndex)) { data.append(contentsOf: $0) }
        offsets.withUnsafeBytes { data.append(contentsOf: $0) }
        elapsedMs.withUnsafeBytes { data.append(contentsOf: $0) }
        errnos.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public static func decode(_ data: Data) -> ScanBatch? {
        let header = 16
        guard data.count >= header else { return nil }
        let decodedMagic: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard decodedMagic == magic else { return nil }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        let firstIndex = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) })
        guard count >= 0, data.count == header + count * 20 else { return nil }

        let offsets = data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: header + $0 * 8, as: Int64.self) }
        }
        let elapsedBase = header + count * 8
        let elapsedMs = data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: elapsedBase + $0 * 8, as: Double.self) }
        }
        let errnoBase = elapsedBase + count * 8
        let errnos = data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: errnoBase + $0 * 4, as: Int32.self) }
        }
        return ScanBatch(firstIndex: firstIndex, offsets: offsets, elapsedMs: elapsedMs, errnos: errnos)
    }

    private static func withValue<T>(_ value: T, _ body: ([UInt8]) -> Void) {
        var v = value
        withUnsafeBytes(of: &v) { body(Array($0)) }
    }
}
