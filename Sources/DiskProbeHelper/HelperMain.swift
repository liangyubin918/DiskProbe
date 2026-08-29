import Foundation
import DiskProbeCore
import Security
import Darwin

// MARK: - DiskProbe 特权 helper（launchd daemon，root 权限）
//
// 由 SMAppService 安装，launchd 按需拉起。只做一件事：对指定整盘裸设备
// 做顺序只读扫描，把每块耗时/errno 回传给 app。
//
// 安全约束：
//   1. 每个新连接校验调用方：audit token → SecCode → 同一签名团队 + app identifier。
//   2. 设备路径白名单 ^/dev/rdisk[0-9]+$，lstat 拒绝符号链接，stat 必须是字符设备。
//   3. 只读：设备以 O_RDONLY 打开；接口层没有任何写语义的方法。
//   4. 所有连接断开后空闲 60 秒自动退出，把进程还给 launchd。

final class ScanRunner: NSObject, HelperScanProtocol {
    // fd / 停止 / 暂停 / 连接被 XPC 连接队列和扫描队列并发访问，必须加锁
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopFlag = false
    private var pauseFlag = false
    private var didReportDone = false
    private weak var connection: NSXPCConnection?

    /// 由 delegate 在接受连接时挂接（connection 通过 exportedObject 强持有 runner，
    /// runner 用 weak 反向引用避免环）
    func attach(_ connection: NSXPCConnection) {
        lock.lock(); self.connection = connection; lock.unlock()
    }

    func detach() {
        lock.lock(); connection = nil; lock.unlock()
    }

    // MARK: XPC 接口（连接队列调用）

    func ping(reply: @escaping (String?) -> Void) {
        reply("DiskProbeHelper \(HelperIdentifiers.helperVersion)")
    }

    func startScan(devicePath: String, blockSize: UInt64, reply: @escaping (String?) -> Void) {
        lock.lock()
        let busy = fd != -1
        lock.unlock()
        guard !busy else { reply("扫描已在进行中"); return }
        guard blockSize >= 512, blockSize <= 4 * 1024 * 1024 else {
            reply("块大小超出允许范围（512B–4MB）")
            return
        }
        if let problem = Self.deviceProblem(devicePath) {
            reply(problem)
            return
        }
        let newFD = open(devicePath, O_RDONLY)
        guard newFD >= 0 else {
            reply("无法打开 \(devicePath)：\(String(cString: strerror(errno)))（errno \(errno)）")
            return
        }
        // 绕过页缓存：测的是真实盘面而不是内存缓存
        guard fcntl(newFD, F_NOCACHE, 1) == 0 else {
            let msg = String(cString: strerror(errno))
            close(newFD)
            reply("设置 F_NOCACHE 失败：\(msg)")
            return
        }

        lock.lock()
        fd = newFD
        stopFlag = false
        pauseFlag = false
        didReportDone = false
        lock.unlock()
        let size = Int(blockSize)
        reply(nil)
        DispatchQueue(label: "local.diskprobe.scan", qos: .userInitiated).async { [weak self] in
            self?.runLoop(fd: newFD, blockSize: size)
        }
    }

    func pauseScan() { setFlags(pause: true) }
    func resumeScan() { setFlags(pause: false) }
    func stopScan() { setFlags(stop: true, pause: false) }

    func connectionDidInvalidate() {
        // app 侧断开（崩溃/退出）时立刻停止读盘，不让 daemon 悬空
        setFlags(stop: true, pause: false)
    }

    // MARK: 标志位（加锁访问）

    private func flags() -> (stop: Bool, pause: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (stopFlag, pauseFlag)
    }

    private func setFlags(stop: Bool? = nil, pause: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let stop { stopFlag = stop }
        if let pause { pauseFlag = pause }
    }

    // MARK: 扫描主循环（独立队列）

    private func runLoop(fd scanFD: Int32, blockSize: Int) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard scanFD >= 0, let connection, let proxy = connection.remoteObjectProxy as? HelperClientProtocol else {
            finish(proxy: nil, error: "内部错误：连接或回调接口不可用")
            return
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: MemoryLayout<UInt8>.alignment)
        defer { buffer.deallocate() }

