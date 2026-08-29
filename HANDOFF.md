# DiskProbe — 硬盘坏道检测工具 进度记录

## 项目概述
macOS 原生硬盘检测工具（类似 DiskGenius 坏道检测），Swift + SwiftUI，面向 Apple Silicon。
纯自用，不上架 App Store。

## 技术决策记录

### 已确认的关键约束
| 约束 | 结论 |
|---|---|
| 环境 | macOS 26.4 / arm64 / Swift 6.3.2，CLT（无 Xcode.app 但用户有 Xcode） |
| 权限方案 | 第三步需要特权助手（`SMJobBless` 或 `SMAppService.daemon` + XPC） |
| 磁盘列表 | ✅ IOKit 枚举 IOMedia + `diskutil info -plist` 取详细信息 |
| DiskArbitration | ❌ CLT SDK 的 Swift overlay 缺少 `DADiskGetDescription`，弃用 |
| 沙盒 | 不启用（裸磁盘读取物理上无法沙盒化） |
| 交付 | SPM Package（`swift build`）；用户也可在 Xcode 中 Open Package.swift |

---

## 第一步：方案分析 ✅ 完成

### 核心架构
```
DiskProbe.app (SwiftUI UI)
  ├─ DiskEnumerator  →  IOKit + diskutil  枚举磁盘
  ├─ ScanEngine (actor)  →  async/await 扫描
  ├─ AppState (@MainActor)  →  UI 状态管理
  └─ [第三步] XPCClient  →  特权助手

DiskProbeHelper [第三步]
  └─ 以 root 打开 /dev/rdiskN，pread() 只读，返回耗时
```

### 安全设计
- 扫描仅 `pread` + `O_RDONLY`，绝不写入
- 助手内部白名单禁止 write/fcntl 写标志
- 扫描前确认对话框，系统盘额外警告
- 阈值可调（设置窗口 Cmd+,）

---

## 第二步：最小可运行版本 ✅ 完成

### 修改的文件
| 文件 | 作用 |
|---|---|
| `Package.swift` | SPM 清单，macOS 14+，两个 target（DiskProbeCore + DiskProbe） |
| `Sources/DiskProbeCore/Models.swift` | BlockStatus 枚举、ScanThresholds、ScanBlock 模型 |
| `Sources/DiskProbeCore/DiskInfo.swift` | DiskInfo 模型、ByteSizeFormatter |
| `Sources/DiskProbe/Disk/DiskEnumerator.swift` | IOKit + diskutil 枚举整盘 |
| `Sources/DiskProbe/Scan/ScanEngine.swift` | actor，扫描状态机，AsyncStream 进度推送（**当前模拟数据**） |
| `Sources/DiskProbe/App/DiskProbeApp.swift` | SwiftUI @main 入口 |
| `Sources/DiskProbe/App/AppState.swift` | @MainActor 全局状态，连接枚举器与扫描引擎 |
| `Sources/DiskProbe/Views/RootView.swift` | 根布局：左侧磁盘列表 + 右侧扫描面板 |
| `Sources/DiskProbe/Views/DiskListView.swift` | 磁盘列表（按外置/内置分组） |
| `Sources/DiskProbe/Views/ScanPanelView.swift` | 右侧面板：头部信息 + 控制条 + 地图 + 统计 + 确认对话框 |
| `Sources/DiskProbe/Views/ScanControlBar.swift` | 开始/暂停/继续/停止 + 块大小选择 |
| `Sources/DiskProbe/Views/ScanMapView.swift` | 扫描地图可视化（Canvas 色块条）+ 进度/速度/ETA |
| `Sources/DiskProbe/Views/ScanStatBar.swift` | 底部统计栏 + 健康结论 |
| `Sources/DiskProbe/Views/SettingsView.swift` | 设置窗口：阈值调整 |

### 如何运行
```bash
cd DiskProbe
swift build                   # 编译
.build/debug/DiskProbe        # 运行（需要 GUI 会话）
```
或在 Xcode 中：`File > Open` → 选 `Package.swift` → Cmd+R

