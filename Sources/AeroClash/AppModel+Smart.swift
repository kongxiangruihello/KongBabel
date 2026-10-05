import SwiftUI
import AppKit

// 流量倍率、订阅流量估算、后台定时测速、“我的规则”与按 Wi‑Fi 自动开关代理

/// 自动切换时的候选节点
typealias SwitchCandidate = (name: String, delay: Int, multiplier: Double, favorite: Bool)

/// “我的规则”中的一条自定义规则（对应自定义规则文本中的一行）
struct CustomRuleItem: Identifiable, Equatable {
    let id: Int          // 在自定义规则文本中的行号
    let type: String
    let payload: String
    let policy: String   // DIRECT、代理组名等
    let options: String  // 出站后面的附加参数，例如 no-resolve
    let enabled: Bool

    /// 简单规则可以直接切换走代理/直连；AND/OR 等逻辑规则只能启用、停用或删除
    var isSimple: Bool {
        ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "GEOSITE", "GEOIP", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "PROCESS-PATH", "SRC-IP-CIDR", "DST-PORT"].contains(type.uppercased())
    }

    var isDirect: Bool { policy.uppercased() == "DIRECT" }

    var symbol: String {
        switch type.uppercased() {
        case "PROCESS-NAME", "PROCESS-PATH": return "app.badge"
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "GEOIP": return "number"
        default: return "globe"
        }
    }
}

extension AppModel {
    // MARK: Traffic multiplier

    func multiplier(for node: String) -> Double? {
        TrafficMultiplier.parse(node)
    }

    func multiplierLabel(for node: String) -> String? {
        multiplier(for: node).map(TrafficMultiplier.label)
    }

    func setPreferLowMultiplier(_ enabled: Bool) {
        preferLowMultiplier = enabled
        UserDefaults.standard.set(enabled, forKey: "preferLowMultiplier")
        showToast(enabled ? "自动切换时优先选择低倍率节点" : "自动切换时只看延迟")
    }

    func setMaxAutoSwitchMultiplier(_ value: Double) {
        maxAutoSwitchMultiplier = value
        UserDefaults.standard.set(value, forKey: "maxAutoSwitchMultiplier")
        showToast(value > 0 ? "自动切换只选倍率不超过 \(TrafficMultiplier.format(value)) 的节点" : "自动切换不限制倍率")
    }

    func setNodeSortOrder(_ order: String) {
        nodeSortOrder = order
        UserDefaults.standard.set(order, forKey: "nodeSortOrder")
    }

    /// 代理页节点排序：default 保持订阅顺序，multiplier 按倍率，latency 按延迟（未测速的排最后）
    func sortedNodes(_ nodes: [ProxyNode]) -> [ProxyNode] {
        switch nodeSortOrder {
        case "multiplier":
            return nodes.enumerated().sorted { lhs, rhs in
                let a = multiplier(for: lhs.element.name) ?? 1, b = multiplier(for: rhs.element.name) ?? 1
                return a != b ? a < b : lhs.offset < rhs.offset
            }.map(\.element)
        case "latency":
            return nodes.enumerated().sorted { lhs, rhs in
                let a = lhs.element.latency > 0 ? lhs.element.latency : Int.max
                let b = rhs.element.latency > 0 ? rhs.element.latency : Int.max
                return a != b ? a < b : lhs.offset < rhs.offset
            }.map(\.element)
        default:
            return nodes
        }
    }

    /// 从候选节点中选一个：开启“低倍率优先”时，在延迟不超过最快节点 1.5 倍 + 80 ms 的范围内选倍率最低的
    func pickSwitchCandidate(_ candidates: [SwitchCandidate]) -> (name: String, delay: Int)? {
        guard let fastest = candidates.min(by: { $0.delay < $1.delay }) else { return nil }
        guard preferLowMultiplier else { return (fastest.name, fastest.delay) }
        let limit = Double(fastest.delay) * 1.5 + 80
        let pool = candidates.filter { Double($0.delay) <= limit }
        let best = pool.min { lhs, rhs in
            lhs.multiplier != rhs.multiplier ? lhs.multiplier < rhs.multiplier : lhs.delay < rhs.delay
        } ?? fastest
        return (best.name, best.delay)
    }

    // MARK: Charged subscription traffic

