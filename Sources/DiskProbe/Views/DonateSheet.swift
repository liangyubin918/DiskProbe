import SwiftUI
import AppKit

// MARK: - 赞赏弹窗

/// 展示收款码。码图放在 app bundle 的 Resources 里（make_app.sh 自动打包）：
///   Resources/Donate-WeChat.png / Donate-Alipay.png
/// 有几张展示几张（自适应居中）；都没有时显示占位提示。
struct DonateSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let candidates: [(title: String, resource: String, tint: Color)] = [
        ("微信", "Donate-WeChat", .green),
        ("支付宝", "Donate-Alipay", .blue),
    ]

    private var cards: [(title: String, image: NSImage, tint: Color)] {
        candidates.compactMap { c in
            Bundle.main.image(forResource: c.resource).map { (c.title, $0, c.tint) }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("如果 DiskProbe 帮到了你")
                    .font(.title3).bold()
                Text("扫码请作者喝杯咖啡")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if cards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 40))
                    Text("收款码待放置")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
                .frame(width: 420, height: 220)
            } else {
                HStack(spacing: 28) {
                    ForEach(cards, id: \.title) { card in
                        VStack(spacing: 8) {
                            Image(nsImage: card.image)
                                .resizable().scaledToFit()
                                .frame(width: 200, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                            Text(card.title).font(.callout).bold().foregroundStyle(card.tint)
                        }
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            Text("金额随意，心意最重要")
                .font(.caption).foregroundStyle(.tertiary)

            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 520)
    }
}
