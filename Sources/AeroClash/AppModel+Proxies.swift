import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

// 代理节点、模式、连接、测速与快捷规则

extension AppModel {
    func testLatency() {
        guard !latencyTesting, coreState == .running else { return }
        latencyTesting = true
        showToast("正在测试全部节点…")
        Task {
            do {
                let group = selectedProxyGroup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedProxyGroup
                let testURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
                let data = try await api.request("/group/\(group)/delay?url=\(testURL)&timeout=5000")
                if let delays = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tested = proxyGroups.first(where: { $0.name == selectedProxyGroup }) {
                    recordGroupDelays(delays, members: tested.members)
                }
                await refreshProxies()
                latencyTesting = false
                let available = nodes.filter { $0.latency > 0 }.count
                showToast("测速完成 · \(available) 个节点可用")
            } catch {
                latencyTesting = false
                showToast("测速失败：\(error.localizedDescription)")
            }
        }
    }

    func selectNode(named nodeName: String, in groupName: String) {
        let previousGroup = selectedProxyGroup
        let previousNode = selectedNodeID
        selectedProxyGroup = groupName
        selectedNodeID = nodeName
        Task {
            do {
                let group = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName
                _ = try await api.request("/proxies/\(group)", method: "PUT", json: ["name": nodeName])
                showToast("\(groupName) 已切换至 \(nodeName)")
                networkWatchdog.recheckSoon()
                await refreshProxies()
            } catch {
                selectedProxyGroup = previousGroup
                selectedNodeID = previousNode
                showToast("节点切换失败：\(error.localizedDescription)")
            }
        }
    }

    func setMode(_ newMode: ProxyMode) {
        guard mode != newMode else { return }
        mode = newMode
        Task {
            do {
                _ = try await api.request("/configs", method: "PATCH", json: ["mode": newMode.apiValue])
                showToast("已切换至\(newMode.rawValue)模式")
            } catch {
                showToast("模式切换失败：\(error.localizedDescription)")
            }
        }
    }

    func selectNode(_ node: ProxyNode) {
        guard node.id != selectedNodeID else { return }
        let previous = selectedNodeID
        selectedNodeID = node.id
        Task {
            do {
                let group = selectedProxyGroup.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? selectedProxyGroup
                _ = try await api.request("/proxies/\(group)", method: "PUT", json: ["name": node.name])
                showToast("已切换至 \(node.name)")
                networkWatchdog.recheckSoon()
                await refreshProxies()
            } catch {
                selectedNodeID = previous
                showToast("节点切换失败：\(error.localizedDescription)")
            }
        }
    }

    func selectProxyGroup(_ name: String) {
        selectedProxyGroup = name
        applySelectedGroup()
    }

    func closeAllConnections() {
        Task {
            do {
                _ = try await api.request("/connections", method: "DELETE")
                connections.removeAll()
                showToast("已关闭全部活动连接")
            } catch { showToast("关闭失败：\(error.localizedDescription)") }
        }
    }

    func closeConnection(id: String) {
        Task {
            do {
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
                _ = try await api.request("/connections/\(encoded)", method: "DELETE")
                connections.removeAll { $0.id == id }
                showToast("连接已关闭")
            } catch { showToast("关闭连接失败：\(error.localizedDescription)") }
        }
    }

    func updateRuleProviders() {
        guard coreState == .running else {
            showToast("Mihomo 内核尚未运行")
            return
        }
        Task {
            do {
                let data = try await api.request("/providers/rules")
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let providers = root["providers"] as? [String: Any] else {
                    throw AeroRuntimeError.invalidResponse
                }
                var updated = 0
                var failed = 0
                for name in providers.keys.sorted() {
                    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                    do {
                        _ = try await api.request("/providers/rules/\(encoded)", method: "PUT")
                        updated += 1
                    } catch {
                        failed += 1
                        appendLog(level: "WARN", message: "规则集“\(name)”更新失败：\(error.localizedDescription)")
                    }
                }
                try await refreshRulesAndConfig()
                if providers.isEmpty {
                    showToast("当前配置没有远程规则集")
                } else if failed == 0 {
                    showToast("规则集更新完成 · \(updated) 个")
                } else {
                    showToast("已更新 \(updated) 个，失败 \(failed) 个")
                }
            } catch {
                showToast("规则集更新失败：\(error.localizedDescription)")
            }
        }
    }

