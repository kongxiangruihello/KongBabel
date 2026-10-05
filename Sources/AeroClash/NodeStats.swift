import Foundation

/// 单个节点近 7 天的稳定性记录：延迟样本、失败次数、被自动切走的次数。
struct NodeStats: Codable, Equatable {
    struct Sample: Codable, Equatable {
        let date: Date
        let delay: Int
    }

    static let window: TimeInterval = 7 * 86_400
    static let maxSamples = 300

    var samples: [Sample] = []
    var failures: [Date] = []
    var switchedAway: [Date] = []

    var isEmpty: Bool { samples.isEmpty && failures.isEmpty && switchedAway.isEmpty }

    var averageDelay: Int? {
        guard !samples.isEmpty else { return nil }
        return samples.map(\.delay).reduce(0, +) / samples.count
    }

    /// 测速成功率（0…1）；没有任何测速记录时为 nil
    var successRate: Double? {
        let total = samples.count + failures.count
        guard total > 0 else { return nil }
        return Double(samples.count) / Double(total)
    }

    /// 只保留最近 7 天、最多 300 个样本
    mutating func prune(now: Date = Date()) {
        let since = now.addingTimeInterval(-Self.window)
        samples.removeAll { $0.date < since }
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        failures.removeAll { $0 < since }
        switchedAway.removeAll { $0 < since }
    }

    /// 节点卡片上的简短说明
    var compactSummary: String {
        var parts: [String] = []
        if let averageDelay { parts.append("均 \(averageDelay) ms") }
        if let successRate { parts.append("成功 \(Int((successRate * 100).rounded()))%") }
        if !switchedAway.isEmpty { parts.append("切走 \(switchedAway.count) 次") }
        return parts.isEmpty ? "近 7 天暂无记录" : "7 天：" + parts.joined(separator: " · ")
    }

    /// 鼠标悬停时显示的完整说明
    var fullSummary: String {
        guard !isEmpty else { return "近 7 天暂无测速记录" }
        var lines = ["近 7 天稳定性"]
        lines.append("测速成功 \(samples.count) 次，失败 \(failures.count) 次")
        if let averageDelay, let minDelay = samples.map(\.delay).min(), let maxDelay = samples.map(\.delay).max() {
            lines.append("平均延迟 \(averageDelay) ms（最快 \(minDelay) ms，最慢 \(maxDelay) ms）")
        }
        lines.append("因故障或高延迟被自动切走 \(switchedAway.count) 次")
        return lines.joined(separator: "\n")
    }
}

/// 节点稳定性记录的持久化：保存在应用支持目录的 node-stats.json。
struct NodeStatsStore {
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("node-stats.json")
    }

    func load() -> [String: NodeStats] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var stats = (try? decoder.decode([String: NodeStats].self, from: data)) ?? [:]
        for key in Array(stats.keys) {
            stats[key]?.prune()
            if stats[key]?.isEmpty == true { stats.removeValue(forKey: key) }
        }
        return stats
    }

    func save(_ stats: [String: NodeStats]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stats) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
