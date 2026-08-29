# DiskProbe — macOS 硬盘坏道检测工具

macOS 原生硬盘检测工具（类似 DiskGenius 坏道检测），Swift + SwiftUI，Apple Silicon 原生。
当前版本（2.1）为**真实只读坏道扫描**：SMAppService 特权 XPC helper 直接读取盘面。

## 使用（推荐：.app 双击启动）

```bash
cd ~/.zcode/workspace/default/DiskProbe
./make_app.sh            # 一键打包 → dist/DiskProbe.app（优先 Apple Development 签名）
open dist/DiskProbe.app  # 双击启动
```

- 首次使用：点「安装特权助手」→ 选盘 → 开始扫描（只读，不改数据）。
- **首次扫描若提示被隐私保护拦截**：在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中添加 DiskProbe（macOS 要求，root 也不豁免），app 内的「去授权」按钮可直达。
- **扫描报「特权助手未确认启动」**：说明注册信息过期（重新打包后常见），
  点控制条右侧的「重装」按钮重新注册即可。
- 必须从 .app bundle 启动（SMAppService 要求），`swift run` 模式下会明确报错。
- 打包脚本找不到 Apple Development 身份时无法使用（SMAppService 拒绝 ad-hoc daemon）。
- 如果 macOS 提示"无法打开"，先执行：
  ```bash
  xattr -dr com.apple.quarantine dist/DiskProbe.app
  ```

## 开发调试

```bash
swift build                    # 编译 app + DiskProbeHelper
swift run DiskProbe            # 运行 GUI app（仅演示扫描可用）
# 单元测试需要完整 Xcode 工具链（Command Line Tools 不带 XCTest/Testing 框架）：
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 功能

| 功能 | 说明 |
|---|---|
| 磁盘列表 | 只显示**物理盘**（过滤 APFS 容器/磁盘镜像/虚拟盘），外置盘排前，标注系统盘/外置盘 |
| 扫描 | **真实只读扫描**（特权 helper 读裸设备，F_NOCACHE 绕过页缓存），耗时分类：正常/慢速/异常/坏道 |
| 扫描地图 | 100×60 色块网格，引擎产出完整快照，实时进度/速度/ETA |
| 扫描控制 | 开始/暂停/继续/停止，阈值可调（Cmd+,，UserDefaults 持久化） |
| SMART | smartctl 读取：温度/通电时间/健康/重映射扇区(HDD)/寿命(SSD)，不支持时明确提示 |

## 安全设计（特权 helper）

- helper 以 root 权限 launchd daemon 运行（SMAppService 安装），**只读**：接口层没有任何写语义。
- 调用方校验：audit token → SecCode → 校验 identifier 为 `local.diskprobe` 且与 helper 同一签名团队；ad-hoc 直接拒绝。
- 设备白名单 `^/dev/rdisk[0-9]+$`（整盘裸设备），lstat 拒绝符号链接，stat 必须是字符设备。
- `O_RDONLY` 打开 + F_NOCACHE；app 断开连接时 helper 自动停止扫描。
- 旧版 `AuthorizationExecuteWithPrivileges` + bundle 内 helper 的提权方案**已废弃，不要再引入**。

## 目录结构

```
Sources/DiskProbeCore/    共享模型（DiskInfo / BlockStatus / 阈值 / XPC 协议 / BatchCodec）
Sources/DiskProbe/        SwiftUI app（枚举 / 扫描引擎 / RealScanSession / SMART / 视图）
Sources/DiskProbeHelper/  特权 helper（root daemon：ScanRunner + 客户端身份校验）
Tests/DiskProbeTests/     Swift Testing 单元测试（19 个）
make_app.sh               打包脚本（.app + helper 双签名 + LaunchDaemons plist）
HANDOFF.md                架构与开发进度记录
REMIND.md                 下次继续工作的注意事项（先读这个）
```

## 依赖

- `smartctl`（brew install smartmontools）用于 SMART 信息；没有也能扫描
- 真实扫描需要钥匙串里有效的 Apple Development 签名身份，并从 .app 启动
