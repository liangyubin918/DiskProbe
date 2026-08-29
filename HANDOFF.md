# DiskProbe — 开发交接记录（HANDOFF）

> 最后更新：2026-08-29。**先读 REMIND.md**（当前待办与注意事项），本文件是完整背景。

## 项目概述

macOS 原生硬盘坏道检测工具（对标 DiskGenius 坏道检测），Swift 6 + SwiftUI，Apple Silicon。
纯自用，不上架 App Store。当前版本 2.0：**真实只读扫描已上线**（SMAppService 特权 XPC helper），
并保留不接触设备的演示模式。

## 检测原理

顺序只读扫描：把整盘按块（64KB–1MB，默认 128KB）逐块 `pread`，按单块耗时分类：

| 耗时 | 状态 | 颜色 |
|---|---|---|
| < warnMs（默认 100ms） | normal | 绿 |
| warnMs ..< abnormalMs | warning | 黄 |
| ≥ abnormalMs（读取成功） | abnormal | 红 |
| 读取失败（errno，EIO=5 典型坏道） | error | 深红 |

只读不写，任何模式都不会修改磁盘数据。阈值在设置窗口（Cmd+,）可调，UserDefaults 持久化
（key：`scan.warnMs` / `scan.abnormalMs`）。

## 架构

```
DiskProbe.app（普通用户权限，SwiftUI）
  ├─ AppState（@MainActor，UI 状态；进度流单一消费者 listenerTask）
  ├─ ScanEngine（actor；演示/真实双模式共用分类/统计/地图/速度逻辑）
  │    └─ runRealScan ← AsyncStream<ScanBatch> ← RealScanSession（XPC 客户端）
  ├─ DiskEnumerator（IOKit IOMedia Whole + diskutil info -plist 过滤物理整盘）
  └─ SMARTReader（smartctl -j -a；解析时不得依赖退出码为 0——退出码是位掩码）

DiskProbeHelper（root 权限 launchd daemon，SMAppService 安装）
  ├─ ScanRunner：O_RDONLY + F_NOCACHE 打开 /dev/rdiskN，逐块 pread 计时，
  │   批次回传（BatchCodec 二进制：约 20 字节/块，128 块或 200ms 一批）
  └─ HelperDelegate：audit token → SecCode 校验调用方（identifier + 同签名团队）

DiskProbeCore（共享）：DiskInfo / BlockStatus / ScanThresholds /
  HelperScanProtocol / HelperClientProtocol（@objc XPC 双向协议）/ BatchCodec
```

关键设计决策：

- **进度是全量快照**：引擎随每个进度事件附带完整 mapCells + 累计 summary，
  `AsyncStream` 用 `bufferingNewest(1)`——事件被丢弃不影响正确性。
- **XPC 批次编码**：`magic(4)|count(4)|firstIndex(8)|offsets(8n)|elapsedMs(8n)|errnos(4n)`，
  全小端；decode 严格校验长度与 magic，垃圾数据直接拒绝。
- **helper 生命周期**：launchd 按需拉起（MachServices），app 断开自动停扫；
  当前实现常驻不退出（见 REMIND.md 待改进项）。

## 签名与安装（make_app.sh）

1. `swift build` 编译 app + helper 两个可执行文件；
2. 组装 .app：helper 放 `Contents/Library/LaunchServices/`，launchd plist 放
   `Contents/Library/LaunchDaemons/local.diskprobe.helper.plist`（BundleProgram 相对路径）；
3. 签名：**先签 helper（--identifier local.diskprobe.helper），再签 app（--identifier local.diskprobe）**，
   外层签名封存内层。用钥匙串里的 Apple Development 身份；找不到则 ad-hoc（仅演示模式）；
4. 用户在 app 内点「安装特权助手」→ `SMAppService.daemon(plistName:).register()` → 系统设置批准。

历史坑：钥匙串缺 WWDR G3 中间证书导致 Apple Development 身份 NOT_TRUSTED，
已从 apple.com/certificateauthority 导入（有效期至 2030）。

## 安全红线（不要回退）

- **绝对不要**恢复 `AuthorizationExecuteWithPrivileges` 或把 helper 以可被用户替换的方式提权执行。
- helper 的安全约束缺一不可：audit token 身份校验（不能用 pid，有 TOCTOU）、
  设备路径白名单 `^/dev/rdisk[0-9]+$`、lstat 拒绝符号链接、O_RDONLY、无写语义接口。
- SMAppService daemon 的可执行文件留在 app bundle 内由 launchd 校验签名后拉起，
  这是官方机制，不要"优化"成复制到共享目录。

## 开发环境备忘

- macOS 26.4 / arm64 / Swift 6.3.2；`xcode-select` 指向 CLT → **跑测试必须
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`**（CLT 无 XCTest/Testing）。
- 测试框架用 Swift Testing（`import Testing`），19 个测试。
- DiskArbitration 在 CLT SDK 下 Swift overlay 缺 `DADiskGetDescription`，磁盘枚举走 IOKit + diskutil。
- 测试运行后如遇 codesign/钥匙串弹窗，属测试进程签名行为，正常。

## 已验证

- swift build（debug/release）通过；19 测试全绿（含 BatchCodec 往返/垃圾拒绝、
  设备路径白名单、阈值分类边界、地图分组 >4.7TB 回归）。
- `./make_app.sh` 打包 + Apple Development 双签名通过（2026-08-29）。
- 历史修复记录见 git log（基线 324bfc8 → 修复 9184394 → 优化 e9cf79b → 真实扫描 717530b）。

## 当前已知问题

见 REMIND.md「待修复 bug 清单」（对抗式审查 2026-08-29 结论，尚未修复）。
