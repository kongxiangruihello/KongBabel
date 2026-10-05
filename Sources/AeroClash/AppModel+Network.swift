import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

// 网络监测、自动切换节点、网络事件、全局快捷键与订阅提醒

extension AppModel {
    // MARK: Network watchdog

    func setNetworkAlertsEnabled(_ enabled: Bool) {
        networkAlertsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "networkAlertsEnabled")
        networkWatchdog.isEnabled = enabled
        if enabled {
            networkAlertsSnoozedUntil = .distantPast
            networkWatchdog.recheckSoon()
        } else {
            if networkNotice?.issue != nil { networkNotice = nil }
            networkIssueBadge = nil
        }
        showToast(enabled ? "已开启网络状态提醒" : "已关闭网络状态提醒")
    }

    func setAutoSwitchNodeEnabled(_ enabled: Bool) {
        autoSwitchNodeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSwitchNodeEnabled")
        showToast(enabled ? "节点失效或延迟过高时将自动切换" : "已关闭自动切换节点")
    }

    func setHighLatencyThreshold(_ milliseconds: Int) {
        highLatencyThreshold = milliseconds
        highLatencyStrikes = 0
        UserDefaults.standard.set(milliseconds, forKey: "highLatencyThreshold")
        showToast(milliseconds > 0 ? "延迟超过 \(milliseconds) ms 时自动切换" : "已关闭高延迟自动切换")
    }

    func setSubscriptionRemindersEnabled(_ enabled: Bool) {
        subscriptionRemindersEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "subscriptionRemindersEnabled")
        if enabled { lastSubscriptionReminderCheck = .distantPast }
        showToast(enabled ? "已开启订阅到期与流量提醒" : "已关闭订阅到期与流量提醒")
    }

    func configureNetworkWatchdog() {
        networkWatchdog.isEnabled = networkAlertsEnabled
        networkWatchdog.context = { [weak self] in
            guard let self else {
                return NetworkWatchdog.Context(coreState: .stopped, isCapturing: false, isDirectMode: true, proxyPort: 0)
            }
            return NetworkWatchdog.Context(
                coreState: self.coreState,
                isCapturing: self.isConnected,
                isDirectMode: self.mode == .direct,
                proxyPort: self.httpPort
            )
        }
        networkWatchdog.onIssue = { [weak self] issue in self?.handleNetworkIssue(issue) }
        networkWatchdog.onRecover = { [weak self] issue in self?.handleNetworkRecovery(issue) }
        networkWatchdog.start()
    }

    func handleNetworkIssue(_ issue: NetworkIssue) {
        appendLog(level: "WARN", message: issue.logMessage)
        recordDiagnostic("network-issue=\(issue)")
        networkIssueBadge = issue
        highLatencyStrikes = 0
        if networkIssueStartedAt == nil { networkIssueStartedAt = Date() }
        recordNetworkEvent(.init(issue: issue), title: issue.title, detail: networkNoticeDetail(for: issue).replacingOccurrences(of: "\n", with: " "))
        if issue == .proxyUnreachable, autoSwitchNodeEnabled, !autoSwitchInProgress,
           Date().timeIntervalSince(lastAutoSwitchAttempt) > 120 {
            Task { await autoSwitch(reason: .unreachable) }
            return
        }
        presentIssueNotice(issue)
    }

    func presentIssueNotice(_ issue: NetworkIssue, extraDetail: String? = nil) {
        guard Date() >= networkAlertsSnoozedUntil else { return }
        var detail = networkNoticeDetail(for: issue)
        if let extraDetail { detail += "\n\(extraDetail)" }
        networkNotice = .failure(issue, detail: detail)
    }

    enum AutoSwitchReason {
        case unreachable
        case highLatency(Int)
        case manual
    }

    /// 对当前策略组测速，切换到延迟最低的可用节点。
    func autoSwitch(reason: AutoSwitchReason) async {
        autoSwitchInProgress = true
        lastAutoSwitchAttempt = Date()
        defer { autoSwitchInProgress = false }
        let isUnreachable: Bool
        if case .unreachable = reason { isUnreachable = true } else { isUnreachable = false }
        let isManual: Bool
        if case .manual = reason { isManual = true } else { isManual = false }
        guard let group = autoSwitchTargetGroup() else {
            if isUnreachable {
                presentIssueNotice(.proxyUnreachable, extraDetail: "当前策略组不支持手动切换，未能自动更换节点。")
            } else if isManual {
                networkNotice = .info(title: "无法切换节点", detail: "当前没有可手动选择节点的策略组。", symbol: "exclamationmark.circle.fill")
            }
            return
        }
        let previous = group.now
        appendLog(level: "INFO", message: "自动切换：正在为“\(group.name)”测速")
        do {
            let encoded = group.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group.name
            let testURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
            let data = try await api.request("/group/\(encoded)/delay?url=\(testURL)&timeout=5000")
            let delays = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let excluded: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]
            var fastest: (name: String, delay: Int)?
            var fastestFavorite: (name: String, delay: Int)?
            for (name, value) in delays {
                guard name != previous, !excluded.contains(name.uppercased()), !excludedNodes.contains(name),
                      let delay = (value as? NSNumber)?.intValue, delay > 0 else { continue }
                if fastest == nil || delay < fastest!.delay { fastest = (name, delay) }
                if favoriteNodes.contains(name), fastestFavorite == nil || delay < fastestFavorite!.delay { fastestFavorite = (name, delay) }
            }
            let currentDelay = (delays[previous] as? NSNumber)?.intValue ?? 0
            // 常用节点优先；高延迟切换要求新节点明显更快，避免在差不多的节点之间来回跳
            let chosen: (name: String, delay: Int)?
            switch reason {
            case .unreachable:
                chosen = fastestFavorite ?? fastest
            case .manual:
                chosen = [fastestFavorite, fastest].compactMap { $0 }.first { currentDelay <= 0 || $0.delay < currentDelay }
            case .highLatency(let current):
                chosen = [fastestFavorite, fastest].compactMap { $0 }.first {
                    $0.delay < highLatencyThreshold && Double($0.delay) < Double(current) * 0.7
                }
            }
            guard let best = chosen else {
                await refreshProxies()
                switch reason {
                case .unreachable:
                    presentIssueNotice(.proxyUnreachable, extraDetail: "已对“\(group.name)”全部可用节点测速，没有找到能连通的节点，可能需要更新订阅。")
                case .manual:
                    let detail = currentDelay > 0
                        ? "当前节点“\(previous)”\(currentDelay) ms，已是“\(group.name)”中最快的可用节点。"
                        : "“\(group.name)”中没有测速成功的节点，可能需要更新订阅。"
                    networkNotice = .info(title: currentDelay > 0 ? "当前节点已是最快" : "没有可用节点", detail: detail, symbol: "speedometer")
                case .highLatency:
                    appendLog(level: "INFO", message: "自动切换：没有明显更快的节点，保持“\(previous)”")
                }
                return
            }
            _ = try await api.request("/proxies/\(encoded)", method: "PUT", json: ["name": best.name])
            selectedProxyGroup = group.name
            await refreshProxies()
            appendLog(level: "INFO", message: "自动切换：\(group.name) 由 \(previous) 切换至 \(best.name)（\(best.delay) ms）")
            recordDiagnostic("auto-switch=\(group.name):\(best.name)")
            let detail: String
            switch reason {
            case .unreachable:
                networkWatchdog.retryAfterRemedy()
                detail = "原节点“\(previous)”无法访问外网，已切换到“\(best.name)”（\(best.delay) ms）。正在重新检测网络…"
            case .highLatency(let current):
                detail = "原节点“\(previous)”延迟 \(current) ms，已切换到更快的“\(best.name)”（\(best.delay) ms）。"
            case .manual:
                detail = "已从“\(previous)”\(currentDelay > 0 ? "（\(currentDelay) ms）" : "")切换到最快的“\(best.name)”（\(best.delay) ms）。"
            }
            let reasonText: String
            switch reason {
            case .unreachable: reasonText = "节点无法连通"
            case .highLatency: reasonText = "延迟过高"
            case .manual: reasonText = "快捷键手动切换"
            }
            recordNetworkEvent(.autoSwitch, title: "切换节点：\(best.name)",
                               detail: "\(reasonText) · \(group.name)：\(previous) → \(best.name)（\(best.delay) ms）")
            if isManual || Date() >= networkAlertsSnoozedUntil {
                networkNotice = .info(title: isManual ? "已切换到最快节点" : "已自动切换节点", detail: detail)
            } else {
                showToast("已自动切换到 \(best.name)")
            }
        } catch {
            appendLog(level: "WARN", message: "自动切换失败：\(error.localizedDescription)")
            if isManual {
                networkNotice = .info(title: "切换失败", detail: error.localizedDescription, symbol: "exclamationmark.circle.fill")
            } else if isUnreachable {
                presentIssueNotice(.proxyUnreachable, extraDetail: "自动切换失败：\(error.localizedDescription)")
            }
        }
    }

    /// 选择要切换的策略组：只处理可手动选择的 Selector 组。
    func autoSwitchTargetGroup() -> ProxyGroup? {
        let selectors = proxyGroups.filter { $0.type == "Selector" && !$0.members.isEmpty }
        if mode == .global { return selectors.first { $0.name == "GLOBAL" } }
        if let current = selectors.first(where: { $0.name == selectedProxyGroup && $0.name != "GLOBAL" }) { return current }
        return selectors.first { $0.name != "GLOBAL" }
    }

    /// 定期测量当前节点延迟；连续两次超过上限时自动切换到更快的节点。
    func checkLatencyIfNeeded() {
        guard highLatencyThreshold > 0, autoSwitchNodeEnabled, coreState == .running, isConnected,
              mode != .direct, networkIssueBadge == nil, !latencyCheckInFlight, !autoSwitchInProgress else { return }
        let interval: TimeInterval = highLatencyStrikes > 0 ? 20 : 60
        guard Date().timeIntervalSince(lastLatencyCheck) >= interval,
              let group = autoSwitchTargetGroup(), !group.now.isEmpty else { return }
        lastLatencyCheck = Date()
        latencyCheckInFlight = true
        let node = group.now
        Task {
            defer { latencyCheckInFlight = false }
            guard let delay = await measureDelay(of: node) else { return } // 连不通由网络监测处理
            guard delay > highLatencyThreshold else {
                highLatencyStrikes = 0
                return
            }
            highLatencyStrikes += 1
            appendLog(level: "WARN", message: "延迟检测：“\(node)”\(delay) ms，超过上限 \(highLatencyThreshold) ms（第 \(highLatencyStrikes) 次）")
            if highLatencyStrikes == 2 {
                recordNetworkEvent(.highLatency, title: "延迟过高：\(node)", detail: "连续两次超过 \(highLatencyThreshold) ms，最近一次 \(delay) ms")
            }
            guard highLatencyStrikes >= 2, !autoSwitchInProgress,
                  Date().timeIntervalSince(lastAutoSwitchAttempt) > 300 else { return }
            highLatencyStrikes = 0
            await autoSwitch(reason: .highLatency(delay))
        }
    }

    func measureDelay(of proxyName: String) async -> Int? {
        let encoded = proxyName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proxyName
        let testURL = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
        guard let data = try? await api.request("/proxies/\(encoded)/delay?url=\(testURL)&timeout=5000"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delay = (json["delay"] as? NSNumber)?.intValue, delay > 0 else { return nil }
        return delay
    }

    // MARK: Favorite / excluded nodes

    func isFavorite(_ name: String) -> Bool { favoriteNodes.contains(name) }
    func isExcluded(_ name: String) -> Bool { excludedNodes.contains(name) }

    func toggleFavorite(_ name: String) {
        if favoriteNodes.remove(name) == nil {
            favoriteNodes.insert(name)
            excludedNodes.remove(name)
            showToast("已设为常用：\(name)")
        } else {
            showToast("已取消常用：\(name)")
        }
        saveNodePreferences()
    }

    func toggleExcluded(_ name: String) {
        if excludedNodes.remove(name) == nil {
            excludedNodes.insert(name)
            favoriteNodes.remove(name)
            showToast("自动切换将跳过：\(name)")
        } else {
            showToast("已允许自动切换到：\(name)")
        }
        saveNodePreferences()
    }

    func saveNodePreferences() {
        UserDefaults.standard.set(Array(favoriteNodes).sorted(), forKey: "favoriteNodes")
        UserDefaults.standard.set(Array(excludedNodes).sorted(), forKey: "autoSwitchExcludedNodes")
    }

    // MARK: Network events

    func recordNetworkEvent(_ kind: NetworkEvent.Kind, title: String, detail: String, duration: TimeInterval? = nil) {
        networkEvents.insert(NetworkEvent(date: Date(), kind: kind, title: title, detail: detail, duration: duration), at: 0)
        if networkEvents.count > NetworkEventStore.limit { networkEvents.removeLast(networkEvents.count - NetworkEventStore.limit) }
        networkEventStore.save(networkEvents)
    }

    func clearNetworkEvents() {
        networkEvents.removeAll()
        networkEventStore.save(networkEvents)
        showToast("网络事件已清空")
    }

    func copyNetworkEvents() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = networkEvents.map { "\(formatter.string(from: $0.date))  \($0.title)  \($0.detail)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("网络事件已复制")
    }

    // MARK: Global hot keys

    func setGlobalHotKeysEnabled(_ enabled: Bool) {
        globalHotKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "globalHotKeysEnabled")
        configureGlobalHotKeys()
        showToast(enabled ? "已开启全局快捷键" : "已关闭全局快捷键")
    }

    func configureGlobalHotKeys() {
        let hotKeys = GlobalHotKeys.shared
        hotKeys.unregisterAll()
        unavailableHotKeys = []
        guard globalHotKeysEnabled else { return }
        for key in KongHotKey.allCases {
            let ok = hotKeys.register(key) { [weak self] in self?.performHotKey(key) }
            if !ok {
                unavailableHotKeys.insert(key.rawValue)
                appendLog(level: "WARN", message: "全局快捷键 \(key.display) 已被其他应用占用")
            }
        }
    }

    func performHotKey(_ key: KongHotKey) {
        switch key {
        case .toggleProxy:
            guard !isChangingConnection else { return }
            Task {
                await setConnectionEnabled(!isConnected)
                networkNotice = .info(title: isConnected ? "系统代理已开启" : "系统代理已关闭",
                                      detail: currentNetworkSummary(), symbol: "power.circle.fill")
            }
        case .cycleMode:
            let next: ProxyMode
            switch mode {
            case .rule: next = .global
            case .global: next = .direct
            case .direct: next = .rule
            }
            setMode(next)
            networkNotice = .info(title: "已切换至\(next.rawValue)模式", detail: currentNetworkSummary(), symbol: "arrow.left.arrow.right.circle.fill")
        case .fastestNode:
            guard coreState == .running, !autoSwitchInProgress else { return }
            networkNotice = .info(title: "正在测速…", detail: "正在为当前策略组测速，完成后切换到最快的节点。", symbol: "speedometer")
            Task { await autoSwitch(reason: .manual) }
        }
    }

    // MARK: Subscription reminders

    /// 订阅到期前 3 天、流量剩余 10% 时各提醒一次（同一情况只提醒一次）。
    func checkSubscriptionReminders() {
        guard subscriptionRemindersEnabled, networkNotice == nil,
              Date().timeIntervalSince(lastSubscriptionReminderCheck) > 600 else { return }
        lastSubscriptionReminderCheck = Date()
        var reminded = Set(UserDefaults.standard.stringArray(forKey: "subscriptionRemindersShown") ?? [])
        for profile in profiles where profile.remoteURL != nil {
            guard let usage = usage(for: profile) else { continue }
            var candidates: [(key: String, notice: NetworkNotice)] = []
            if let expiresAt = usage.expiresAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "M 月 d 日"
                let dateText = formatter.string(from: expiresAt)
                let stamp = Int(expiresAt.timeIntervalSince1970)
                let days = expiresAt.timeIntervalSinceNow / 86_400
                if days <= 0 {
                    candidates.append(("expired-\(profile.id)-\(stamp)", subscriptionNotice(
                        profile, style: .failure, title: "订阅已过期", symbol: "calendar.badge.exclamationmark",
                        detail: "“\(profile.name)”已于 \(dateText) 到期，节点可能无法使用，请续费后更新订阅。")))
                } else if days <= 3 {
                    let left = max(1, Int(days.rounded(.up)))
                    candidates.append(("expiring-\(profile.id)-\(stamp)", subscriptionNotice(
                        profile, style: .warning, title: "订阅即将到期", symbol: "calendar.badge.clock",
                        detail: "“\(profile.name)”将于 \(dateText) 到期，还剩 \(left) 天。")))
                }
            }
            if usage.totalBytes > 0 {
                let remaining = max(0, usage.totalBytes - usage.usedBytes)
                let ratio = Double(remaining) / Double(usage.totalBytes)
                let remainingText = ByteCountFormatter.string(fromByteCount: remaining, countStyle: .decimal)
                if remaining == 0 {
                    candidates.append(("traffic-out-\(profile.id)-\(usage.totalBytes)", subscriptionNotice(
                        profile, style: .failure, title: "订阅流量已用完", symbol: "gauge.with.dots.needle.0percent",
                        detail: "“\(profile.name)”的流量已经用完，节点可能无法使用。")))
                } else if ratio <= 0.1 {
                    candidates.append(("traffic-low-\(profile.id)-\(usage.totalBytes)", subscriptionNotice(
                        profile, style: .warning, title: "订阅流量即将用完", symbol: "gauge.with.dots.needle.33percent",
                        detail: "“\(profile.name)”剩余 \(remainingText)（\(Int((ratio * 100).rounded()))%）。")))
                }
            }
            if let next = candidates.first(where: { !reminded.contains($0.key) }) {
                reminded.insert(next.key)
                UserDefaults.standard.set(Array(reminded), forKey: "subscriptionRemindersShown")
                appendLog(level: "WARN", message: "订阅提醒：\(next.notice.title) · \(profile.name)")
                recordNetworkEvent(.subscription, title: next.notice.title, detail: next.notice.detail)
                networkNotice = next.notice
                return // 一次只弹一个，其余的下次检查再提醒
            }
        }
    }

    func subscriptionNotice(_ profile: Profile, style: NetworkNotice.Style, title: String, symbol: String, detail: String) -> NetworkNotice {
        NetworkNotice(issue: nil, style: style, title: title, detail: detail, symbol: symbol,
                      actions: [.updateSubscription(profileID: profile.id), .openProfiles])
    }

    func handleNetworkRecovery(_ issue: NetworkIssue) {
        networkIssueBadge = nil
        let duration = networkIssueStartedAt.map { Date().timeIntervalSince($0) }
        networkIssueStartedAt = nil
        recordNetworkEvent(.recovered, title: issue == .coreStopped ? "内核已恢复" : "网络已恢复",
                           detail: "\(issue.title)已解除" + (duration.map { "，持续 \(NetworkEvent.durationText($0))" } ?? ""),
                           duration: duration)
        appendLog(level: "INFO", message: "网络检测：已恢复（\(issue.title)）")
        recordDiagnostic("network-recovered=\(issue)")
        let title = issue == .coreStopped ? "Mihomo 内核已恢复运行" : "网络已恢复连接"
        guard Date() >= networkAlertsSnoozedUntil else {
            showToast(title)
            return
        }
        networkNotice = .recovery(issue, title: title, detail: currentNetworkSummary())
    }

    func currentNetworkSummary() -> String {
        let capture: String
        if isConnected {
            capture = tunRequested ? "TUN 已接管" : "\(runtimeSettings.captureMode.rawValue)已开启"
        } else {
            capture = "未接管系统流量"
        }
        return "\(mode.rawValue)模式 · \(capture) · \(selectedNodeID)"
    }

    func networkNoticeDetail(for issue: NetworkIssue) -> String {
        switch issue {
        case .offline:
            return "Mac 没有连接到任何网络（Wi‑Fi 或有线），请检查网络连接。"
        case .internetUnreachable:
            return "已连接网络，但无法访问互联网。校园网、酒店或公共 Wi‑Fi 可能需要先在浏览器中登录认证。"
        case .proxyUnreachable:
            return "本机网络正常，但经当前节点无法访问外网。\n当前节点：\(selectedProxyGroup) → \(selectedNodeID)\n节点可能失效或订阅已过期。"
        case .coreStopped:
            let reason: String
            if case .failed(let message) = coreState { reason = message } else { reason = "未知原因" }
            return "代理内核已停止，经 KongBabel 的连接将全部失败。\n原因：\(String(reason.prefix(160)))"
        }
    }

    func performNetworkNoticeAction(_ action: NetworkNoticeAction) {
        networkNotice = nil
        switch action {
        case .openNetworkSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .testAndSwitch:
            showMainWindow(section: .proxies)
            testLatency()
            networkWatchdog.recheckSoon()
        case .diagnose:
            showMainWindow(section: .overview)
            runNetworkDiagnostics()
        case .restartCore:
            Task { await startCore() }
        case .showLogs:
            showMainWindow(section: .logs)
        case .updateSubscription(let profileID):
            if let profile = profiles.first(where: { $0.id == profileID }) { updateProfile(profile) }
        case .openProfiles:
            showMainWindow(section: .profiles)
        }
    }

    func dismissNetworkNotice(snooze: Bool = false) {
        if snooze {
            networkAlertsSnoozedUntil = Date().addingTimeInterval(30 * 60)
            showToast("30 分钟内不再提醒网络状态")
        }
        networkNotice = nil
    }

    func showMainWindow(section: SidebarSection) {
        selectedSection = section
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}
