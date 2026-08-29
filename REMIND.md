# REMIND — 下次继续工作时先读这个

> 更新：2026-08-29。背景细节见 HANDOFF.md；历史审查结论的代码位置都标了 文件:行号。

## ✅ 2026-08-29 对抗式审查发现的问题——已全部修复

| # | 问题 | 位置 | 修法 |
|---|---|---|---|
| 🔴 1 | helper 拒绝/未安装时 `begin()` 永久挂起，UI 无响应 | RealScanSession.swift | invalidationHandler 唤醒 pendingAck + 15s 兜底超时（只 resume 一次，锁保护） |
| 🟠 2 | installHelper 的同步 `register()` 冻结主线程 | AppState.swift | register 放 `Task.detached`，完成后回主线程更新状态 |
| 🟠 3 | `stop()` 不关闭 XPC 会话，连接悬到下次扫描 | ScanEngine.swift stop() | stop 时 `close()` 并置 nil |
| 🟠 4 | helper 的 fd/stopFlag/pauseFlag 跨线程无锁 | HelperMain.swift | NSLock 统一保护；fd/连接在锁内读写 |
| 🟡 5 | 团队 ID 靠 DR 正则（要求带引号，格式不受契约保证） | HelperMain.swift signingTeam | 优先 `kSecCodeInfoTeamIdentifier` 结构化取值，DR 正则回退且兼容无引号 |
| 🟡 6 | helper 常驻不退出 | HelperMain.swift | 所有连接断开空闲 60s 后 `exit(0)`，launchd 按需再拉起 |
| 🟡 7 | runRealScan 逐块 yield，6000 格快照每批重复拷贝上百次 | ScanEngine.swift runRealScan | 整批处理完只 yield 一次 |
| 🟡 8 | 第二个连接顶掉 delegate 的单槽 runner 引用 | HelperMain.swift | 移除单槽，runner 由 connection 持有，支持多连接 |
| 🟡 9 | helperStatus 不随"从系统设置批准后返回"刷新 | ScanControlBar.swift | onAppear + scenePhase 变 active 时刷新 |
| 🟡 10 | "不是块设备节点"文案与 S_IFCHR 检查不符；unscanned 有 ±1 块漂移 | HelperMain / ScanEngine | 改文案；unscanned 由 totalBlocks − scanned 推导 |

修复后：swift build 无警告、19 测试全绿、`./make_app.sh` 重新打包（helper TeamIdentifier 有效）。

## 📌 工作方式提醒

- 跑测试：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  （CLT 下没有 XCTest/Testing 框架，直接 swift test 会报 no such module）。
- `swift run` / `swift build` 只能开发演示模式；**每次改完想测真实扫描必须
  `./make_app.sh` 重打包 + 重装 helper**（helper 签名变了 launchd 才会拉起新版本；
  必要时先 `sudo launchctl bootout system/local.diskprobe.helper`，再在 app 里重新 register）。
- `.build/` 和 `dist/` 都已 gitignore、可随时删除重建；仓库里不要提交构建产物。
- 旧版 AuthorizationExecuteWithPrivileges 提权方案是**废弃的安全漏洞方案**，
  任何"临时恢复"的提议都要拒绝（详见 HANDOFF.md 安全红线）。
- 注释里大量中文记录了踩坑原因（smartctl 退出码位掩码、diskutil "Unknown" 物理性、
  AsyncStream bufferingNewest(1) 依赖全量快照、begin 的 pendingAck 只能 resume 一次等），
  改代码前先读所在文件的头部注释。

## 🗺️ 后续可做（非 bug，按价值排序）

1. 真实扫描端到端验证：目前只在演示模式 + 代码审查层面验证过，找一块外置盘
   走完整流程（安装 helper → 卸载卷 → 真实扫描 → 对照 `dd`/SMART 自检结果）。
2. 扫描结果导出/报告（CSV：offset、耗时、errno）。
3. resume 时从上次断点继续扫描（现在停止后只能从头再来）。
4. 扫描结束后把 bad block 列表存盘，供后续复查对比。
