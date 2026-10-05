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
            recordGroupDelays(delays, members: group.members)
            let excluded: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]
            var candidates: [SwitchCandidate] = []
            for (name, value) in delays {
                guard name != previous, !excluded.contains(name.uppercased()), !excludedNodes.contains(name), !Self.isInfoNodeName(name),
                      let delay = (value as? NSNumber)?.intValue, delay > 0 else { continue }
                let rate = multiplier(for: name) ?? 1
                if maxAutoSwitchMultiplier > 0, rate > maxAutoSwitchMultiplier + 0.0001 { continue }
                candidates.append((name: name, delay: delay, multiplier: rate, favorite: favoriteNodes.contains(name)))
            }
            // 常用节点优先；开启“低倍率优先”时，在延迟相近的节点中选倍率最低的
            let fastest = pickSwitchCandidate(candidates)
            let fastestFavorite = pickSwitchCandidate(candidates.filter { $0.favorite })
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
            recordNodeSwitchedAway(previous)
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
            let measured = await measureDelay(of: node)
            recordNodeDelay(node, delay: measured)
            saveNodeStats()
            guard let delay = measured else { return } // 连不通由网络监测处理
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
            let binding = hotKeyBinding(for: key)
            let ok = hotKeys.register(key, binding: binding) { [weak self] in self?.performHotKey(key) }
            if !ok {
                unavailableHotKeys.insert(key.rawValue)
                appendLog(level: "WARN", message: "全局快捷键 \(binding.display) 已被其他应用占用")
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

    // MARK: Node stability

    /// 记录一次测速结果：delay 为 nil 或 0 表示失败
    func recordNodeDelay(_ name: String, delay: Int?) {
        var stats = nodeStats[name] ?? NodeStats()
        if let delay, delay > 0 {
            stats.samples.append(.init(date: Date(), delay: delay))
        } else {
            stats.failures.append(Date())
        }
        stats.prune()
        nodeStats[name] = stats
    }

    /// 记录一次策略组测速：组内测速失败的节点不会出现在结果里，按失败计
    func recordGroupDelays(_ delays: [String: Any], members: [String]) {
        let special: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
        for member in members where !special.contains(member.uppercased()) && !Self.isInfoNodeName(member) {
            recordNodeDelay(member, delay: (delays[member] as? NSNumber)?.intValue)
        }
        saveNodeStats()
    }

    func recordNodeSwitchedAway(_ name: String) {
        var stats = nodeStats[name] ?? NodeStats()
        stats.switchedAway.append(Date())
        stats.prune()
        nodeStats[name] = stats
        saveNodeStats()
    }

    func saveNodeStats() {
        nodeStatsStore.save(nodeStats)
    }

    // MARK: Custom hot keys

    func hotKeyBinding(for key: KongHotKey) -> HotKeyBinding {
        hotKeyBindings[key.rawValue] ?? key.defaultBinding
    }

    func isCustomHotKey(_ key: KongHotKey) -> Bool {
        hotKeyBindings[key.rawValue] != nil
    }

    /// 开始录制：暂停全局快捷键，等待用户在设置页按下新组合（Esc 取消）
    func beginRecordingHotKey(_ key: KongHotKey) {
        stopRecordingHotKey(reconfigure: false)
        recordingHotKey = key
        GlobalHotKeys.shared.unregisterAll()
        hotKeyRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleHotKeyRecording(event)
        }
    }

    func stopRecordingHotKey(reconfigure: Bool = true) {
        if let monitor = hotKeyRecorder { NSEvent.removeMonitor(monitor) }
        hotKeyRecorder = nil
        recordingHotKey = nil
        if reconfigure { configureGlobalHotKeys() }
    }

    func resetHotKey(_ key: KongHotKey) {
        hotKeyBindings[key.rawValue] = nil
        saveHotKeyBindings()
        configureGlobalHotKeys()
        showToast("已恢复默认快捷键 \(key.display)")
    }

    func handleHotKeyRecording(_ event: NSEvent) -> NSEvent? {
        guard let key = recordingHotKey else { return event }
        if event.keyCode == 53 { // Esc
            stopRecordingHotKey()
            return nil
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep()
            showToast("快捷键需要包含 ⌘、⌥ 或 ⌃ 中的至少一个")
            return nil
        }
        let newBinding = HotKeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: HotKeyBinding.carbonModifiers(from: flags),
            display: HotKeyBinding.displayString(flags: flags, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        )
        if let other = KongHotKey.allCases.first(where: { $0 != key && hotKeyBinding(for: $0).sameKeys(as: newBinding) }) {
            NSSound.beep()
            showToast("\(newBinding.display) 已用于“\(other.title)”")
            return nil
        }
        hotKeyBindings[key.rawValue] = newBinding.sameKeys(as: key.defaultBinding) ? nil : newBinding
        saveHotKeyBindings()
        stopRecordingHotKey()
        if unavailableHotKeys.contains(key.rawValue) {
            showToast("\(newBinding.display) 已被其他应用占用，请换一个")
        } else {
            showToast("“\(key.title)”已改为 \(newBinding.display)")
        }
        return nil
    }

    func saveHotKeyBindings() {
        var saved: [String: HotKeyBinding] = [:]
        for (id, binding) in hotKeyBindings { saved[String(id)] = binding }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "hotKeyBindings")
        }
    }

    // MARK: Update check

    func setAutoUpdateCheckEnabled(_ enabled: Bool) {
        autoUpdateCheckEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoUpdateCheckEnabled")
        if enabled { lastUpdateCheckAttempt = .distantPast }
        showToast(enabled ? "将每天自动检查更新" : "已关闭自动检查更新")
    }

    /// 启动 1 分钟后检查一次，之后每天一次；失败后 1 小时内不重试
    func checkForUpdatesIfNeeded() {
        guard autoUpdateCheckEnabled, !updateCheckInProgress,
              let startedAt = coreStartedAt, Date().timeIntervalSince(startedAt) > 60,
              Date().timeIntervalSince(lastUpdateCheckAttempt) > 3_600 else { return }
        let lastSuccess = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastSuccess) > 86_400 else { return }
        checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) {
        guard !updateCheckInProgress else { return }
        updateCheckInProgress = true
        lastUpdateCheckAttempt = Date()
        Task {
            defer { updateCheckInProgress = false }
            do {
                guard let release = try await UpdateChecker.fetchLatest() else {
                    UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                    if manual {
                        networkNotice = .info(title: "暂无发布版本", detail: "GitHub 上还没有发布过 KongBabel 的版本。可以用 ./build.sh --release 发布。", symbol: "shippingbox.fill")
                    }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                guard UpdateChecker.isNewer(release.version, than: AppInfo.version) else {
                    latestRelease = release
                    if manual {
                        networkNotice = .info(title: "已是最新版本", detail: "当前版本 \(AppInfo.version)，GitHub 上最新为 \(release.version)。", symbol: "checkmark.seal.fill")
                    }
                    return
                }
                latestRelease = release
                let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
                guard manual || skipped != release.version else { return }
                let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                var detail = "当前版本 \(AppInfo.version)，可升级到 \(release.version)。"
                if !notes.isEmpty { detail += "\n" + String(notes.prefix(160)) }
                networkNotice = NetworkNotice(
                    issue: nil, style: .update, title: "发现新版本 \(release.version)", detail: detail,
                    symbol: "arrow.down.circle.fill",
                    actions: [.downloadUpdate(url: (release.downloadURL ?? release.pageURL).absoluteString), .skipVersion(release.version)]
                )
            } catch {
                if manual {
                    networkNotice = .info(title: "检查更新失败", detail: error.localizedDescription, symbol: "exclamationmark.circle.fill")
                }
            }
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
        case .downloadUpdate(let url):
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        case .skipVersion(let version):
            UserDefaults.standard.set(version, forKey: "skippedUpdateVersion")
            showToast("已跳过 \(version)，有更新的版本时会再提醒")
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