    /// 按每条连接的出站节点倍率，折算本次刷新新增的订阅流量；直连不计
    func accountChargedTraffic(_ rawConnections: [[String: Any]]) {
        var seen: [String: Int64] = [:]
        for raw in rawConnections {
            guard let id = raw["id"] as? String else { continue }
            let total = ((raw["upload"] as? NSNumber)?.int64Value ?? 0) + ((raw["download"] as? NSNumber)?.int64Value ?? 0)
            seen[id] = total
            let delta = max(0, total - (connectionByteCache[id] ?? 0))
            guard delta > 0 else { continue }
            let node = (raw["chains"] as? [String])?.first ?? "DIRECT"
            guard !["DIRECT", "REJECT", "REJECT-DROP", "PASS"].contains(node.uppercased()) else { continue }
            pendingChargedActual += delta
            pendingChargedBytes += Int64((Double(delta) * (multiplier(for: node) ?? 1)).rounded())
        }
        connectionByteCache = seen
    }

    func flushChargedTraffic() {
        guard pendingChargedActual > 0 || pendingChargedBytes > 0 else { return }
        chargedTraffic = chargedTrafficStore.record(actual: pendingChargedActual, charged: pendingChargedBytes, into: chargedTraffic)
        pendingChargedActual = 0
        pendingChargedBytes = 0
    }