        var offset: Int64 = 0
        var firstIndex = 0
        var offsets: [Int64] = []
        var elapsedMs: [Double] = []
        var errnos: [Int32] = []
        var lastSend = DispatchTime.now()

        func flush(force: Bool) {
            guard !offsets.isEmpty else { return }
            let now = DispatchTime.now()
            guard force || offsets.count >= 128 || now.uptimeNanoseconds - lastSend.uptimeNanoseconds > 200_000_000 else { return }
            let data = BatchCodec.encode(firstIndex: firstIndex, offsets: offsets,
                                         elapsedMs: elapsedMs, errnos: errnos)
            proxy.onBatch(data)
            firstIndex += offsets.count
            offsets.removeAll(keepingCapacity: true)
            elapsedMs.removeAll(keepingCapacity: true)
            errnos.removeAll(keepingCapacity: true)
            lastSend = now
        }

        while true {
            var (stop, pause) = flags()
            while pause && !stop {
                Thread.sleep(forTimeInterval: 0.1)
                (stop, pause) = flags()
            }
            guard !stop else { break }

            var done: Int = 0
            var readErrno: Int32 = 0
            var eof = false
            let started = DispatchTime.now().uptimeNanoseconds
            while done < blockSize {
                let n = pread(scanFD, buffer.advanced(by: done), blockSize - done, offset + Int64(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    readErrno = Int32(errno)
                    break
                }
                if n == 0 { eof = true; break }  // 到达盘末
                done += n
            }
            let elapsed = elapsedMsSince(started)

            var endOfDisk = false
            if readErrno != 0 {
                // 读取失败（EIO=5 即坏道）：记 errno，继续下一块——坏道是数据不是终点
                errnos.append(readErrno)
                elapsedMs.append(elapsed)
            } else if eof && done == 0 {
                endOfDisk = true
            } else {
                errnos.append(0)
                elapsedMs.append(elapsed)
                if eof { endOfDisk = true }
            }

            offsets.append(offset)
            offset += Int64(blockSize)
            flush(force: false)
            if endOfDisk { break }
        }
        flush(force: true)
        finish(proxy: proxy, error: nil)
    }