    func runNetworkDiagnostics() {
        Task {
            do {
                guard coreState == .running else {
                    throw AeroRuntimeError.commandFailed("Mihomo 内核未运行")
                }
                _ = try await api.request("/version")
                let configData = try await api.request("/configs")
                guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
                    throw AeroRuntimeError.invalidResponse
                }
                let portMatches = runtimeSettings.useMixedPort
                    ? (config["mixed-port"] as? NSNumber)?.intValue == httpPort
                    : (config["port"] as? NSNumber)?.intValue == httpPort && (config["socks-port"] as? NSNumber)?.intValue == socksPort
                guard portMatches else {
                    throw AeroRuntimeError.commandFailed("运行端口与保存的设置不一致")
                }
                let detected = systemProxy.status(httpPort: httpPort, socksPort: socksPort, pacURL: repository.pacURL)
                detectedCaptureMode = detected
                if isConnected, runtimeSettings.captureMode != .tun, detected != runtimeSettings.captureMode {
                    throw AeroRuntimeError.commandFailed("系统实际接管状态与 KongBabel 显示状态不一致")
                }
                let capture = tunRequested ? "TUN" : (detected?.rawValue ?? "未接管系统流量")
                showToast("诊断通过 · 内核、端口与\(capture)状态正常")
            } catch {
                appendLog(level: "ERROR", message: "网络诊断失败：\(error.localizedDescription)")
                showToast("诊断发现问题：\(error.localizedDescription)")
            }
        }
    }

    func refreshProxies() async {
        do {
            let data = try await api.request("/proxies")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rawProxies = root["proxies"] as? [String: [String: Any]] else { throw AeroRuntimeError.invalidResponse }
            var delays: [String: Int] = [:]
            for (name, raw) in rawProxies {
                if let history = raw["history"] as? [[String: Any]], let last = history.last {
                    delays[name] = (last["delay"] as? NSNumber)?.intValue ?? 0
                }
            }
            proxyDelays = delays
            let groupTypes = Set(["Selector", "URLTest", "Fallback", "LoadBalance"])
            let groups = rawProxies.values.compactMap { raw -> ProxyGroup? in
                guard let name = raw["name"] as? String, let type = raw["type"] as? String, groupTypes.contains(type), raw["hidden"] as? Bool != true else { return nil }
                return ProxyGroup(name: name, type: type, now: raw["now"] as? String ?? raw["fixed"] as? String ?? "", members: raw["all"] as? [String] ?? [])
            }.sorted { lhs, rhs in
                if lhs.name == "GLOBAL" { return false }
                if rhs.name == "GLOBAL" { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            proxyGroups = groups
            if !groups.contains(where: { $0.name == selectedProxyGroup }) {
                selectedProxyGroup = groups.first?.name ?? "GLOBAL"
            }
            applySelectedGroup(from: rawProxies)
        } catch {
            appendLog(level: "WARN", message: "读取代理节点失败：\(error.localizedDescription)")
        }
    }

    func applySelectedGroup(from proxies: [String: [String: Any]]? = nil) {
        guard let group = proxyGroups.first(where: { $0.name == selectedProxyGroup }) else {
            nodes = []; return
        }
        selectedNodeID = group.now
        guard let proxies else { Task { await refreshProxies() }; return }
        nodes = group.members.compactMap { name in
            guard let raw = proxies[name] else { return nil }
            let history = raw["history"] as? [[String: Any]] ?? []
            let latency = (history.last?["delay"] as? NSNumber)?.intValue ?? 0
            let type = raw["type"] as? String ?? "Proxy"
            return ProxyNode(id: name, name: name, city: type, countryCode: flag(for: name), latency: latency, load: latency == 0 ? 0 : min(1, Double(latency) / 500), type: type, favorite: name == group.now)
        }
    }

    func flag(for name: String) -> String {
        let lower = name.lowercased()
        let pairs = [("香港", "🇭🇰"), ("hong kong", "🇭🇰"), ("日本", "🇯🇵"), ("东京", "🇯🇵"), ("japan", "🇯🇵"), ("新加坡", "🇸🇬"), ("狮城", "🇸🇬"), ("singapore", "🇸🇬"), ("美国", "🇺🇸"), ("united states", "🇺🇸"), ("洛杉矶", "🇺🇸"), ("台湾", "🇹🇼"), ("taiwan", "🇹🇼"), ("英国", "🇬🇧"), ("伦敦", "🇬🇧"), ("德国", "🇩🇪"), ("韩国", "🇰🇷")]
        return pairs.first(where: { lower.contains($0.0) })?.1 ?? (name == "DIRECT" ? "🖥" : "🌐")
    }

    /// 只测速某一个节点组（快捷面板中节点组右侧的按钮）
    func testGroupLatency(_ groupName: String) {
        guard coreState == .running, !testingGroups.contains(groupName) else { return }
        testingGroups.insert(groupName)
        Task {
            defer { testingGroups.remove(groupName) }
            let encoded = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupName
            let testURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
            do {
                let data = try await api.request("/group/\(encoded)/delay?url=\(testURL)&timeout=5000")
                if let delays = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let group = proxyGroups.first(where: { $0.name == groupName }) {
                    recordGroupDelays(delays, members: group.members)
                }
            } catch {
                appendLog(level: "WARN", message: "“\(groupName)”测速失败：\(error.localizedDescription)")
            }
            await refreshProxies()
        }
    }

    enum QuickRulePolicy {
        case proxy
        case direct
    }

    /// 把某个网站或应用设为始终走代理/直连：规则放在自定义规则最前面，优先级最高
    func addQuickRule(type: String, payload: String, policy: QuickRulePolicy) {
        let target = policy == .direct ? "DIRECT" : proxyPolicyGroupName()
        var lines = runtimeSettings.customRules
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        lines.removeAll { Self.ruleMatches($0, type: type, payload: payload) }
        lines.insert("\(type),\(payload),\(target)", at: 0)
        runtimeSettings.customRules = lines.joined(separator: "\n")
        applyCustomRules(message: "已设置：\(payload) → \(policy == .direct ? "直连" : "代理（\(target)）")")
    }

    func removeQuickRules(type: String, payload: String) {
        let lines = runtimeSettings.customRules.components(separatedBy: .newlines)
        let kept = lines.filter { !Self.ruleMatches($0, type: type, payload: payload) }
        guard kept.count != lines.count else { return }
        runtimeSettings.customRules = kept.joined(separator: "\n")
        applyCustomRules(message: "已删除 \(payload) 的规则")
    }

    /// 已有规则的出站（DIRECT 或代理组名）；没有规则时为 nil
    func quickRuleTarget(type: String, payload: String) -> String? {
        for line in runtimeSettings.customRules.components(separatedBy: .newlines) where Self.ruleMatches(line, type: type, payload: payload) {
            let parts = Self.ruleParts(line)
            return parts.count >= 3 ? parts[2] : nil
        }
        return nil
    }

    func applyCustomRules(message: String) {
        do {
            try settingsStore.save(runtimeSettings)
        } catch {
            presentError("保存规则失败", error)
            return
        }
        Task {
            await startCore()
            if coreState == .running { showToast(message) }
        }
    }

    func proxyPolicyGroupName() -> String {
        autoSwitchTargetGroup()?.name ?? "GLOBAL"
    }

    static func ruleParts(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return text.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func ruleMatches(_ line: String, type: String, payload: String) -> Bool {
        let parts = ruleParts(line)
        return parts.count >= 2 && parts[0].uppercased() == type.uppercased() && parts[1].lowercased() == payload.lowercased()
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// 网站的主域名，例如 www.youtube.com → youtube.com，news.sina.com.cn → sina.com.cn
    static func ruleDomain(for host: String) -> String? {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !lower.isEmpty, lower != "未知目标", !isIPAddress(lower), lower.contains(".") else { return nil }
        let labels = lower.split(separator: ".").map(String.init)
        let secondLevel: Set<String> = ["com", "net", "org", "gov", "edu", "co", "ac"]
        if labels.count >= 3, secondLevel.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// 订阅里用来显示到期日、剩余流量、官网等信息的“假节点”，不是真正可用的线路
    static func isInfoNodeName(_ name: String) -> Bool {
        let keywords = ["有效期", "到期", "过期", "剩余", "官网", "重置", "套餐", "expire", "traffic left", "remaining"]
        let lower = name.lowercased()
        return keywords.contains { lower.contains($0) }
    }
}
