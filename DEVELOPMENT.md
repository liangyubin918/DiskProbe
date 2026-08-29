# 开发指南

## 构建 / 测试 / 打包

```bash
swift build                   # 编译（真实扫描必须从 .app 启动，swift run 仅演示用途）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 27 个单元测试
./make_app.sh                 # 打包 dist/DiskProbe.app（helper 先签、app 外层封存）
```

签名要求：钥匙串里有 Apple Development 证书即可（免费 Apple ID + Xcode 自动生成，无需付费账户）。

## 架构一页纸

```
DiskProbe.app（用户权限）
  ├─ DiskEnumerator      IOKit Whole + diskutil info 过滤物理整盘
  ├─ SMARTReader         smartctl -j -a 解析（勿依赖退出码为 0，它是位掩码）
  ├─ ScanEngine (actor)  消费批次流 → 分类/统计/地图快照/速度/ETA
  │                      地图与累计统计由引擎维护，进度事件是全量快照
  │                      （AsyncStream 用 bufferingNewest(1)，丢事件不丢正确性）
  └─ RealScanSession     XPC 客户端（begin 的 pendingAck 只能 resume 一次）

DiskProbeHelper（root daemon，SMAppService 安装）
  ├─ NSXPCListener(machServiceName:) —— 勿用 .service()，daemon 环境会 SIGTRAP
  ├─ audit token 校验调用方（KVC 取出后用 NSValue.getValue 拷字节，勿 as? C 结构体）
  ├─ 设备白名单 ^/dev/rdisk[0-9]+$、lstat 拒符号链接、O_RDONLY
  └─ 扫描队列逐块 pread；可疑块（≥50ms 或失败）复检最多 3 次取最优
```

## 安全红线

- 不要恢复 `AuthorizationExecuteWithPrivileges` 或任何"用户可替换文件提权"方案
- helper 的 audit token 校验、设备白名单、只读约束缺一不可
- 重新打包后需重新注册 daemon（app 内「重装特权助手」或 `--register-helper` 无头模式）

## 常见坑速查

| 症状 | 原因 |
|---|---|
| 扫描报「特权助手未确认启动」 | 注册信息过期（重打包后常见）→ 重装助手 |
| open /dev/rdiskN EPERM | TCC：需完全磁盘访问权限，root 不豁免 |
| 助手显示已注册但起不来 | 用 `launchctl print system/local.diskprobe.helper` 看 runs/exit code；crash report 在 /Library/Logs/DiagnosticReports |
