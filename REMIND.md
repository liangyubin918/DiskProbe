# REMIND — 下次继续工作时先读这个

> 更新：2026-08-29。背景细节见 HANDOFF.md；审查结论的代码位置都标了 文件:行号。

## ⚠️ 待修复 bug 清单（2026-08-29 对抗式审查，按严重度排序，均未修复）

### 🔴 1. RealScanSession.begin 可能永久挂起
`Sources/DiskProbe/Scan/RealScanSession.swift:35-50`：`withCheckedContinuation` 等
helper 的 startScan 回执，但如果 helper **拒绝连接**（身份校验失败）或 **根本没安装**，
连接直接 invalidate，回执永远不会来 → `await session.begin` 永久挂起。
用户现象：真实模式下点「开始扫描」没有任何反应，也不报错。
修法：在 `invalidationHandler` 里若尚未 acked 则 `cont.resume(returning: false)`，
或给 begin 加超时。**修之前不要让用户用真实模式。**

### 🟠 2. installHelper 阻塞主线程
`Sources/DiskProbe/App/AppState.swift`（installHelper）：`SMAppService.register()` 是
同步调用，却在 @MainActor 的 Task 里执行，输密码弹窗期间整个 UI 冻结。
修法：`Task.detached { try service.register() }` 后回主线程更新状态。

### 🟠 3. stop() 不关闭真实扫描会话
`Sources/DiskProbe/Scan/ScanEngine.swift:129-140`：`stop()` 只调了 `realSession?.stop()`
（通知 helper 停），没有 `close()`，XPC 连接和 session 一直被 engine 持有到下次 start
才被覆盖释放。修法：stop() 里 close 掉 session（runRealScan 的 isCurrent 检查保证不会误用）。

### 🟠 4. ScanRunner 标志位跨线程无同步
`Sources/DiskProbeHelper/HelperMain.swift`：`stopFlag`/`pauseFlag`/`fd` 被 XPC 连接队列
（start/pause/stop）和扫描队列（runLoop）无锁共享，属数据竞争（实际危害低但应修）。
修法：加 NSLock / OSAllocatedUnfairLock 保护。

### 🟡 5. 团队 ID 正则依赖 DR 字符串带引号
`HelperMain.swift:268`：`#"subject\.OU\]\s*=\s*"([A-Z0-9]{10})"#` 要求值带引号。
codesign 当前输出带引号，但格式不受契约保证；失败时是 fail-closed（拒绝所有连接），
症状会是"真实扫描全部连不上"。更稳的做法：用 `SecCodeCopyDesignatedRequirement` 后
`SecRequirementCreateWithACL`？或直接比较 `kSecCodeInfoTeamIdentifier`（signing info 里
有该 key？确认后改用结构化取值）。

### 🟡 6. 其他小问题
- helper 常驻不退出（`HelperMain.swift` RunLoop 永远跑）：可加空闲退出定时器。
- `runRealScan` 对每个块 yield 一次带完整 6000 格快照的进度，一批 128 块重复拷贝
  128 次：改成每批 yield 一次（`ScanEngine.swift:307`）。
- helper 只认一个 `self.runner` 槽位（`HelperMain.swift:189`），第二连接会顶掉引用；
  实际生命周期靠 connection 持有 exportedObject 兜底，建议显式支持多连接或拒绝第二个。
- `helperStatus` 只有初始化和切换模式时刷新：用户从系统设置批准后回来 UI 不更新。
- `deviceProblem` 报错文案"不是块设备节点"，实际检查的是 S_IFCHR（字符设备），文案不符。
- `summary.unscanned` 依赖 diskutil Size 与实际可读字节数一致，个别盘可能有 ±1 块误差。

## 📌 工作方式提醒

- 跑测试：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  （CLT 下没有 XCTest/Testing 框架，直接 swift test 会报 no such module）。
- `swift run` / `swift build` 只能开发演示模式；**每次改完想测真实扫描必须
  `./make_app.sh` 重打包 + 重装 helper**（SMAppService 记录的签名会校验，
  重新打包后需要重新 register——helper 签名变了 launchd 才会拉起新版本，
  必要时先 `sudo launchctl bootout system/local.diskprobe.helper`）。
- `.build/` 和 `dist/` 都已 gitignore、可随时删除重建；仓库里不要提交构建产物。
- 旧版 AuthorizationExecuteWithPrivileges 提权方案是**废弃的安全漏洞方案**，
  任何"临时恢复"的提议都要拒绝（详见 HANDOFF.md 安全红线）。
- 注释里大量中文记录了踩坑原因（smartctl 退出码位掩码、diskutil "Unknown" 物理性、
  AsyncStream bufferingNewest(1) 依赖全量快照等），改代码前先读所在文件的头部注释。
