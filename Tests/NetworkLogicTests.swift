import Foundation

enum LogicTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let message): return message }
    }
}

/// 网络事件、节点稳定性、版本比较、快捷键等纯逻辑的测试（不需要启动应用）。
@main
struct NetworkLogicTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw LogicTestFailure.failed(message) }
    }

    static func main() throws {
        let workDirectory: URL
        if CommandLine.arguments.count >= 3 {
            workDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        } else {
            workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("kongbabel-logic-tests")
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // 故障时长文字
        try expect(NetworkEvent.durationText(5) == "5 秒", "durationText 秒")
        try expect(NetworkEvent.durationText(125) == "2 分 5 秒", "durationText 分秒")
        try expect(NetworkEvent.durationText(3_720) == "1 小时 2 分", "durationText 小时")

        // 网络事件保存与读取
        let eventStore = NetworkEventStore(root: workDirectory)
        let events = [
            NetworkEvent(date: Date(timeIntervalSince1970: 1_800_000_000), kind: .autoSwitch, title: "切换节点：A", detail: "B → A", duration: nil),
            NetworkEvent(date: Date(timeIntervalSince1970: 1_800_000_100), kind: .recovered, title: "网络已恢复", detail: "持续 12 秒", duration: 12)
        ]
        eventStore.save(events)
        try expect(eventStore.load() == events, "网络事件保存后读取不一致")

        // 节点稳定性
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stats = NodeStats()
        stats.samples = [
            .init(date: now.addingTimeInterval(-8 * 86_400), delay: 999),
            .init(date: now.addingTimeInterval(-60), delay: 100),
            .init(date: now, delay: 300)
        ]
        stats.failures = [now]
        stats.switchedAway = [now.addingTimeInterval(-9 * 86_400), now]
        stats.prune(now: now)
        try expect(stats.samples.count == 2, "超过 7 天的延迟样本没有被清理")
        try expect(stats.switchedAway.count == 1, "超过 7 天的切换记录没有被清理")
        try expect(stats.averageDelay == 200, "平均延迟计算错误")
        try expect(abs((stats.successRate ?? 0) - 2.0 / 3.0) < 0.001, "成功率计算错误")
        try expect(stats.compactSummary == "7 天：均 200 ms · 成功 67% · 切走 1 次", "节点摘要文字错误：\(stats.compactSummary)")
        try expect(NodeStats().compactSummary == "近 7 天暂无记录", "空记录摘要错误")

        let statsStore = NodeStatsStore(root: workDirectory)
        var recent = NodeStats()
        recent.samples = [.init(date: Date(), delay: 88)]
        statsStore.save(["日本 01": recent])
        try expect(statsStore.load()["日本 01"]?.averageDelay == 88, "节点记录保存后读取不一致")

        // 版本比较
        try expect(UpdateChecker.normalized("v1.9.0") == "1.9.0", "去掉 v 前缀失败")
        try expect(UpdateChecker.isNewer("v1.9.0", than: "1.8.0"), "1.9.0 应比 1.8.0 新")
        try expect(!UpdateChecker.isNewer("1.8.0", than: "1.8.0"), "相同版本不应算新")
        try expect(UpdateChecker.isNewer("1.10.0", than: "1.9.9"), "1.10.0 应比 1.9.9 新")
        try expect(!UpdateChecker.isNewer("1.7.9", than: "1.8"), "1.7.9 不应比 1.8 新")
        try expect(UpdateChecker.isNewer("2", than: "1.99.99"), "2 应比 1.99.99 新")

        // 快捷键
        try expect(KongHotKey.toggleProxy.defaultBinding.display == "⌃⌥P", "默认快捷键显示错误")
        try expect(HotKeyBinding.displayString(flags: [.command, .shift], keyCode: 40, characters: "k") == "⇧⌘K", "快捷键显示文字错误")
        try expect(HotKeyBinding.displayString(flags: [.control, .option], keyCode: 49, characters: " ") == "⌃⌥Space", "空格键显示错误")
        let binding = HotKeyBinding(keyCode: 46, modifiers: HotKeyBinding.carbonModifiers(from: [.control, .option]), display: "⌃⌥M")
        try expect(binding.sameKeys(as: KongHotKey.cycleMode.defaultBinding), "修饰键转换错误")
        let encoded = try JSONEncoder().encode(["2": binding])
        try expect(try JSONDecoder().decode([String: HotKeyBinding].self, from: encoded)["2"] == binding, "快捷键保存后读取不一致")

        // WebDAV 备份：新备份带个人偏好，旧备份（没有 preferences）也能读取
        var bundle = AeroBackupBundle(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      profiles: [], runtimeSettings: .standard, files: [:])
        bundle.preferences = BackupPreferences(
            favoriteNodes: ["日本 01"], excludedNodes: ["美国 09"], hotKeyBindings: ["1": KongHotKey.toggleProxy.defaultBinding],
            networkAlertsEnabled: true, autoSwitchNodeEnabled: false, highLatencyThreshold: 800,
            subscriptionRemindersEnabled: true, globalHotKeysEnabled: true, autoUpdateCheckEnabled: false,
            showMenuBarRates: true, networkEvents: events, nodeStats: ["日本 01": recent]
        )
        let bundleData = try JSONEncoder().encode(bundle)
        let decodedBundle = try JSONDecoder().decode(AeroBackupBundle.self, from: bundleData)
        try expect(decodedBundle.preferences == bundle.preferences, "备份中的个人偏好保存后读取不一致")
        var legacy = try JSONSerialization.jsonObject(with: bundleData) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "preferences")
        let legacyBundle = try JSONDecoder().decode(AeroBackupBundle.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(legacyBundle.preferences == nil, "旧版备份应能正常读取且不含个人偏好")

        // 合并网络事件与节点记录
        let extra = NetworkEvent(date: Date(timeIntervalSince1970: 1_800_000_200), kind: .offline, title: "网络未连接", detail: "", duration: nil)
        let mergedEvents = BackupPreferences.mergeEvents(events, [events[0], extra])
        try expect(mergedEvents.count == 3 && mergedEvents.first == extra, "网络事件合并错误")
        var remoteStats = NodeStats()
        remoteStats.samples = [.init(date: now, delay: 500)]
        let mergedStats = BackupPreferences.mergeNodeStats(["A": stats], ["A": remoteStats, "B": remoteStats], now: now)
        try expect(mergedStats["A"]?.samples.count == 3, "节点记录合并错误")
        try expect(mergedStats["B"]?.averageDelay == 500, "新增节点记录合并错误")

        // 流量倍率识别
        try expect(TrafficMultiplier.parse("日本-PRO-FW-JP1-流量倍率:0.2") == 0.2, "倍率识别：流量倍率:0.2")
        try expect(TrafficMultiplier.parse("中国香港-PRO-IPLC-HK2-1-流量倍率:1") == 1, "倍率识别：流量倍率:1")
        try expect(TrafficMultiplier.parse("香港 01 [0.5x]") == 0.5, "倍率识别：0.5x")
        try expect(TrafficMultiplier.parse("美国 ×2") == 2, "倍率识别：×2")
        try expect(TrafficMultiplier.parse("新加坡 3倍") == 3, "倍率识别：3倍")
        try expect(TrafficMultiplier.parse("德国-PRO-FW-DE1") == nil, "没有倍率的节点不应识别出倍率")
        try expect(TrafficMultiplier.parse("Proxy") == nil, "Proxy 不应识别出倍率")
        try expect(TrafficMultiplier.label(0.2) == "×0.2" && TrafficMultiplier.label(1) == "×1", "倍率标签错误")

        // 订阅流量记录与汇总
        let chargedStore = ChargedTrafficStore(root: workDirectory)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var chargedDays = chargedStore.record(actual: 1_000, charged: 200, on: day, into: [])
        chargedDays = chargedStore.record(actual: 500, charged: 500, on: day, into: chargedDays)
        try expect(chargedDays.count == 1 && chargedDays[0].actualBytes == 1_500 && chargedDays[0].chargedBytes == 700, "订阅流量累计错误")
        try expect(chargedStore.load() == chargedDays, "订阅流量记录保存后读取不一致")
        let chargedSummary = ChargedTrafficStore.summary(of: chargedDays, now: day)
        try expect(chargedSummary.today.chargedBytes == 700 && chargedSummary.month == 700, "订阅流量汇总错误")

        print("NetworkLogicTests passed")
    }
}
