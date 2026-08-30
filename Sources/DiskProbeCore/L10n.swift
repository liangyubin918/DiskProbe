import Foundation

// MARK: - 轻量双语
//
// 不引入 .strings/.xcstrings 资源体系（SPM + make_app.sh 双构建路径下资源
// 处理是坑），直接双语文案内联：tr("中文", "English")，按系统首选语言二选一。
// 代价是两种语言都进二进制（本 app 文案量小，可忽略）；收益是任何构建
// 方式、任何系统版本行为一致，且不存在"漏翻译键"（两种语言写在一起）。

public func tr(_ zh: String, _ en: String) -> String {
    L10n.isChinese ? zh : en
}

public enum L10n {
    /// 系统首选语言是否中文。launchd daemon（特权 helper）环境读不到
    /// 用户 AppleLanguages 时自然回退英文，可接受（helper 文案只有少量技术错误）。
    public static let isChinese: Bool = {
        if let first = Locale.preferredLanguages.first, !first.isEmpty {
            return first.hasPrefix("zh")
        }
        return (Locale.current as NSLocale).object(forKey: NSLocale.Key.languageCode) as? String == "zh"
    }()
}
