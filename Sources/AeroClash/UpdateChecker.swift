import Foundation

/// GitHub Releases 上的一个发布版本。
struct ReleaseInfo: Equatable {
    let version: String
    let pageURL: URL
    let downloadURL: URL?
    let notes: String
}

/// 检查 GitHub Releases 是否有新版本。
enum UpdateChecker {
    static let repository = "kongxiangruihello/KongBabel"

    /// 去掉 tag 前面的 “v”
    static func normalized(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }

    /// 按数字逐段比较版本号，例如 1.10.0 比 1.9.9 新
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            normalized(value).split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = parts(remote), rhs = parts(local)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 读取最新发布版本；仓库还没有发布版本时返回 nil
    static func fetchLatest() async throws -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KongBabel/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard 200..<300 ~= status else {
            throw AeroRuntimeError.commandFailed("GitHub 返回 HTTP \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw AeroRuntimeError.invalidResponse
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.lowercased().hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
        return ReleaseInfo(version: normalized(tag), pageURL: page, downloadURL: dmg, notes: json["body"] as? String ?? "")
    }
}
