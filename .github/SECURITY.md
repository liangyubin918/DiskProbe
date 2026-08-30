# 安全策略

## 报告安全问题

本项目包含一个以 root 权限运行的特权 helper（DiskProbeHelper）。
如果你发现任何安全问题（提权、绕过校验、任意设备访问等）：

- **请勿公开提交 Issue**
- 使用 GitHub 私有漏洞报告：仓库 **Security 标签页 → Report a vulnerability**，
  或访问 https://github.com/liangyubin918/DiskProbe/security/advisories/new

收到报告后会尽快回复，确认后修复并发布新版本，修复前对细节保密。

## 支持的版本

仅最新 [Release](https://github.com/liangyubin918/DiskProbe/releases) 版本获得安全修复。
注意：Apple Development 免费证书有效期 1 年，过期签名的 daemon 无法启动，请更新到最新 Release。
