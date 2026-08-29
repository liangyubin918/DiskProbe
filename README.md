# DiskProbe — macOS 硬盘坏道检测工具

**English**: A native macOS bad-sector scanner with a DiskGenius-style defect map, built with Swift/SwiftUI and a sandboxed-approval privileged helper. Strictly read-only — it never writes to your disk.

<!-- TODO: 应用截图（Cmd+Shift+4 截取窗口，保存为 docs/screenshot.png 后取消注释下一行）
![DiskProbe 主界面](docs/screenshot.png)
-->

## 这是什么

DiskProbe 是一款 macOS 原生硬盘坏道检测工具（对标 DiskGenius 的坏道检测）。它把整块硬盘按块顺序**只读**读取一遍，按每块的读取耗时给磁盘表面"体检"，并用一张 100×60 的色块地图把结果可视化：绿=正常、黄=慢速、红=异常、深红=坏道。

| 功能 | 说明 |
|---|---|
| 磁盘列表 | 只显示物理盘（过滤 APFS 容器/磁盘镜像/虚拟盘），外置盘排前，标注系统盘/外置盘 |
| 真实只读扫描 | 特权 helper 直接读裸设备（`F_NOCACHE` 绕过页缓存），速度/进度/坏道均为真实数据 |
| 扫描地图 | 100×60 色块网格，悬停查看格子编号/块编号/采样耗时，支持缩放（1×–16×）与平移 |
| 可疑块复检 | 单次读 ≥50ms 或失败的块自动重读最多 3 次取最优，坏块需连续失败才定论 |
| 扫描控制 | 开始/暂停/继续/停止，阈值可调（Cmd+,）并持久化 |
| SMART | smartctl 读取：健康/温度/通电时间/重映射扇区(HDD)/寿命(SSD) |
| 记录导出 | 扫描完成后导出 CSV（表格分析）或 JSON（完整报告，含地图快照） |

## 系统要求

- macOS 14 及以上，Apple Silicon 原生
- 签名证书：**不需要付费开发者账户**。安装 Xcode 并登录任意免费 Apple ID，钥匙串即自动获得 Apple Development 证书（免费证书 1 年有效，过期重新构建即可；iOS 上"7 天过期"的限制不适用于 macOS）
- 特权助手必须真实签名（SMAppService 拒绝 ad-hoc），make_app.sh 会自动检测证书
- `smartctl`（`brew install smartmontools`，仅 SMART 功能需要，没有也能扫描）
- **完全磁盘访问权限**：macOS 隐私保护要求读取裸设备必须授权，root 也不豁免；首次扫描按提示在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中添加本 app 即可

## 构建与运行

```bash
git clone https://github.com/liangyubin918/DiskProbe.git
cd DiskProbe
./make_app.sh                 # 编译 app + 特权 helper，打包并签名 → dist/DiskProbe.app
open dist/DiskProbe.app       # 双击启动
```

首次使用：点「安装特权助手」→ 选盘 → 开始扫描（全程只读，不修改任何数据）。

开发调试：

```bash
swift build                   # 编译（仅演示用途；真实扫描必须从 .app 启动）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 单元测试（27 个）
```

## 工作原理

```
DiskProbe.app（用户权限，SwiftUI）
  ├─ DiskEnumerator      IOKit + diskutil 枚举物理整盘
  ├─ SMARTReader         smartctl -j -a 解析 SMART
  └─ ScanEngine (actor)  消费扫描批次 → 分类/统计/地图快照/速度/ETA

        ▲ XPC（audit token 校验调用方身份）
        ▼

DiskProbeHelper（root 权限 launchd daemon，SMAppService 安装）
  └─ 逐块 pread 计时（O_RDONLY + F_NOCACHE），批次回传约 20 字节/块
```

检测方法与 DiskGenius 等工具一致：顺序只读扫描，按单块读取耗时分级（<100ms 正常，100–500ms 警告，≥500ms 异常，读取失败为坏道）。只读不写，任何情况下不会修改磁盘数据。

## 安全设计

特权 helper 以 root 运行，安全是第一约束：

- 调用方校验：audit token → SecCode → 校验 identifier 与签名团队，未签名/异签名进程一律拒绝
- 设备白名单 `^/dev/rdisk[0-9]+$`，lstat 拒绝符号链接，stat 必须为字符设备
- 设备以 `O_RDONLY` 打开，XPC 接口层不存在任何写语义
- app 断开连接时 helper 自动停止扫描；空闲 60 秒自动退出
- 旧版 `AuthorizationExecuteWithPrivileges` 提权方案存在本地提权漏洞，已彻底废弃

踩坑记录（SMAppService daemon 的 `NSXPCListener.service()` 崩溃、KVC auditToken 强转陷阱、TCC 授权等）见 [REMIND.md](REMIND.md)，完整架构与开发背景见 [HANDOFF.md](HANDOFF.md)。

## License

[MIT](LICENSE)
