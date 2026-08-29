import Foundation
import DiskProbeCore

// MARK: - App 端 XPC 客户端：与特权 helper 通信，产出逐块结果流
//
// 生命周期与 ScanEngine 的一次真实扫描绑定：
//   begin() 建连并发起扫描 → 返回批次流；pause/resume/stop 转发；
//   onDone / 连接断开都会终结流。

final class RealScanSession: NSObject, HelperClientProtocol {
    private var connection: NSXPCConnection?
    private var continuation: AsyncStream<ScanBatch>.Continuation?
    private var stream: AsyncStream<ScanBatch>?
    private(set) var lastError: String?
    private let lock = NSLock()
    private var finished = false

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
            self?.finish(error: "与特权助手的连接已断开。")
        }
        connection.resume()
        self.connection = connection

        let acked: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let proxy = connection.remoteObjectProxy as? HelperScanProtocol else {
                self.finish(error: "特权助手接口不可用。")
                cont.resume(returning: false)
                return
            }
            proxy.startScan(devicePath: "/dev/r\(bsdName)", blockSize: blockSize) { [weak self] error in
                guard let self else { return cont.resume(returning: false) }
                if let error {
                    self.finish(error: error)
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
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

    /// 主动断开（扫描正常结束后调用）
    func close() {
        finish(error: nil)
        connection?.invalidate()
        connection = nil
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
}
