// swift-tools-version: 5.9
// DiskProbe - macOS 硬盘坏道检测工具
//
// 构建方式：
//   swift build                   # 编译 app + 特权 helper
//   swift run DiskProbe           # 运行 GUI app（仅演示扫描；真实扫描需从 .app 启动）
//   ./make_app.sh                 # 打包 dist/DiskProbe.app（含真实扫描）
//
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

        // 主 App（SwiftUI，普通用户权限）。真实扫描通过 XPC 调用 DiskProbeHelper。
        .executableTarget(
            name: "DiskProbe",
            dependencies: ["DiskProbeCore"],
            path: "Sources/DiskProbe"
        ),

        // 特权 helper（SMAppService daemon，root 权限运行，只做只读扫描）
        .executableTarget(
            name: "DiskProbeHelper",
            dependencies: ["DiskProbeCore"],
            path: "Sources/DiskProbeHelper"
        ),

        .testTarget(
            name: "DiskProbeTests",
            dependencies: ["DiskProbe", "DiskProbeCore", "DiskProbeHelper"],
            path: "Tests/DiskProbeTests"
        ),
    ]
)