### 当前功能
- ✅ 真实磁盘列表（自动枚举你机器上的磁盘，外置盘排前面）
- ✅ 点击磁盘显示详情头部
- ✅ 模拟扫描（0.3% 警告/异常、0.05% 错误的概率分布）
- ✅ 实时进度条（百分比、速度 MB/s、已用时间、预计剩余）
- ✅ 扫描地图色块条（绿/黄/红/深红/灰）
- ✅ 统计栏 + 健康结论
- ✅ 开始/暂停/继续/停止控制
- ✅ 块大小可选（64KB~1MB）
- ✅ 阈值可调（设置窗口）
- ✅ 系统盘标注 + 扫描前确认对话框

### 已知限制（第二步）
1. **扫描是模拟数据**，第三步替换为真实 `pread`
2. **扫描地图是比例条**（按 summary 比例画色段），尚未逐块绘制网格
3. **没有 SMART 信息**
4. **虚拟盘（磁盘镜像）未精确过滤**（isVirtual 恒 false）

---

## 第三步：旧版真实磁盘读取方案 ❌ 已撤回（安全审查后）

> 2026-08-20：旧版通过 `AuthorizationExecuteWithPrivileges` 提升 app bundle 内 helper，且以临时文件路径传递控制/结果。该方案存在 helper 替换导致本地提权，以及符号链接 TOCTOU 特权写入风险，已从构建与打包流程移除。当前仅保留演示扫描。
>
> 下一步必须采用签名校验的 XPC privileged helper（`SMAppService` 或 `SMJobBless`）并避免以用户可控路径作为特权 IPC；在此之前不得恢复真实读取开关。

### 历史实现方案（禁止恢复）
以下内容仅保留作审查历史，不可作为实现参考：

```
DiskProbe.app (普通权限, SwiftUI)
  └─ ScanEngine (actor)
       └─ RealDiskReader (actor)
            ├─ 启动: sudo DiskProbeRead /dev/rdisk4   ← 弹一次密码
            ├─ stdin: "<offset> <count>\n"  (每条指令)
            └─ stdout: {"ok":true,"elapsed_ms":3.27,...} (每行 JSON)
```

- helper 保持运行，**只启动一个 sudo 进程**（弹一次密码），后续所有块读复用同一进程
- macOS 缓存 sudo 凭证 ~5 分钟，超时后需重新认证

### 修改的文件
| 文件 | 变化 |
|---|---|
| `Package.swift` | 新增 `DiskProbeRead` executable target |
| `Sources/DiskProbeRead/main.swift` | 新增：特权读取助手（流模式 + 单块模式） |
| `Scan/ScanEngine.swift` | `DiskReader` 协议 + `RealDiskReader`(sudo 流式) + `MockDiskReader`；`runScan` 改用 reader |
| `App/AppState.swift` | 地图格子增量更新（100×60 固定网格）；sudo 认证状态 |
| `Views/ScanControlBar.swift` | 真实/模拟切换开关 + 认证提示 |
| `Views/ScanPanelView.swift` | 确认框提示真实模式需密码 |
| `Views/ScanMapView.swift` | 从比例条 → 逐格 Canvas 色块网格 |

### 安全设计（helper 内）
- 设备路径白名单：仅 `/dev/rdisk[0-9]+`
- 硬编码 `O_RDONLY`，打开后 `fcntl(F_GETFL)` 二次校验只读
- 单块上限 16 MB
- 无写入路径：任何情况下不写设备

### 如何测试
```bash
cd DiskProbe
swift build
.build/debug/DiskProbe
```
→ 选左侧"外置硬盘"（Westen Digital）→ 确认「真实读取」开关已开 →
点「开始扫描」→ 输入管理员密码 → 观察地图实时滚动。

### 已完成的单元验证（CLT 环境）
- ✅ helper 编译为独立二进制
- ✅ 无 sudo 读取 → `{"ok":false,"errno":"13"}`（EACCES 正确）
- ✅ 设备白名单：`/etc/passwd`、`/dev/disk4`（非 rdisk）被拒绝
- ✅ 参数校验：负数 offset / 超大 count → exit 1
- ✅ 流模式 stdin 协议正确（read → JSON 行 → quit）
- ⏳ 真实读 disk4 需在 GUI 会话输密码，等用户实机验证

