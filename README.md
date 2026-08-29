# DiskProbe — macOS 硬盘坏道检测工具

macOS 原生硬盘检测工具（类似 DiskGenius 坏道检测），Swift + SwiftUI，Apple Silicon 原生。

## 使用（推荐：.app 双击启动）

```bash
cd ~/.zcode/workspace/default/DiskProbe
./make_app.sh            # 一键打包 → dist/DiskProbe.app
open dist/DiskProbe.app  # 双击启动
```

- 当前版本默认提供演示扫描；真实裸设备读取已因旧版特权模型存在安全风险而暂时禁用。
- 如果 macOS 提示"无法打开"，先执行：
  ```bash
  xattr -dr com.apple.quarantine dist/DiskProbe.app
  ```

## 开发调试

```bash
swift build                    # 编译
swift run DiskProbe            # 或直接运行 .build/debug/DiskProbe
# 单元测试需要完整 Xcode 工具链（Command Line Tools 不带测试框架）：
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 功能

| 功能 | 说明 |
|---|---|
| 磁盘列表 | 只显示**物理盘**（过滤 APFS 容器/磁盘镜像/虚拟盘），外置盘排前，标注系统盘/外置盘 |
| 扫描 | **演示扫描**（模拟数据）与**真实扫描**（特权 helper 只读裸设备）双模式；真实模式需先在 app 内安装特权助手 |
| 扫描地图 | 100×60 色块网格，实时进度/速度/ETA |
| 扫描控制 | 开始/暂停/继续/停止，阈值可调（Cmd+,） |
| SMART | smartctl 读取：温度/通电时间/健康/重映射扇区(HDD)/寿命(SSD)，不支持时明确提示 |

## 安全设计

- 旧版使用的 `AuthorizationExecuteWithPrivileges` 与 bundle 内 helper 已移除，避免本地提权和路径 TOCTOU。
- 真实裸设备读取仅会在签名校验、系统安装的 XPC privileged helper 完成后重新引入。
- 扫描前确认对话框，系统盘额外警告

## 目录结构

```
Sources/DiskProbeCore/   共享模型（DiskInfo / BlockStatus / 阈值）
Sources/DiskProbe/       SwiftUI app（枚举 / 扫描引擎 / SMART / 视图）
make_app.sh              打包脚本（.app + ad-hoc 签名）
HANDOFF.md               开发进度记录
```

## 依赖

- 需要 `smartctl`（brew install smartmontools）用于 SMART 信息；没有也能用扫描功能
- SMART 读取依赖 smartctl；当前版本不请求管理员权限