    /// 订阅流量估算：今日扣除、今日实际经代理流量、本月扣除、按近 7 天平均剩余流量可用天数
    var chargedTrafficSummary: (todayCharged: Int64, todayActual: Int64, month: Int64, daysLeft: Int?) {
        let summary = ChargedTrafficStore.summary(of: chargedTraffic)
        let todayCharged = summary.today.chargedBytes + pendingChargedBytes
        let todayActual = summary.today.actualBytes + pendingChargedActual
        var daysLeft: Int?
        if let profile = profiles.first(where: { $0.id == activeProfileID }), let usage = usage(for: profile),
           usage.totalBytes > 0, summary.dailyAverage > 0 {
            let remaining = Double(max(0, usage.totalBytes - usage.usedBytes))
            daysLeft = Int(remaining / summary.dailyAverage)
        }
        return (todayCharged, todayActual, summary.month + pendingChargedBytes, daysLeft)
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    // MARK: Background latency test

    func setBackgroundTestInterval(_ minutes: Int) {
        backgroundTestInterval = minutes
        UserDefaults.standard.set(minutes, forKey: "backgroundTestInterval")
        showToast(minutes > 0 ? "每 \(minutes) 分钟在后台测速一次" : "已关闭后台定时测速")
    }

    func checkBackgroundTestIfNeeded() {
        guard backgroundTestInterval > 0, coreState == .running, !backgroundTesting, !latencyTesting, !autoSwitchInProgress,
              networkIssueBadge != .offline, let startedAt = coreStartedAt, Date().timeIntervalSince(startedAt) > 90,
              Date().timeIntervalSince(lastBackgroundTest) >= Double(backgroundTestInterval) * 60 else { return }
        runBackgroundTest()
    }

    /// 依次测速各节点组（已测过的节点不重复测），更新红绿点、节点稳定性和自动切换所用的数据
    func runBackgroundTest(manual: Bool = false) {
        guard !backgroundTesting, coreState == .running else { return }
        backgroundTesting = true
        lastBackgroundTest = Date()
        Task {
            defer { backgroundTesting = false }
            let special: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
            let testURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
            var tested = Set<String>()
            var available = 0
            var failed = 0
            let groups = proxyGroups.filter { $0.name != "GLOBAL" }
            for group in (groups.isEmpty ? proxyGroups : groups) {
                let members = group.members.filter { !tested.contains($0) && !special.contains($0.uppercased()) && !Self.isInfoNodeName($0) }
                guard !members.isEmpty else { continue }
                let encoded = group.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group.name
                guard let data = try? await api.request("/group/\(encoded)/delay?url=\(testURL)&timeout=5000"),
                      let delays = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                recordGroupDelays(delays, members: members)
                for member in members {
                    tested.insert(member)
                    if ((delays[member] as? NSNumber)?.intValue ?? 0) > 0 { available += 1 } else { failed += 1 }
                }
            }
            await refreshProxies()
            appendLog(level: "INFO", message: "后台测速完成：\(available) 个节点可用，\(failed) 个失效")
            if manual { showToast("测速完成：\(available) 个可用，\(failed) 个失效") }
        }
    }

    // MARK: My rules

    var customRuleItems: [CustomRuleItem] {
        runtimeSettings.customRules.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let enabled = !line.hasPrefix("#")
            if !enabled { line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            let parts = Self.ruleParts(line)
            guard parts.count >= 3 else { return nil }
            let target = parts[2].split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return CustomRuleItem(id: index, type: parts[0], payload: parts[1], policy: target.first ?? "",
                                  options: target.count > 1 ? target[1] : "", enabled: enabled)
        }
    }

    private func rewriteCustomRule(_ item: CustomRuleItem, with newLine: String?, message: String) {
        var lines = runtimeSettings.customRules.components(separatedBy: .newlines)
        guard item.id < lines.count else { return }
        if let newLine { lines[item.id] = newLine } else { lines.remove(at: item.id) }
        runtimeSettings.customRules = lines.joined(separator: "\n")
        applyCustomRules(message: message)
    }

    private func ruleLine(_ item: CustomRuleItem, policy: String, enabled: Bool) -> String {
        let body = "\(item.type),\(item.payload),\(policy)" + (item.options.isEmpty ? "" : ",\(item.options)")
        return enabled ? body : "# " + body
    }

    func setCustomRuleEnabled(_ item: CustomRuleItem, _ enabled: Bool) {
        rewriteCustomRule(item, with: ruleLine(item, policy: item.policy, enabled: enabled),
                          message: enabled ? "已启用：\(item.payload)" : "已停用：\(item.payload)")
    }

    func setCustomRuleDirect(_ item: CustomRuleItem, _ direct: Bool) {
        guard item.isSimple else { return }
        let policy = direct ? "DIRECT" : proxyPolicyGroupName()
        rewriteCustomRule(item, with: ruleLine(item, policy: policy, enabled: item.enabled),
                          message: "\(item.payload) → \(direct ? "直连" : "代理（\(policy)）")")
    }

    func deleteCustomRule(_ item: CustomRuleItem) {
        rewriteCustomRule(item, with: nil, message: "已删除：\(item.payload)")
    }

    // MARK: Wi‑Fi rules

    func configureWiFiMonitor() {
        wifiMonitor.onAuthorizationChange = { [weak self] in self?.refreshWiFiState() }
        refreshWiFiState()
    }

    func checkWiFiIfNeeded() {
        guard Date().timeIntervalSince(lastSSIDCheck) > 10 else { return }
        refreshWiFiState()
    }

    /// 读取当前 Wi‑Fi；只有在 Wi‑Fi 发生变化时才按规则开关代理，之后不干预手动操作
    func refreshWiFiState() {
        lastSSIDCheck = Date()
        let ssid = wifiMonitor.currentSSID
        if currentSSID != ssid { currentSSID = ssid }
        let needsPermission = ssid == nil && wifiMonitor.needsLocationPermission
        if wifiNeedsPermission != needsPermission { wifiNeedsPermission = needsPermission }
        guard wifiAutoEnabled, coreState == .running, !isChangingConnection, ssid != lastHandledSSID else { return }
        lastHandledSSID = ssid
        guard let ssid, let action = wifiRules[ssid] else { return }
        applyWiFiRule(ssid: ssid, action: action)
    }

    private func applyWiFiRule(ssid: String, action: String) {
        let enable = action == "enable"
        guard enable != isConnected else { return }
        Task {
            await setConnectionEnabled(enable)
            guard isConnected == enable else { return }
            let title = enable ? "已自动开启系统代理" : "已自动关闭系统代理"
            recordNetworkEvent(.wifiRule, title: title, detail: "已连接 Wi‑Fi「\(ssid)」")
            networkNotice = .info(title: title, detail: "已连接 Wi‑Fi「\(ssid)」，按你的设置\(enable ? "开启" : "关闭")了系统代理。", symbol: "wifi")
        }
    }

    func setWiFiAutoEnabled(_ enabled: Bool) {
        wifiAutoEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "wifiAutoEnabled")
        lastHandledSSID = currentSSID // 开启时不立即改动当前状态，下次切换 Wi‑Fi 时生效
        if enabled && wifiMonitor.currentSSID == nil && wifiMonitor.needsLocationPermission { wifiMonitor.requestPermission() }
        showToast(enabled ? "已开启按 Wi‑Fi 自动开关代理" : "已关闭按 Wi‑Fi 自动开关代理")
    }

    /// action 为 "enable"、"disable"；nil 表示删除这条 Wi‑Fi 规则
    func setWiFiRule(_ ssid: String, action: String?) {
        wifiRules[ssid] = action
        UserDefaults.standard.set(wifiRules, forKey: "wifiRules")
    }

    func requestWiFiPermission() {
        wifiMonitor.requestPermission()
    }
}
