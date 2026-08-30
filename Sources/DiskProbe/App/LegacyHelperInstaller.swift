import Foundation
import ServiceManagement
import Security
import DiskProbeCore

// MARK: - macOS 11/12 特权 helper 安装器（SMJobBless 路径）

/// SMAppService 是 macOS 13+ 才有的 API；11/12 上用 SMJobBless（13 起标记弃用，
/// 但在旧系统上是唯一机制，不存在被移除的风险；本类型只在 macOS 13 以下被调用）。
///
/// 前提（缺一不可，均已在工程里配置）：
///   - app Info.plist：SMPrivilegedExecutables 声明 helper 的签名要求（make_app.sh 生成）
///   - helper 二进制内嵌 Info.plist（含 SMAuthorizedClients）与 launchd plist
///     （Package.swift 链接参数 -sectcreate 写进 __TEXT 段）
///   - helper 在 bundle 内必须以 launchd label 命名：Contents/Library/LaunchServices/local.diskprobe.helper
///   - app 与 helper 同一签名身份（Apple Development 证书）
///
/// 签名要求串用 identifier + anchor apple generic（不锁定 Team ID，因为内嵌 plist
/// 是静态文件、无法按机器注入 Team ID）。跨团队冒用由 helper 自身的 XPC 客户端
/// 校验兜底（HelperMain 校验同一签名团队 + app identifier），且安装本身仍需管理员密码。
///
/// 安装结果：helper 落到 /Library/PrivilegedHelperTools/local.diskprobe.helper，
/// launchd plist 落到 /Library/LaunchDaemons/local.diskprobe.helper.plist，
/// MachServices 名字与 SMAppService daemon 一致，XPC 通信代码完全复用。
enum LegacyHelperInstaller {
    /// 与 helper 内嵌 launchd plist 的 Label、app 侧 SMPrivilegedExecutables 的 key 一致
    static let helperLabel = HelperIdentifiers.machServiceName

    /// kSMRightBlessPrivilegedHelper / kSMRightModifySystemDaemons 的 C 宏不导入 Swift，用字面值
    private static let blessRight = "com.apple.ServiceManagement.blesshelper"
    private static let modifyDaemonsRight = "com.apple.ServiceManagement.modifySystemDaemons"

    static var helperToolPath: String { "/Library/PrivilegedHelperTools/\(helperLabel)" }
    static var launchdPlistPath: String { "/Library/LaunchDaemons/\(HelperIdentifiers.launchdPlistName)" }

    /// 是否已安装（文件存在即视为已注册；真实可用性由 ping 端到端验证）
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperToolPath)
            && FileManager.default.fileExists(atPath: launchdPlistPath)
    }

    /// 安装（系统弹管理员密码确认）。返回 nil = 成功；非 nil = 可读错误。
    /// 同步阻塞调用（等用户输密码可能数秒），调用方须放后台线程。
    static func install() -> String? {
        var authRef: AuthorizationRef? = nil
        var cfError: Unmanaged<CFError>? = nil
        defer { freeAuth(&authRef) }
        guard acquireAuthorization(right: blessRight, into: &authRef) else {
            return "已取消，特权助手未做更改。"
        }
        guard SMJobBless(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, &cfError) else {
            let message = cfError?.takeRetainedValue().localizedDescription ?? "未知错误"
            return "SMJobBless 失败：\(message)"
        }
        return nil
    }

    /// 卸载（重装 = 先卸后装；也用于 macOS 13+ 上清理从旧系统升级来的残留）。
    /// 返回 nil = 成功（含"本来就没装"）；非 nil = 可读错误。同步阻塞调用。
    static func remove() -> String? {
        guard FileManager.default.fileExists(atPath: helperToolPath)
            || FileManager.default.fileExists(atPath: launchdPlistPath) else {
            return nil
        }
        var authRef: AuthorizationRef? = nil
        var cfError: Unmanaged<CFError>? = nil
        defer { freeAuth(&authRef) }
        guard acquireAuthorization(right: modifyDaemonsRight, into: &authRef) else {
            return "已取消，未移除旧版特权助手。"
        }
        // wait=true：阻塞到旧 helper 进程退出，避免重装时端口占用
        guard SMJobRemove(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, true, &cfError) else {
            let message = cfError?.takeRetainedValue().localizedDescription ?? "未知错误"
            return "SMJobRemove 失败：\(message)"
        }
        // SMJobRemove 理论上会一并清理工具文件，这里兜底清残留（无 root 时静默失败）
        try? FileManager.default.removeItem(atPath: helperToolPath)
        try? FileManager.default.removeItem(atPath: launchdPlistPath)
        return nil
    }

    // MARK: 授权

    /// 以管理员权限获取指定 right（交互式弹窗；用户取消返回 false）
    private static func acquireAuthorization(right: String, into authRef: inout AuthorizationRef?) -> Bool {
        var granted = false
        right.withCString { namePtr in
            var item = AuthorizationItem(name: namePtr, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                let status = AuthorizationCreate(&rights, nil, flags, &authRef)
                granted = status == errAuthorizationSuccess && authRef != nil
            }
        }
        return granted
    }

    private static func freeAuth(_ authRef: inout AuthorizationRef?) {
        if let ref = authRef {
            AuthorizationFree(ref, AuthorizationFlags())
            authRef = nil
        }
    }
}
