import Foundation
import DiskProbeCore
import Security
import Darwin

// MARK: - DiskProbe 特权 helper（launchd daemon，root 权限）
//
// macOS 13+ 由 SMAppService 安装、11/12 由 SMJobBless 安装（同一个 helper 二进制，
// 内嵌 Info.plist/launchd plist 供 SMJobBless 使用），launchd 按需拉起。
// 只做一件事：对指定整盘裸设备做顺序只读扫描，把每块耗时/errno 回传给 app。
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
        guard !busy else { reply(tr("扫描已在进行中", "A scan is already in progress")); return }
        guard blockSize >= 512, blockSize <= 4 * 1024 * 1024 else {
            reply(tr("块大小超出允许范围（512B–4MB）", "Block size out of allowed range (512B–4MB)"))
            return
        }
        if let problem = Self.deviceProblem(devicePath) {
            reply(problem)
            return
        }
        let newFD = open(devicePath, O_RDONLY)
        guard newFD >= 0 else {
            // root 也会被 TCC 拦：读取裸设备需要完全磁盘访问权限（Full Disk Access）
            if errno == EPERM {
                reply(tr("[TCC] macOS 隐私保护拦截了裸设备读取。请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中添加 DiskProbe（App），然后重新扫描。若仍失败，把 helper 二进制（DiskProbe.app/Contents/Library/LaunchServices/local.diskprobe.helper）也加入列表。", "[TCC] macOS privacy protection blocked raw-device access. Add DiskProbe (the app) under System Settings → Privacy & Security → Full Disk Access, then scan again. If it still fails, also add the helper binary (DiskProbe.app/Contents/Library/LaunchServices/local.diskprobe.helper)."))
                return
            }
            reply(tr("无法打开 \(devicePath)：\(String(cString: strerror(errno)))（errno \(errno)）", "Cannot open \(devicePath): \(String(cString: strerror(errno))) (errno \(errno))"))
            return
        }
        // 绕过页缓存：测的是真实盘面而不是内存缓存
        guard fcntl(newFD, F_NOCACHE, 1) == 0 else {
            let msg = String(cString: strerror(errno))
            close(newFD)
            reply(tr("设置 F_NOCACHE 失败：\(msg)", "Failed to set F_NOCACHE: \(msg)"))
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

    /// 复检阈值：单次读 ≥ 此值的块视为可疑，最多再读 2 次取最优。
    /// 远低于 app 默认警告阈值（100ms），健康盘（HDD ~20ms）的块永不复检，零开销。
    /// 目的：剔除系统 IO 抖动造成的"假慢块/假坏块"，让同一块盘多次扫描结果稳定。
    static let verifyThresholdMs: Double = 50
    static let maxAttempts = 3

    private func runLoop(fd scanFD: Int32, blockSize: Int) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard scanFD >= 0, let connection, let proxy = connection.remoteObjectProxy as? HelperClientProtocol else {
            finish(proxy: nil, error: tr("内部错误：连接或回调接口不可用", "Internal error: connection or callback interface unavailable"))
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

            // 逐块读取（可疑块复检，取最好成绩）
            var bestElapsed: Double? = nil
            var lastErrno: Int32 = 0
            var lastElapsed: Double = 0
            var endOfDisk = false

            for attempt in 0..<Self.maxAttempts {
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
                    if n == 0 {
                        // 到达盘末。提前 EOF（远小于容量）意味着设备/桥接异常，
                        // 打印现场便于排查（stdout/stderr 进 helper 日志）
                        NSLog("[DiskProbeHelper] EOF at offset %lld (block #%lld, done=%d)", offset, offset / Int64(blockSize), done)
                        eof = true; break
                    }
                    done += n
                }
                lastElapsed = elapsedMsSince(started)

                if eof {
                    // 盘末：done==0 表示恰好读完；done>0 是最后一块（不足 blockSize）
                    endOfDisk = true
                    if done > 0 {
                        if readErrno == 0 {
                            bestElapsed = lastElapsed
                            lastErrno = 0
                        } else {
                            lastErrno = readErrno
                        }
                    } else if readErrno != 0 {
                        lastErrno = readErrno
                    }
                    break
                }
                if readErrno != 0 {
                    // 读取失败：复检确认，连续失败才算坏块（EIO=5 即坏道）
                    lastErrno = readErrno
                    continue
                }
                if bestElapsed == nil || lastElapsed < bestElapsed! {
                    bestElapsed = lastElapsed
                }
                // 快块一次定论；慢块复检剔除抖动
                if bestElapsed! < Self.verifyThresholdMs || attempt == Self.maxAttempts - 1 {
                    break
                }
            }

            // eof 且无任何数据：不记录该块，直接结束
            let recordBlock = !(endOfDisk && bestElapsed == nil && lastErrno == 0)
            if recordBlock {
                if let e = bestElapsed, lastErrno == 0 {
                    errnos.append(0)
                    elapsedMs.append(e)
                } else {
                    // 读取失败（EIO=5 即坏道）：记 errno，继续下一块——坏道是数据不是终点
                    errnos.append(lastErrno)
                    elapsedMs.append(lastElapsed)
                }
                offsets.append(offset)
            }
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
            return tr("只允许扫描整盘裸设备（/dev/rdiskN）", "Only whole-disk raw devices are allowed (/dev/rdiskN)")
        }
        var ls = stat()
        guard lstat(path, &ls) == 0 else {
            return tr("设备不存在：\(path)", "Device does not exist: \(path)")
        }
        // 拒绝符号链接（防 TOCTOU：先 lstat 再 open 之间被替换）
        guard (ls.st_mode & S_IFMT) != S_IFLNK else {
            return tr("拒绝符号链接设备路径", "Symbolic-link device paths are rejected")
        }
        guard (ls.st_mode & S_IFMT) == S_IFCHR else {
            return tr("不是磁盘设备节点（期望 /dev/rdiskN 字符设备）", "Not a disk device node (expected /dev/rdiskN character device)")
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
        // 注意：KVC 装箱的 C 结构体必须用 NSValue.getValue 拷贝字节——
        // `as? audit_token_t` 在运行时恒为 nil，会把所有客户端（含合法 app）拒掉。
        guard let boxed = connection.value(forKey: "auditToken") as? NSValue else {
            NSLog("[DiskProbeHelper] 校验失败：KVC 未取到 auditToken")
            return false
        }
        var token = audit_token_t()
        boxed.getValue(&token)
        var tokenCopy = token
        let tokenData = withUnsafeBytes(of: &tokenCopy) { Data($0) }

        var clientCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary,
                                             [], &clientCode) == errSecSuccess,
              let client = clientCode else {
            NSLog("[DiskProbeHelper] 校验失败：SecCodeCopyGuestWithAttributes 失败")
            return false
        }

        let clientID = signingIdentifier(client)
        guard let clientID, clientID == HelperIdentifiers.appIdentifier else {
            NSLog("[DiskProbeHelper] 校验失败：identifier 不匹配（实际 \(clientID ?? "nil")）")
            return false
        }
        // 双方都必须由同一团队签名（ad-hoc 没有 OU，直接拒绝）
        let clientTeam = signingTeam(client)
        let selfTeam = selfCode().flatMap(signingTeam)
        guard let clientTeam, let selfTeam, clientTeam == selfTeam else {
            NSLog("[DiskProbeHelper] 校验失败：团队不匹配（client=\(clientTeam ?? "nil") self=\(selfTeam ?? "nil")）")
            return false
        }
        fputs("[DiskProbeHelper] 接受连接：identifier=\(clientID) team=\(clientTeam)\n", stderr)
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