### 已知问题
- `RealDiskReader.authenticate()` 里 `Process.waitUntilExit` 是阻塞的
  （actor 内 OK，不卡 UI；但 stop 时若在 wait 中会等 helper 退出）
- 扫描整盘时间 = 块数 × 单块耗时。500GB/128KB ≈ 390 万块 × ~5ms ≈ 5.4 小时，
  建议用 512KB 或 1MB 块大小（约 1.4 小时）。后续可加"区间扫描"（只扫指定字节段）。

---

## 第四步：SMART 信息 ✅ 已完成

### 实现方案
用 **smartctl**（smartmontools，用户机器已装 7.5）+ JSON 解析。
不自己实现 IOKit SMART 协议（Apple 私有 NVMe 协议复杂且未公开）。

### 修改的文件
| 文件 | 作用 |
|---|---|
| `Sources/DiskProbe/SMART/SMARTReader.swift` | 新增：smartctl -j 解析 → SMARTInfo 模型 |
| `Sources/DiskProbe/Views/SMARTSummaryBar.swift` | 新增：头部 SMART 摘要条（健康/温度/通电/重映射/寿命） |
| `App/AppState.swift` | 新增 `refreshSMART()`，选中盘切换时自动读取 |

### 支持与降级
- **HDD（SATA/USB-SAT）**：温度、通电时间、重映射扇区(5)、待定扇区(197)、离线不可纠正(198)
- **NVMe SSD（内置）**：温度、通电时间、寿命已用%、已写数据量
- **不支持 SMART 的盘/硬盘盒**：明确显示错误（"该磁盘（或硬盘盒）不支持 SMART"）
- **未装 smartctl**：提示 `brew install smartmontools`

### 端到端验证（真实 disk4）
```
磁盘: disk4  (ST500LT012-1DG142, 希捷 500GB)
健康: PASSED
温度: 34°C
通电: 2263h
重映射扇区: 0 | 待定扇区: 0 | 离线不可纠正: 0   ← 健康
```
内置盘 disk0 (Apple SSD AP0512Z) 也支持 NVMe SMART（Log 0x02）。

### 踩坑
- smartctl JSON 的 `raw.value` 对多字节属性不可靠（Power_On_Hours raw=185701500979415 是错的），
  正确数值在 `raw.string` 前缀里（"2263 (168 229 0)" → 2263）。已用 `parseInt(prefix)` 修复并单测通过。

---

## 第五步：Bug 修复 + .app 打包 ✅ 已完成

### 用户反馈的 4 个问题，全部解决

**问题1：枚举出 9 个盘（实际只有 2 个）**
- 根因：枚举器把所有 Whole=true 的 Media 都算上，含 APFS 合成容器（disk1/2/3）、磁盘镜像（disk6/7/8/9）
- 修复：解析 `diskutil info -plist` 的 `VirtualOrPhysical` 字段，只过滤明确为 `Virtual` 的
- ⚠️ 注意：Apple Silicon 内置盘（disk0）该字段是 `"Unknown"`，**必须保留**，只滤 Virtual

**问题2：每个盘都标成系统盘**
- 根因：`isInternal = !isExternal` 对虚拟盘误判
- 修复：改用 diskutil 的 `Internal` 布尔字段；过滤虚拟盘后自然只剩真实盘

**问题3：要输命令启动，不是 .app**
- 新增 `make_app.sh`：`swift build` → 组装 `dist/DiskProbe.app`（Info.plist + 主程序 + helper）→ ad-hoc 签名
- 产物仅 1.5MB，双击即可启动
- 用户有 Xcode 时也可直接打开 Package.swift

**问题4：没用的文件占空间**
- 删除 /tmp 下全部临时测试文件
- 删除 .DS_Store
- 说明：`.build` 是构建缓存（305MB），可 `swift package clean` 或直接删除重建

### 验证结果（真实机器）
```
过滤前: disk0-4, disk6-9 (9 个)
过滤后: disk0 (系统盘, Apple SSD AP0512Z) + disk4 (外置, USB)  ✅ 与事实一致
```

