import SwiftUI
import AppKit
import DiskProbeCore

// MARK: - 赞赏弹窗

/// 展示收款码。码图放在 app bundle 的 Resources 里（make_app.sh 自动打包）：
///   Resources/Donate-WeChat.png / Donate-Alipay.png
/// 有几张展示几张（自适应居中）；都没有时显示占位提示。
struct DonateSheet: View {
    // presentationMode 是 dismiss（macOS 12+）的 macOS 11 等价物
    @Environment(\.presentationMode) private var presentationMode

    private let candidates: [(title: String, resource: String, tint: Color)] = [
        (tr("微信", "WeChat"), "Donate-WeChat", .green),
        (tr("支付宝", "Alipay"), "Donate-Alipay", .blue),
    ]

    private var cards: [(title: String, image: NSImage, tint: Color)] {
        candidates.compactMap { c in
            Bundle.main.image(forResource: c.resource).map { (c.title, $0, c.tint) }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(tr("如果 DiskProbe 帮到了你", "If DiskProbe helped you"))
                    .font(.title3.weight(.bold))
                Text(tr("扫码请作者喝杯咖啡", "Scan to buy the author a coffee"))
                    .font(.callout).foregroundColor(.appSecondary)
            }

            if cards.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 40))
                    Text(tr("收款码待放置", "QR codes not bundled"))
                        .font(.caption)
                }
                .foregroundColor(.appTertiary)
                .frame(width: 420, height: 220)
            } else {
                HStack(spacing: 28) {
                    ForEach(cards, id: \.title) { card in
                        VStack(spacing: 8) {
                            Image(nsImage: card.image)
                                .resizable().scaledToFit()
                                .frame(width: 200, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.appSeparator))
                            Text(card.title).font(.callout.weight(.bold)).foregroundColor(card.tint)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
                    }
                }
            }

            Text(tr("金额随意，心意最重要", "Any amount matters — the thought counts"))
                .font(.caption).foregroundColor(.appTertiary)

            Button(tr("关闭", "Close")) { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 520)
    }
}
