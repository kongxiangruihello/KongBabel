import Foundation

/// WebDAV 备份中的个人偏好：常用/跳过的节点、自定义快捷键、各项提醒开关、网络事件与节点稳定性记录。
/// 所有字段都是可选的：旧版本的备份没有这一部分，恢复时会保留本机现有设置。
struct BackupPreferences: Codable, Equatable {
    var favoriteNodes: [String]?
    var excludedNodes: [String]?
    /// 键为 KongHotKey.rawValue 的字符串
    var hotKeyBindings: [String: HotKeyBinding]?
    var networkAlertsEnabled: Bool?
    var autoSwitchNodeEnabled: Bool?
    var highLatencyThreshold: Int?
    var subscriptionRemindersEnabled: Bool?
    var globalHotKeysEnabled: Bool?
    var autoUpdateCheckEnabled: Bool?
    var showMenuBarRates: Bool?
    var networkEvents: [NetworkEvent]?
    var nodeStats: [String: NodeStats]?

    /// 合并网络事件：按 id 去重、按时间倒序，最多保留 NetworkEventStore.limit 条
    static func mergeEvents(_ local: [NetworkEvent], _ remote: [NetworkEvent]) -> [NetworkEvent] {
        var seen = Set<UUID>()
        var merged: [NetworkEvent] = []
        for event in (local + remote).sorted(by: { $0.date > $1.date }) where !seen.contains(event.id) {
            seen.insert(event.id)
            merged.append(event)
        }
        return Array(merged.prefix(NetworkEventStore.limit))
    }

    /// 合并节点稳定性记录：同一节点的样本、失败与切换记录去重后合并，再清理超过 7 天的部分
    static func mergeNodeStats(_ local: [String: NodeStats], _ remote: [String: NodeStats], now: Date = Date()) -> [String: NodeStats] {
        var merged = local
        for (name, incoming) in remote {
            var stats = merged[name] ?? NodeStats()
            var sampleKeys = Set(stats.samples.map { "\($0.date.timeIntervalSince1970)-\($0.delay)" })
            for sample in incoming.samples where !sampleKeys.contains("\(sample.date.timeIntervalSince1970)-\(sample.delay)") {
                sampleKeys.insert("\(sample.date.timeIntervalSince1970)-\(sample.delay)")
                stats.samples.append(sample)
            }
            stats.samples.sort { $0.date < $1.date }
            stats.failures = Array(Set(stats.failures + incoming.failures)).sorted()
            stats.switchedAway = Array(Set(stats.switchedAway + incoming.switchedAway)).sorted()
            stats.prune(now: now)
            if stats.isEmpty { merged.removeValue(forKey: name) } else { merged[name] = stats }
        }
        return merged
    }
}