### 修改的文件
- `Sources/DiskProbe/Disk/DiskEnumerator.swift` — VirtualOrPhysical 过滤逻辑
- `make_app.sh` — 新增打包脚本
- `README.md` — 新增使用说明
- 删除：/tmp 临时文件、.DS_Store

---

## 第六步：Bug 修复（v4 架构 — AuthorizationServices）✅ 已完成

### 用户反馈的 3 个 bug + 新增的 .app 问题，全部修复

**Bug 1：命令启动有密码弹窗但报错**
- 根因（第一性原理实证）：osascript 的 `do shell script ... with administrator privileges`
  在 CLI/GUI 混合会话里**卡住或行为不稳定**（实测卡 3 秒不返回、nohup 报
  "can't detach from console"），helper 从未正确以 root 启动
- 修复：彻底弃用 osascript/sudo/shell，改用 **AuthorizationServices** 直接弹系统密码框

**Bug 2：.app 直接打开连密码弹窗都没有**
- 根因：同 Bug 1（osascript 链路不可靠），且 .app 从 LaunchServices 启动时
  上下文与终端不同，osascript 行为更不稳定
- 修复：AuthorizationServices 不依赖 shell/GUI 会话，从 app 内直接弹框

**Bug 3：系统盘温度 -237°C**
- 根因（第一性原理实证）：**smartctl 7.5 的 NVMe JSON `temperature` 已是摄氏度**（实测 37），
  我错误地假设它是开尔文又减了 273 → -236
- 修复：去掉 `-273`，直接使用 smartctl 返回的摄氏度

### v4 架构（最终）
```
DiskProbe.app (普通用户, SwiftUI)
  ├─ AuthorizationCreate → AuthorizationCopyRights → 弹系统标准密码框
  ├─ DiskProbeExecuteWithPrivileges（C 包装 AuthorizationExecuteWithPrivileges）
  │    以 root 启动 DiskProbeRead
  ├─ helper 逐块 pread → 直接写结果文件（参数传入，不经 shell）
  ├─ ScanEngine 轮询结果文件新增行 → ScanProgress
  └─ 暂停/继续/停止 → 写控制文件，helper 每块检查
```

关键点：
- **C 包装层 AuthExec**：Swift 中 `AuthorizationExecuteWithPrivileges` 被标记
  unavailable（deprecated 早于 10.9），用 C 函数包装后 Swift 可调用
- **arguments 不含程序名**：AuthorizationExecuteWithPrivileges 的 arguments
  从 argv[1] 开始（实测确认，曾导致 helper 收到 usage 错误）
- helper 以 root 直连 /dev/rdisk4，实测读取成功：
  `{"i":0,"ok":true,"ms":346.072,"errno":null,"bytes":4096}`

### 修改的文件
- `Sources/AuthExec/` — 新增 C 包装层（AuthExec.c + AuthExec.h + modulemap）
- `Sources/DiskProbeRead/main.swift` — 结果文件作为参数直接写入（不再依赖 shell 重定向）
- `Sources/DiskProbe/Scan/RealScanSession.swift` — 改用 AuthorizationServices + C 包装
- `Sources/DiskProbe/SMART/SMARTReader.swift` — 修复 NVMe 温度单位
- `Package.swift` — 新增 AuthExec target

### 已验证（CLT + 真实授权）
- ✅ AuthorizationServices 全链路：Create → CopyRights(弹框) → ExecuteWithPrivileges
- ✅ **helper 以 root 真实读取 /dev/rdisk4 成功**（bytes=4096, errno=null）
- ✅ helper 完整扫描模式（结果文件写入）
- ✅ 控制文件 pause/resume/stop 生效
- ✅ 授权凭证缓存：第二次调用无需重新弹框
- ✅ 主工程编译 + .app 打包 + 启动正常

### 已知限制
- helper 是 root 进程，普通用户无法强杀，只能靠控制文件优雅退出（坏道 EIO 会快速返回）
- 首次扫描弹一次密码框，5 分钟内授权缓存，之后扫描不再弹框

---

