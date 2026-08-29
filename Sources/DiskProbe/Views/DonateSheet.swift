import SwiftUI
import AppKit

// MARK: - 赞赏弹窗

/// 展示微信 / 支付宝收款码。码图放在 app bundle 的 Resources 里：
///   Resources/Donate-WeChat.png / Donate-Alipay.png（make_app.sh 自动打包）
/// 图片未就位时显示占位提示，不影响其他功能。
struct DonateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("如果 DiskProbe 帮到了你")
                    .font(.title3).bold()
                Text("扫码请作者喝杯咖啡")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                qrCard(title: "微信", resource: "Donate-WeChat", tint: .green)
                qrCard(title: "支付宝", resource: "Donate-Alipay", tint: .blue)
            }

            Text("金额随意，心意最重要")
                .font(.caption).foregroundStyle(.tertiary)

            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 520)
    }

    @ViewBuilder
    private func qrCard(title: String, resource: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Group {
                if let image = Bundle.main.image(forResource: resource) {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .frame(width: 190, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .frame(width: 190, height: 190)
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 34))
                                Text("收款码待放置")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.tertiary)
                        )
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            Text(title).font(.callout).bold().foregroundStyle(tint)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
