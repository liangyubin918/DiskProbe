import Foundation

// MARK: - 检查更新（GitHub Releases）
//
// 启动后静默检查（24h 一次），菜单可手动检查。不嵌 SDK、不联网上报，
// 只 GET releases/latest 一个接口；拿不到就当没有更新，绝不打扰。

struct UpdateInfo: Equatable, Sendable {
    var version: String   // "2.9"（tag 去掉 v 前缀）
    var url: String       // release 页面
}

enum UpdateChecker {
    static let apiURL = "https://api.github.com/repos/liangyubin918/DiskProbe/releases/latest"
    static let releasesPage = "https://github.com/liangyubin918/DiskProbe/releases/latest"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 返回 nil 表示已是最新；网络失败抛错（静默检查方忽略，手动检查方提示）
    static func fetchLatest() async throws -> UpdateInfo? {
        guard let url = URL(string: apiURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw URLError(.badServerResponse)
        }
        let version = String(tag.drop { $0 == "v" || $0 == "V" })
        guard isNewer(version, than: currentVersion) else { return nil }
        return UpdateInfo(version: version,
                          url: json["html_url"] as? String ?? releasesPage)
    }

    /// 逐段数值比较（"2.10" > "2.9"）；候选版本没有更新的返回 false
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func numbers(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let c = numbers(candidate), cur = numbers(current)
        for i in 0..<max(c.count, cur.count) {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
