import SwiftUI
import DiskProbeCore

// MARK: - App 入口

@main
struct DiskProbeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)

        // 设置窗口：阈值调整（最小实现，放 Settings 菜单里）
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button(tr("检查更新…", "Check for Updates…")) {
                    Task { try? await appState.checkForUpdates(manual: true) }
                }
            }
        }
    }
}
