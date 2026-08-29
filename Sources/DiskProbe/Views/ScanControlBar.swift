import SwiftUI
import AppKit
import DiskProbeCore

// MARK: - 扫描控制条：开始/暂停/继续/停止 + 块大小

struct ScanControlBar: View {
    let state: ScanState
    @Binding var blockSizeKB: Int
    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 12) {
            // 按钮组
            switch state {
            case .idle, .finished, .stopped, .error:
                Button(action: onStart) {
                    Label("开始扫描", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .scanning:
                Button(action: onPause) {
                    Label("暂停", systemImage: "pause.fill")
                }
                .controlSize(.large)
                Button(action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .tint(.red)
                .controlSize(.large)

            case .paused:
                Button(action: onResume) {
                    Label("继续", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .tint(.red)
                .controlSize(.large)
            }

            Divider().frame(height: 22)

            // 块大小
            LabeledContent {
                Picker("块大小", selection: $blockSizeKB) {
                    Text("64 KB").tag(64)
                    Text("128 KB").tag(128)
                    Text("256 KB").tag(256)
                    Text("512 KB").tag(512)
                    Text("1 MB").tag(1024)
                }
                .frame(width: 100)
                .labelsHidden()
                .disabled(state == .scanning || state == .paused)
            } label: {
                Label("块大小", systemImage: "square.grid.2x2")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }

            Spacer()

            // 状态标签 + 特权助手提示 + 扫描错误提示
            HStack(spacing: 8) {
                helperStatusView
                if let err = appState.authError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                stateLabel
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onAppear { appState.refreshHelperStatus() }
        // 用户从系统设置批准特权助手回到 app 后，自动刷新安装状态
        .onChange(of: scenePhase) {
            if scenePhase == .active { appState.refreshHelperStatus() }
        }
    }

    @ViewBuilder private var helperStatusView: some View {
        switch appState.helperStatus {
        case .enabled:
            Label("特权助手已就绪", systemImage: "checkmark.shield.fill")
                .font(.caption).foregroundStyle(.green)
            // 已注册 ≠ 能跑：重新打包后旧注册会让 launchd 反复 spawn 失败，
            // 常驻一个"重装"入口以便一键修复
            Button("重装") { appState.reinstallHelper() }
                .font(.caption).controlSize(.small)
                .help("扫描报「特权助手未确认启动」时点这里重新注册")
        case .requiresApproval:
            Button("去系统设置批准特权助手") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption).controlSize(.small)
        default:
            Button("安装特权助手") { appState.installHelper() }
                .font(.caption).controlSize(.small)
        }
    }

    @ViewBuilder private var stateLabel: some View {
        switch state {
        case .idle:      EmptyView()
        case .scanning:  badge("扫描中", color: .green)
        case .paused:    badge("已暂停", color: .orange)
        case .stopped:   badge("已停止", color: .gray)
        case .finished:  badge("已完成", color: .blue)
        case .error:     badge("出错", color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).bold().foregroundStyle(color)
    }
}