## 第七步：暂停 bug 修复 + 缓存清理 ✅ 已完成

### 用户反馈
1. 还是没办法暂停
2. 工具占 500MB，删缓存

### 暂停 bug（第一性原理定位）
- **根因**：`runRealScan` 的轮询循环**没有检查 `pauseRequested`**！
  `pause()` 只设置标志 + 写控制文件，helper 停了，但 app 端仍在轮询
  消费文件缓冲里的结果、继续推进进度 → 暂停看起来"无效"
- 另外：`pause()/resume()/stop()` 里写控制文件用了 `Task {}`（fire-and-forget），
  与状态切换竞态
- **修复**：
  - `runRealScan` 轮询循环加 `while pauseRequested { sleep }` 显式暂停
  - 控制文件写入改为 `setControlSync`（nonisolated 同步写，去 Task 竞态）
- **验证**（集成测试）：helper 侧 pause 时进度完全停止（0→0），
  resume 后恢复（0→401）——控制机制本身正常，确认 bug 在 app 端轮询循环

### 缓存清理
- 删除 `.build` 构建缓存（543MB）→ 项目 545MB → **1.8MB**（-99.7%）
- 删除误产物 `main`（34KB）+ `.DS_Store`
- 新增 `.gitignore`（忽略 .build/ 和 dist/）
- 说明：`dist/DiskProbe.app`（1.6MB）保留可直接用；
  需要重新构建时 `./make_app.sh` 会自动重建 .build

### 修改的文件
- `Sources/DiskProbe/Scan/ScanEngine.swift` — runRealScan 加暂停检查；控制写同步
- `Sources/DiskProbe/Scan/RealScanSession.swift` — 新增 nonisolated setControlSync
- `.gitignore` — 新增
- 删除：.build 缓存、误产物 main、.DS_Store

---

## 第八步：暂停"读取停了但软件还在显示" ✅ 已修复

### 用户反馈
点击暂停后，活动监视器显示读取停了，但软件依然在显示读取。

### 根因（两层）
1. **用户跑的是旧版 .app**：上一轮修复后打包的 dist 是旧代码（当时打包后又改了
   代码，没重新打包就删了 .build）。确认方式：dist 二进制里没有 `setControlSync`
   符号 → 用户测试的是修复前版本
2. **修复前行为**：`runRealScan` 轮询循环完全没有 `pauseRequested` 检查，
   helper 停了对 app 端毫无感知，持续消费文件缓冲里已写入的结果、继续推进进度，
   直到缓冲耗尽才停（可能几秒）——正是"读取停了但软件还在显示读取"

### 修复
- 重新编译 + 打包（dist 现在含修复，nm 验证 `pauseRequested` 检查逻辑存在）
- 追加加固：`for block in results` 循环里也检查 `pauseRequested`，
  暂停瞬间已读入的缓冲也不再消费（最多让"正在读的最后一块"完成，1 块误差）
- 用状态机模拟测试验证：暂停时进度停止（+1 为正在飞的那块，正常竞态）、
  继续后恢复、停止后终止

### 验证
- dist 二进制时间戳 (15:10) > 源码时间戳 (15:10)，含修复
- 状态机模拟：暂停→进度停、继续→恢复、停止→终止 全部符合预期
- app 启动正常

### 给用户的验证方式
```
cd ~/.zcode/workspace/default/DiskProbe
./make_app.sh && open dist/DiskProbe.app
```
必须用**新打包的** dist/DiskProbe.app（旧版没有修复）。

---

## 开发日志

### 2026-08-02
- 调研完成：SMAppService.daemon 取代 SMJobBless；DiskArbitration CLT overlay 不完整
- 第二步完成：13 个源文件，编译 0.74s，运行验证通过（5s 无崩溃）
- 踩坑记录：
  - DiskArbitration CLT SDK 缺少 Swift overlay（`DADiskGetDescription` 不存在）→ 改用 `diskutil info -plist`
  - `protocol` 是 Swift 关键字，struct 属性不能用这个名字
  - `Process.run()` 在 Swift 6 需要 `try`
  - IOKit `kIOMediaClass` 等宏在 Swift 里需要手动声明字符串
