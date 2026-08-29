// swift-tools-version: 5.9
// DiskProbe - macOS 硬盘坏道检测工具
//
// 构建方式：
//   swift build                   # 编译 app
//   swift run DiskProbe           # 运行 GUI app
//
// 当前不构建或打包特权 helper；真实裸设备读取将在安全的 XPC 方案完成后恢复。
// 在 Xcode 中：File > Open > Package.swift → Cmd+R
import PackageDescription

let package = Package(
    name: "DiskProbe",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // 共享模型与协议
        .target(
            name: "DiskProbeCore",
            path: "Sources/DiskProbeCore"
        ),

        // 主 App（SwiftUI，普通用户权限）。
        // 真实裸设备读取将在签名校验的 XPC privileged helper 完成后单独加入；
        // 不再构建或打包可由用户替换后再提升权限的 helper。
        .executableTarget(
            name: "DiskProbe",
            dependencies: ["DiskProbeCore"],
            path: "Sources/DiskProbe"
        ),
    ]
)