    private func elapsedMsSince(_ started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    private func finish(proxy: HelperClientProtocol?, error: String?) {
        lock.lock()
        if fd >= 0 { close(fd); fd = -1 }
        let already = didReportDone
        didReportDone = true
        lock.unlock()
        guard !already else { return }
        proxy?.onDone(error)
    }

    // MARK: 设备路径校验

    /// 纯路径白名单：只接受整盘裸设备节点（可独立测试，不依赖硬件）
    static func pathAllowed(_ path: String) -> Bool {
        path.range(of: HelperIdentifiers.devicePathPattern, options: .regularExpression) != nil
    }

    static func deviceProblem(_ path: String) -> String? {
        guard pathAllowed(path) else {
            return "只允许扫描整盘裸设备（/dev/rdiskN）"
        }
        var ls = stat()
        guard lstat(path, &ls) == 0 else {
            return "设备不存在：\(path)"
        }
        // 拒绝符号链接（防 TOCTOU：先 lstat 再 open 之间被替换）
        guard (ls.st_mode & S_IFMT) != S_IFLNK else {
            return "拒绝符号链接设备路径"
        }
        guard (ls.st_mode & S_IFMT) == S_IFCHR else {
            return "不是磁盘设备节点（期望 /dev/rdiskN 字符设备）"
        }
        return nil
    }
}

// MARK: - 连接管理 + 客户端身份校验

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let lock = NSLock()
    private var connectionCount = 0
    private var idleExitWork: DispatchWorkItem?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard verifyClient(newConnection) else {
            NSLog("[DiskProbeHelper] 拒绝未授权的连接（客户端身份校验失败）")
            return false
        }
        cancelIdleExit()
        // runner 由 connection 通过 exportedObject 强引用持有，随连接失效而释放；
        // 支持多个连接并存（但每次 startScan 前 ScanRunner 会拒绝并发扫描）
        let runner = ScanRunner()
        runner.attach(newConnection)
        lock.lock()
        connectionCount += 1
        lock.unlock()
        newConnection.exportedInterface = NSXPCInterface(with: HelperScanProtocol.self)
        newConnection.exportedObject = runner
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperClientProtocol.self)
        newConnection.invalidationHandler = { [weak self, weak runner] in
            runner?.detach()
            runner?.connectionDidInvalidate()
            self?.connectionClosed()
        }
        newConnection.resume()
        return true
    }

    /// 所有连接断开后空闲 60 秒退出，把常驻内存还给系统（下次连接 launchd 会按需拉起）
    private func connectionClosed() {
        lock.lock()
        connectionCount -= 1
        let idle = connectionCount <= 0
        lock.unlock()
        guard idle else { return }
        lock.lock()
        if idleExitWork == nil {
            let work = DispatchWorkItem { exit(0) }
            idleExitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        }
        lock.unlock()
    }

    private func cancelIdleExit() {
        lock.lock()
        idleExitWork?.cancel()
        idleExitWork = nil
        lock.unlock()
    }

    /// 用 audit token 找到调用方的 SecCode，校验：
    ///   - identifier 是本 app（local.diskprobe）
    ///   - 签名团队与 helper 自身一致（防别的签名替换 app 再驱动 root helper）
    private func verifyClient(_ connection: NSXPCConnection) -> Bool {
        // NSXPCConnection.auditToken 是 ObjC 私有属性，KVC 取出。
        // 不走 App Store 的本地工具，这是获取可靠调用方身份的标准做法；
        // pid 校验有 TOCTOU（连接建立后原进程死掉被复用 pid），不能用。
        guard let token = connection.value(forKey: "auditToken") as? audit_token_t else {
            return false
        }
        var tokenCopy = token
        let tokenData = withUnsafeBytes(of: &tokenCopy) { Data($0) }

        var clientCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary,
                                             [], &clientCode) == errSecSuccess,
              let client = clientCode else { return false }

        guard let clientID = signingIdentifier(client), clientID == HelperIdentifiers.appIdentifier else {
            return false
        }
        // 双方都必须由同一团队签名（ad-hoc 没有 OU，直接拒绝）
        guard let clientTeam = signingTeam(client),
              let selfCode = selfCode(),
              let selfTeam = signingTeam(selfCode),
              clientTeam == selfTeam else {
            return false
        }
        return true
    }

    private func selfCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return code
    }

    private func signingIdentifier(_ code: SecCode) -> String? {
        guard let staticCode = staticCode(code) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoIdentifier as String] as? String
    }

    private func staticCode(_ code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    /// 取调用方的签名团队 ID。优先用签名信息里的结构化字段（macOS 10.12+），
    /// 回退到 designated requirement 字符串解析（同时兼容带引号/不带引号两种格式）。
    private func signingTeam(_ code: SecCode) -> String? {
        guard let staticCode = staticCode(code) else { return nil }

        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any],
           let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
           !team.isEmpty {
            return team
        }

        var req: SecRequirement?
        var reqStr: CFString?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess,
              let req = req,
              SecRequirementCopyString(req, [], &reqStr) == errSecSuccess,
              let dr = reqStr as String? else { return nil }
        guard let match = dr.range(of: #"subject\.OU\]\s*=\s*"?([A-Z0-9]{10})"?"#,
                                   options: .regularExpression) else {
            return nil
        }
        // match 里再取连续 10 位大写字母数字，兼容有引号与无引号
        guard let teamRange = dr.range(of: #"[A-Z0-9]{10}"#, options: .regularExpression, range: match) else {
            return nil
        }
        return String(dr[teamRange])
    }
}

// MARK: - 入口

@main
struct HelperMain {
    static func main() {
        NSLog("[DiskProbeHelper] helper launched (pid %d)", getpid())
        // 注意：不要用 NSXPCListener.service()！它走 xpc_main 的"XPC Service"
        // check-in 路径，与 launchd daemon（MachServices）环境不匹配，
        // 会在 _xpc_copy_xpcservice_dictionary 处 SIGTRAP 崩溃（实测 macOS 26.4）。
        // daemon 必须用显式 mach 服务名：launchd 按 plist 里的 MachServices 建好
        // socket，这里用 LISTENER 模式认领。
        let listener = NSXPCListener(machServiceName: HelperIdentifiers.machServiceName)
        let delegate = HelperDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
    }
}
