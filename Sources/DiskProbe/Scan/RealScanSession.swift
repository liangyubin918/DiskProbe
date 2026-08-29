import Foundation

// 旧版 RealScanSession 通过 AuthorizationExecuteWithPrivileges 将 app bundle 中
// 可被当前用户替换的 helper 提升为 root，并通过 /tmp 路径交换控制/结果文件。
// 该设计会造成特权 helper 替换和符号链接 TOCTOU，已整体移除。
//
// 真实裸设备扫描将在后续版本以签名校验的 XPC privileged helper 重建；在此之前，
// ScanEngine 会拒绝真实读取请求，而不会尝试任何不安全的提权执行。
