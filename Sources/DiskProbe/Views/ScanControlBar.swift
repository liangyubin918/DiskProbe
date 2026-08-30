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

    var body: some View {
        HStack(spacing: 12) {
            // 按钮组
            switch state {
            case .idle, .finished, .stopped, .error:
                Button(action: onStart) {
                    Label("开始扫描", systemImage: "play.fill")
                }
                .controlSize(.large)

            case .scanning:
                Button(action: onPause) {
                    Label("暂停", systemImage: "pause.fill")
                }
                .controlSize(.large)
                Button(action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .foregroundColor(.red)
                .controlSize(.large)

            case .paused:
                Button(action: onResume) {
                    Label("继续", systemImage: "play.fill")
                }
                .controlSize(.large)
                Button(action: onStop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .foregroundColor(.red)
                .controlSize(.large)
            }

            Divider().frame(height: 22)

            // 块大小（LabeledContent 是 macOS 13+，用 HStack 等价实现）
            HStack(spacing: 8) {
                Label("块大小", systemImage: "square.grid.2x2")
                    .font(.caption)
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
            }

            Spacer()

            // 状态标签 + 特权助手状态 + 扫描错误提示
            HStack(spacing: 8) {
                helperStatusView
                if let ok = appState.saveSuccessMessage {
                    Text(ok).font(.caption).foregroundColor(.green)
                }
                if let err = appState.authError {
                    if err.hasPrefix("[TCC]") {
                        Button("去授权完全磁盘访问") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.caption).controlSize(.small)
                        Text(err.dropFirst(5)).font(.caption).foregroundColor(.red)
                    } else {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                }
                stateLabel
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onAppear { appState.refreshHelperStatus() }
        // 用户从系统设置批准特权助手回到 app 后，自动刷新安装状态
        // （.onChange(of: scenePhase) 是 macOS 12+/14+ API，用通知等价实现）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshHelperStatus()
        }
    }

    @ViewBuilder private var helperStatusView: some View {
        if appState.helperOpInProgress {
            ProgressView().controlSize(.small)
            Text("正在更新特权助手…").font(.caption).foregroundColor(.appSecondary)
        } else {
            switch appState.helperStatus {
            case .registered:
                helperHealthView
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
            // 操作结果独立展示，不与健康状态混在一起；新操作开始或成功时自动清除
            if let err = appState.helperOpError {
                Text(err).font(.caption).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder private var helperHealthView: some View {
        switch appState.helperHealth {
        case .ready:
            // 就绪态保持干净，不放操作按钮；需要重装的异常态由下面的分支接管
            Label("特权助手已就绪", systemImage: "checkmark.shield.fill")
                .font(.caption).foregroundColor(.green)
        case .stale(let reported):
            Label("助手版本过期（注册的是 \(reported)）", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption).foregroundColor(.orange)
            Button("重装特权助手") { appState.reinstallHelper() }
                .font(.caption).controlSize(.small)
        case .unreachable:
            Label("已注册但助手无法启动", systemImage: "exclamationmark.shield.fill")
                .font(.caption).foregroundColor(.orange)
            Button("重装特权助手") { appState.reinstallHelper() }
                .font(.caption).controlSize(.small)
        case .checking:
            Label("特权助手检查中…", systemImage: "shield.lefthalf.filled")
                .font(.caption).foregroundColor(.appSecondary)
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
        Text(text).font(.caption.weight(.bold)).foregroundColor(color)
    }
}
