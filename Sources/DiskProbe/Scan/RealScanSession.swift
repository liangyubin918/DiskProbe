import Foundation
import DiskProbeCore

// MARK: - App 端 XPC 客户端：与特权 helper 通信，产出逐块结果流
//
// 生命周期与 ScanEngine 的一次真实扫描绑定：
//   begin() 建连并发起扫描 → 返回批次流；pause/resume/stop 转发；
//   onDone / 连接断开都会终结流，并唤醒挂起的 begin（绝不永久等待）。

final class RealScanSession: NSObject, HelperClientProtocol {
    /// begin() 等待 helper 启动回执的兜底超时。
    /// 连接被拒绝/未安装会走 invalidationHandler，通常用不到它；
    /// 它只防"helper 存活但对 startScan 永不回执"（如 open 卡死在故障设备上）。
    private static let ackTimeout: TimeInterval = 15

    private var connection: NSXPCConnection?
    private var continuation: AsyncStream<ScanBatch>.Continuation?
    private var stream: AsyncStream<ScanBatch>?
    private(set) var lastError: String?
    private let lock = NSLock()
    private var finished = false
    private var pendingAck: CheckedContinuation<Bool, Never>? = nil
    private var ackTimeoutTask: Task<Void, Never>? = nil

    /// 建连并发起扫描。返回 nil 表示 helper 拒绝或连接失败（原因见 lastError）。
    func begin(bsdName: String, blockSize: UInt64) async -> AsyncStream<ScanBatch>? {
        let (stream, continuation) = AsyncStream<ScanBatch>.makeStream(of: ScanBatch.self,
                                                                       bufferingPolicy: .bufferingNewest(64))
        self.stream = stream
        self.continuation = continuation

        let connection = NSXPCConnection(machServiceName: HelperIdentifiers.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperScanProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: HelperClientProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            // helper 未安装 / 拒绝连接 / 身份校验失败 / helper 崩溃都会走到这里。
            // 必须唤醒挂起的 begin，否则 await 永久挂起、UI 毫无反应。
            guard let self else { return }
            self.resumeAck(false)
            self.finish(error: "无法连接特权助手（未安装、被系统拒绝或连接已断开）。")
        }
        connection.resume()
        self.connection = connection

        let acked: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let proxy = connection.remoteObjectProxy as? HelperScanProtocol else {
                self.finish(error: "特权助手接口不可用。")
                cont.resume(returning: false)
                return
            }
            self.lock.lock()
            if self.finished {
                self.lock.unlock()
                cont.resume(returning: false)
                return
            }
            self.pendingAck = cont
            self.lock.unlock()
            proxy.startScan(devicePath: "/dev/r\(bsdName)", blockSize: blockSize) { [weak self] error in
                guard let self else { return cont.resume(returning: false) }
                if let error {
                    self.resumeAck(false)
                    self.finish(error: error)
                } else {
                    self.resumeAck(true)
                }
            }
            // 兜底超时：连接活着但 startScan 回执迟迟不来
            self.ackTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.ackTimeout * 1_000_000_000))
                guard let self, self.resumeAck(false) else { return }
                self.finish(error: "特权助手 \(Int(Self.ackTimeout)) 秒内未确认启动（注册信息可能过期，请点「重装特权助手」）。")
            }
        }
        return acked ? stream : nil
    }

    func pause() {
        let proxy = connection?.remoteObjectProxy as? HelperScanProtocol
        proxy?.pauseScan()
    }

    func resume() {
        let proxy = connection?.remoteObjectProxy as? HelperScanProtocol
        proxy?.resumeScan()
    }

    func stop() {
        let proxy = connection?.remoteObjectProxy as? HelperScanProtocol
        proxy?.stopScan()
    }

    /// 主动断开（扫描结束/停止后调用）
    func close() {
        resumeAck(false) // 防御：若 begin 仍在等待则先唤醒
        finish(error: nil)
        connection?.invalidate()
        connection = nil
    }

    // MARK: 启动回执（只允许 resume 一次）

    @discardableResult
    private func resumeAck(_ value: Bool) -> Bool {
        lock.lock()
        let cont = pendingAck
        pendingAck = nil
        ackTimeoutTask?.cancel()
        ackTimeoutTask = nil
        lock.unlock()
        guard let cont else { return false }
        cont.resume(returning: value)
        return true
    }

    // MARK: HelperClientProtocol（helper 在后台队列回调）

    func onBatch(_ data: Data) {
        guard let batch = BatchCodec.decode(data) else { return }
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done else { return }
        continuation?.yield(batch)
    }

    func onDone(_ errorMessage: String?) {
        finish(error: errorMessage)
    }

    private func finish(error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let error { lastError = error }
        continuation?.finish()
        continuation = nil
    }

    // MARK: 健康检查

    /// 用一次性连接 ping helper。返回版本串；nil 表示无法启动/超时/被拒。
    /// 用于把 SMAppService 的"已注册"和"真的能跑"区分开——重新打包后
    /// 注册信息过期时，status 仍是 enabled 但 daemon 实际 spawn 失败。
    static func ping(timeout: TimeInterval = 5) async -> String? {
        let pinger = HelperPinger()
        return await withCheckedContinuation { cont in
            pinger.start(timeout: timeout, continuation: cont)
        }
    }
}

/// 一次性健康检查连接。生命周期：start → 回复/断开/超时 三者最先发生者终结。
private final class HelperPinger: NSObject, HelperClientProtocol {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<String?, Never>?
    private var connection: NSXPCConnection?
    private var timeoutTask: Task<Void, Never>?

    func start(timeout: TimeInterval, continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
        let connection = NSXPCConnection(machServiceName: HelperIdentifiers.machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperScanProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: HelperClientProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.resume(nil)
        }
        self.connection = connection
        connection.resume()

        guard let proxy = connection.remoteObjectProxy as? HelperScanProtocol else {
            resume(nil)
            return
        }
        proxy.ping { [weak self] version in
            self?.resume(version)
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.resume(nil)
        }
    }

    private func resume(_ version: String?) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let cont = continuation
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        cont?.resume(returning: version)
        connection?.invalidate()
        connection = nil
    }

    // HelperClientProtocol 空实现：ping 流程 helper 不会回调这些方法
    func onBatch(_ data: Data) {}
    func onDone(_ errorMessage: String?) {}
}
