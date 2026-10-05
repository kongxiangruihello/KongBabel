import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

@MainActor
final class AppModel: NSObject, ObservableObject {
    let menuBarIcon: NSImage = {
        let image: NSImage
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let bundledImage = NSImage(contentsOf: url) {
            image = bundledImage
        } else {
            image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "KongBabel")
                ?? NSApplication.shared.applicationIconImage
        }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true
        return image
    }()

    @Published var selectedSection: SidebarSection = .overview
    @Published var isConnected = false
    @Published var isChangingConnection = false
    @Published var coreState: CoreState = .stopped
    @Published var coreVersion = "检测中"
    @Published var mode: ProxyMode = .rule
    @Published var selectedNodeID = "DIRECT"
    @Published var selectedProxyGroup = "节点选择"
    @Published var proxyGroups: [ProxyGroup] = []
    /// 每个节点最近一次测速的延迟（毫秒）；0 表示测速失败，没有键表示还没测过
    @Published var proxyDelays: [String: Int] = [:]
    @Published var searchText = ""
    @Published var uploadRate = 0.0
    @Published var downloadRate = 0.0
    @Published var totalUpload = 0.0
    @Published var totalDownload = 0.0
    @Published var latencyTesting = false
    @Published var activity: [Double] = Array(repeating: 0.03, count: 18)
    @Published var logs: [LogEntry] = []
    @Published var profiles: [Profile] = []
    @Published var activeProfileID = "default"
    @Published var showImportSheet = false
    @Published var showCommandPalette = false
    @Published var showInspector = false
    @Published var toast: String?
    @Published var alertMessage: String?
    @Published var httpPort = 7890
    @Published var socksPort = 7890
    @Published var runtimeSettings: RuntimeSettings
    @Published var detectedCaptureMode: ProxyCaptureMode?
    @Published var subscriptionUpdateInProgress = false
    @Published var showProfileSettings = false
    @Published var profileBeingEdited: Profile?
    @Published var showYAMLEditor = false
    @Published var editingYAML = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var showMenuBarRates = UserDefaults.standard.object(forKey: "showMenuBarRates") as? Bool ?? true
    @Published var coreStartedAt: Date?
    @Published var webDAVSettings: WebDAVSettings
    @Published var webDAVPassword: String
    @Published var webDAVBusy = false
    @Published var trafficHistory: [DailyTraffic]
    @Published var networkAlertsEnabled = UserDefaults.standard.object(forKey: "networkAlertsEnabled") as? Bool ?? true
    /// 菜单栏图标下方弹出的网络状态提示；nil 表示不显示。
    @Published var networkNotice: NetworkNotice?
    /// 当前未恢复的网络故障，用于菜单栏图标上的状态小圆点；nil 表示网络正常。
    @Published var networkIssueBadge: NetworkIssue?
    @Published var autoSwitchNodeEnabled = UserDefaults.standard.object(forKey: "autoSwitchNodeEnabled") as? Bool ?? true
    /// 延迟上限（毫秒），连续两次超过即自动切换节点；0 表示关闭。
    @Published var highLatencyThreshold = UserDefaults.standard.object(forKey: "highLatencyThreshold") as? Int ?? 1_000
    @Published var subscriptionRemindersEnabled = UserDefaults.standard.object(forKey: "subscriptionRemindersEnabled") as? Bool ?? true
    /// 用户标记的常用节点：自动切换时优先选择
    @Published var favoriteNodes = Set(UserDefaults.standard.stringArray(forKey: "favoriteNodes") ?? [])
    /// 用户排除的节点：自动切换时不会切到这里
    @Published var excludedNodes = Set(UserDefaults.standard.stringArray(forKey: "autoSwitchExcludedNodes") ?? [])
    @Published var globalHotKeysEnabled = UserDefaults.standard.object(forKey: "globalHotKeysEnabled") as? Bool ?? true
    @Published var unavailableHotKeys: Set<UInt32> = []
    @Published var networkEvents: [NetworkEvent]
    /// 各节点近 7 天的稳定性记录
    @Published var nodeStats: [String: NodeStats]
    /// 用户自定义的全局快捷键（键为 KongHotKey.rawValue）；未自定义的用默认组合
    @Published var hotKeyBindings: [UInt32: HotKeyBinding]
    @Published var recordingHotKey: KongHotKey?
    @Published var autoUpdateCheckEnabled = UserDefaults.standard.object(forKey: "autoUpdateCheckEnabled") as? Bool ?? true
    @Published var latestRelease: ReleaseInfo?
    @Published var updateCheckInProgress = false

    @Published var nodes: [ProxyNode] = []
    @Published var connections: [ConnectionItem] = []
    @Published var rules: [RuleItem] = []

    var timer: Timer?
    let repository: ProfileRepository
    let core = MihomoProcess()
    let api: MihomoAPI
    let controllerPort: Int
    let systemProxy: SystemProxyManager
    let settingsStore: RuntimeSettingsStore
    let webDAVSettingsStore: WebDAVSettingsStore
    let webDAVCredentialStore: WebDAVCredentialStore
    let webDAVClient = WebDAVClient()
    let trafficHistoryStore: TrafficHistoryStore
    let networkEventStore: NetworkEventStore
    let nodeStatsStore: NodeStatsStore
    var hotKeyRecorder: Any?
    var lastUpdateCheckAttempt = Date.distantPast
    var networkIssueStartedAt: Date?
    var refreshCounter = 0
    var isRefreshing = false
    var lastTrafficDate = Date()
    var lastUploadBytes: Double = 0
    var lastDownloadBytes: Double = 0
    var pendingHistoryUpload: Int64 = 0
    var pendingHistoryDownload: Int64 = 0
    var tunRequested = false
    var lastSubscriptionCheck = Date.distantPast
    let networkWatchdog = NetworkWatchdog()
    var networkAlertsSnoozedUntil = Date.distantPast
    var autoSwitchInProgress = false
    var lastAutoSwitchAttempt = Date.distantPast
    var lastLatencyCheck = Date.distantPast
    var latencyCheckInFlight = false
    var highLatencyStrikes = 0
    var lastSubscriptionReminderCheck = Date.distantPast

    override init() {
        let repository = ProfileRepository()
        try? repository.prepare()
        let secret = (try? repository.loadOrCreateSecret()) ?? "aero-local-controller"
        MihomoProcess.cleanupStaleProcess(pidFileURL: repository.root.appendingPathComponent("mihomo.pid"))
        let controllerPort = LocalPort.firstAvailable(startingAt: 19097)
        self.repository = repository
        self.controllerPort = controllerPort
        self.api = MihomoAPI(secret: secret, port: controllerPort)
        self.systemProxy = SystemProxyManager(appSupportDirectory: repository.root)
        let settingsStore = RuntimeSettingsStore(root: repository.root)
        self.settingsStore = settingsStore
        self.runtimeSettings = settingsStore.load()
        let webDAVSettingsStore = WebDAVSettingsStore(root: repository.root)
        self.webDAVSettingsStore = webDAVSettingsStore
        self.webDAVSettings = webDAVSettingsStore.load()
        let webDAVCredentialStore = WebDAVCredentialStore()
        self.webDAVCredentialStore = webDAVCredentialStore
        self.webDAVPassword = webDAVCredentialStore.loadPassword()
        let trafficHistoryStore = TrafficHistoryStore(root: repository.root)
        self.trafficHistoryStore = trafficHistoryStore
        self.trafficHistory = trafficHistoryStore.load()
        let networkEventStore = NetworkEventStore(root: repository.root)
        self.networkEventStore = networkEventStore
        self.networkEvents = networkEventStore.load()
        let nodeStatsStore = NodeStatsStore(root: repository.root)
        self.nodeStatsStore = nodeStatsStore
        self.nodeStats = nodeStatsStore.load()
        if let data = UserDefaults.standard.data(forKey: "hotKeyBindings"),
           let saved = try? JSONDecoder().decode([String: HotKeyBinding].self, from: data) {
            var bindings: [UInt32: HotKeyBinding] = [:]
            for entry in saved {
                if let id = UInt32(entry.key) { bindings[id] = entry.value }
            }
            self.hotKeyBindings = bindings
        } else {
            self.hotKeyBindings = [:]
        }
        let loadedProfiles = repository.loadProfiles()
        self.profiles = loadedProfiles
        let savedID = UserDefaults.standard.string(forKey: "activeProfileID")
            ?? UserDefaults(suiteName: "com.aero.networkconsole")?.string(forKey: "activeProfileID")
            ?? "default"
        self.activeProfileID = loadedProfiles.contains(where: { $0.id == savedID }) ? savedID : "default"
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshRuntime()
                self?.networkWatchdog.tick()
                self?.checkLatencyIfNeeded()
                self?.checkSubscriptionReminders()
                self?.checkForUpdatesIfNeeded()
            }
        }
        configureNetworkWatchdog()
        configureGlobalHotKeys()
        Task { await startCore() }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    var selectedNode: ProxyNode {
        nodes.first(where: { $0.id == selectedNodeID }) ?? nodes.first ?? .placeholder
    }

    var activeConnections: [ConnectionItem] {
        connections.filter { $0.status == .active }
    }

    var modeBinding: Binding<ProxyMode> {
        Binding(get: { self.mode }, set: { self.setMode($0) })
    }

    var uptimeText: String {
        guard let coreStartedAt else { return "00:00:00" }
        let total = max(0, Int(Date().timeIntervalSince(coreStartedAt)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    var menuBarDownloadRateText: String {
        menuBarRate(downloadRate)
    }

    var menuBarUploadRateText: String {
        menuBarRate(uploadRate)
    }

    func menuBarRate(_ megabytesPerSecond: Double) -> String {
        let parts = rateParts(megabytesPerSecond)
        return parts.value + parts.unit
    }

    /// 统一的速率格式：小于 1 MB/s 显示 KB/s（整数），否则显示 MB/s（两位小数）。
    func rateParts(_ megabytesPerSecond: Double) -> (value: String, unit: String) {
        if megabytesPerSecond < 1 {
            return ("\(Int((megabytesPerSecond * 1_024).rounded()))", "KB/s")
        }
        return (String(format: "%.2f", megabytesPerSecond), "MB/s")
    }

    func rateText(_ megabytesPerSecond: Double) -> String {
        let parts = rateParts(megabytesPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    func startCore() async {
        guard coreState != .starting else { return }
        coreState = .starting
        do {
            coreState = .stopped
            core.stop()
            coreState = .starting
            try repository.prepare()
            guard let profile = profiles.first(where: { $0.id == activeProfileID }) else { throw AeroRuntimeError.missingProfile }
            guard let stableCoreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
            let requestedCoreURL = Bundle.main.url(forResource: runtimeSettings.coreChannel.resourceName, withExtension: nil)
            let coreURL = requestedCoreURL ?? stableCoreURL
            if runtimeSettings.coreChannel == .preview, requestedCoreURL == nil {
                runtimeSettings.coreChannel = .stable
                try? settingsStore.save(runtimeSettings)
                showToast("预览版内核未随构建提供，已使用稳定版")
            }

            var effectiveSettings = runtimeSettings
            if effectiveSettings.useMixedPort {
                let preferred = validPort(effectiveSettings.mixedPort, fallback: 17_890)
                let port = LocalPort.isAvailable(preferred) ? preferred : LocalPort.firstAvailable(startingAt: preferred + 1)
                effectiveSettings.mixedPort = port
                httpPort = port
                socksPort = port
            } else {
                let preferredHTTP = validPort(effectiveSettings.httpPort, fallback: 17_890)
                let web = LocalPort.isAvailable(preferredHTTP) ? preferredHTTP : LocalPort.firstAvailable(startingAt: preferredHTTP + 1)
                let preferredSOCKS = validPort(effectiveSettings.socksPort, fallback: 17_891)
                let socks = preferredSOCKS != web && LocalPort.isAvailable(preferredSOCKS) ? preferredSOCKS : LocalPort.firstAvailable(startingAt: max(web + 1, preferredSOCKS + 1))
                effectiveSettings.httpPort = web
                effectiveSettings.socksPort = socks
                httpPort = web
                socksPort = socks
            }
            recordDiagnostic("selected-ports=http:\(httpPort),socks:\(socksPort),capture:\(runtimeSettings.captureMode.rawValue)")
            let configURL = try repository.prepareRuntimeConfig(for: profile, settings: effectiveSettings, tunEnabled: tunRequested, coreURL: coreURL)
            try core.start(executableURL: coreURL, configURL: configURL, dataDirectory: repository.root, secret: api.secret, controllerPort: controllerPort, pidFileURL: repository.root.appendingPathComponent("mihomo.pid"), onOutput: { [weak self] line in
                Task { @MainActor in self?.appendCoreLog(line) }
            }, onExit: { [weak self] status in
                Task { @MainActor in
                    guard let self, self.coreState != .stopped else { return }
                    self.coreState = status == 0 ? .stopped : .failed("Mihomo 已退出，代码 \(status)")
                    self.coreStartedAt = nil
                    self.isConnected = false
                }
            })
            try await api.waitUntilReady()
            let patch: [String: Any] = [
                "mixed-port": effectiveSettings.useMixedPort ? effectiveSettings.mixedPort : 0,
                "port": effectiveSettings.useMixedPort ? 0 : effectiveSettings.httpPort,
                "socks-port": effectiveSettings.useMixedPort ? 0 : effectiveSettings.socksPort,
                "allow-lan": effectiveSettings.allowLAN,
                "bind-address": effectiveSettings.allowLAN ? "*" : "127.0.0.1"
            ]
            _ = try await api.request("/configs", method: "PATCH", json: patch)
            try await Task.sleep(nanoseconds: 180_000_000)
            let runtimeConfigData = try await api.request("/configs")
            recordDiagnostic("runtime-config=\(String(data: runtimeConfigData, encoding: .utf8) ?? "unreadable")")
            guard let runtimeConfig = try JSONSerialization.jsonObject(with: runtimeConfigData) as? [String: Any],
                  runtimePortMatches(runtimeConfig, settings: effectiveSettings) else {
                throw AeroRuntimeError.commandFailed("无法启用指定代理端口")
            }
            coreState = .running
            coreStartedAt = Date()
            let versionData = try await api.request("/version")
            if let json = try JSONSerialization.jsonObject(with: versionData) as? [String: Any] {
                coreVersion = (json["version"] as? String) ?? "v1.19.30"
            }
            await refreshRuntime(force: true)
            if tunRequested { isConnected = true }
            detectedCaptureMode = systemProxy.status(httpPort: httpPort, socksPort: socksPort, pacURL: repository.pacURL)
            if detectedCaptureMode != nil { isConnected = true }
            showToast("Mihomo \(coreVersion) 已启动")
        } catch {
            recordDiagnostic("startup-error=\(error.localizedDescription)")
            coreState = .failed(error.localizedDescription)
            appendLog(level: "ERROR", message: error.localizedDescription)
            showToast("内核启动失败：\(error.localizedDescription)")
        }
    }

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

    func toggleConnection() {
        guard !isChangingConnection else { return }
        Task { await setConnectionEnabled(!isConnected) }
    }

    func setConnectionEnabled(_ enabled: Bool) async {
        guard !isChangingConnection else { return }
        isChangingConnection = true
        defer { isChangingConnection = false }
        do {
            let proxy = systemProxy
            if enabled {
                if runtimeSettings.captureMode == .tun {
                    if proxy.hasActiveSnapshot { try await Task.detached { try proxy.disable() }.value }
                    tunRequested = true
                    await startCore()
                    guard coreState == .running else {
                        tunRequested = false
                        throw AeroRuntimeError.commandFailed("TUN 启动失败。macOS 若拒绝创建路由，需要安装经过签名的特权辅助程序")
                    }
                } else {
                    tunRequested = false
                    if coreState != .running { await startCore() }
                    guard coreState == .running else { throw AeroRuntimeError.commandFailed("Mihomo 内核未运行") }
                    let web = httpPort
                    let socks = socksPort
                    if runtimeSettings.captureMode == .pac {
                        let pacURL = try repository.writePAC(httpPort: web, socksPort: socks)
                        try await Task.detached { try proxy.enablePAC(url: pacURL) }.value
                    } else {
                        try await Task.detached { try proxy.enable(httpPort: web, socksPort: socks) }.value
                    }
                }
            } else {
                if proxy.hasActiveSnapshot { try await Task.detached { try proxy.disable() }.value }
                if tunRequested {
                    tunRequested = false
                    await startCore()
                }
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { isConnected = enabled }
            detectedCaptureMode = enabled ? runtimeSettings.captureMode : nil
            networkWatchdog.recheckSoon()
            showToast(enabled ? "\(runtimeSettings.captureMode.rawValue) 已开启" : "网络设置已恢复")
        } catch {
            isConnected = false
            showToast("系统代理设置失败：\(error.localizedDescription)")
            appendLog(level: "ERROR", message: error.localizedDescription)
        }
    }

    func saveAndApplySettings() {
        do {
            runtimeSettings.mixedPort = validPort(runtimeSettings.mixedPort, fallback: 17_890)
            runtimeSettings.httpPort = validPort(runtimeSettings.httpPort, fallback: 17_890)
            runtimeSettings.socksPort = validPort(runtimeSettings.socksPort, fallback: 17_891)
            try settingsStore.save(runtimeSettings)
            Task {
                let reconnect = isConnected
                if reconnect { await setConnectionEnabled(false) }
                await startCore()
                if reconnect { await setConnectionEnabled(true) }
                showToast("高级网络设置已应用")
            }
        } catch { presentError("保存设置失败", error) }
    }

    func resetRuntimeSettings() {
        runtimeSettings = .standard
        saveAndApplySettings()
    }

    func saveWebDAVSettings() {
        do {
            webDAVSettings.serverURL = webDAVSettings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            webDAVSettings.username = String(webDAVSettings.username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            webDAVSettings.remotePath = String(webDAVSettings.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            try webDAVSettingsStore.save(webDAVSettings)
            try webDAVCredentialStore.savePassword(webDAVPassword)
            showToast("WebDAV 设置已安全保存")
        } catch { presentError("保存 WebDAV 设置失败", error) }
    }

    func backupToWebDAV() {
        guard !webDAVBusy else { return }
        webDAVBusy = true
        Task {
            defer { webDAVBusy = false }
            do {
                try webDAVSettingsStore.save(webDAVSettings)
                try webDAVCredentialStore.savePassword(webDAVPassword)
                let bundle = try repository.makeBackupBundle(profiles: profiles, settings: runtimeSettings)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(bundle)
                try await webDAVClient.upload(data, settings: webDAVSettings, password: webDAVPassword)
                showToast("WebDAV 备份完成 · \(profiles.count) 个配置")
            } catch { presentError("WebDAV 备份失败", error) }
        }
    }

    func restoreFromWebDAV() {
        guard !webDAVBusy else { return }
        let alert = NSAlert()
        alert.messageText = "从 WebDAV 恢复 KongBabel？"
        alert.informativeText = "将恢复配置、订阅偏好和网络覆写设置。当前配置会先保留本地备份。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        webDAVBusy = true
        Task {
            defer { webDAVBusy = false }
            do {
                let data = try await webDAVClient.download(settings: webDAVSettings, password: webDAVPassword)
                let bundle = try JSONDecoder().decode(AeroBackupBundle.self, from: data)
                guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else {
                    throw AeroRuntimeError.missingCore
                }
                let restored = try repository.restoreBackup(bundle, coreURL: coreURL)
                profiles = restored.0
                runtimeSettings = restored.1
                try settingsStore.save(runtimeSettings)
                if !profiles.contains(where: { $0.id == activeProfileID }) {
                    activeProfileID = profiles[0].id
                    UserDefaults.standard.set(activeProfileID, forKey: "activeProfileID")
                }
                await startCore()
                showToast("WebDAV 恢复完成 · \(profiles.count) 个配置")
            } catch { presentError("WebDAV 恢复失败", error) }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            showToast(launchAtLogin ? "已启用登录时启动" : "已关闭登录时启动")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            presentError("开机启动设置失败", error)
        }
    }

    func setShowMenuBarRates(_ enabled: Bool) {
        showMenuBarRates = enabled
        UserDefaults.standard.set(enabled, forKey: "showMenuBarRates")
        showToast(enabled ? "已显示菜单栏实时速率" : "已隐藏菜单栏实时速率")
    }

    func setAllowLAN(_ enabled: Bool) {
        guard runtimeSettings.allowLAN != enabled else { return }
        runtimeSettings.allowLAN = enabled
        saveAndApplySettings()
    }

    func copyTerminalProxyCommand() {
        let command = "export http_proxy=http://127.0.0.1:\(httpPort) https_proxy=http://127.0.0.1:\(httpPort) all_proxy=socks5://127.0.0.1:\(socksPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        showToast("终端代理命令已复制")
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

    func activateProfile(_ profile: Profile) {
        guard profile.id != activeProfileID else { return }
        activeProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "activeProfileID")
        Task {
            await startCore()
            showToast("已应用配置“\(profile.name)”")
        }
    }

    func importProfile(from urlString: String) {
        guard let url = SubscriptionDownloader.normalizedURL(from: urlString) else {
            presentError("无法添加订阅", SubscriptionDownloadError.invalidURL)
            return
        }
        Task {
            do {
                let (data, response) = try await downloadSubscription(from: url)
                let name = subscriptionName(from: response) ?? url.host ?? "订阅配置"
                try installProfile(data: data, name: name, remoteURL: url.absoluteString, response: response)
            } catch { presentError("添加订阅失败", error) }
        }
    }

    func importLocalProfile() {
        let panel = NSOpenPanel()
        panel.title = "选择 Mihomo / Clash 配置"
        panel.allowedContentTypes = [.data, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try installProfile(data: data, name: url.deletingPathExtension().lastPathComponent, remoteURL: nil, response: nil)
        } catch { presentError("导入配置失败", error) }
    }

    func updateProfile(_ profile: Profile) {
        guard let remote = profile.remoteURL, let url = URL(string: remote) else {
            showToast("本地配置没有远程更新地址")
            return
        }
        Task {
            do {
                let (data, response) = try await downloadSubscription(from: url, profileID: profile.id)
                try replaceProfile(profile, with: data, response: response)
                markSubscriptionUpdated(profileID: profile.id, response: response)
                showToast("“\(profile.name)”已更新")
                if profile.id == activeProfileID { await startCore() }
            } catch { presentError("更新订阅失败", error) }
        }
    }

    func installProfile(data: Data, name: String, remoteURL: String?, response: HTTPURLResponse?) throws {
        guard data.count < 20_000_000 else { throw AeroRuntimeError.commandFailed("配置文件超过 20 MB") }
        try repository.prepare()
        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).yaml"
        let destination = repository.profilesDirectory.appendingPathComponent(fileName)
        let temporary = repository.root.appendingPathComponent("import-\(id).yaml")
        let prepared = try SubscriptionFormatter.prepare(data: data, id: id)
        var installedProviderURL: URL?
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed {
                try? FileManager.default.removeItem(at: destination)
                if let installedProviderURL { try? FileManager.default.removeItem(at: installedProviderURL) }
            }
        }
        try prepared.configData.write(to: temporary, options: .atomic)
        if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
            let providerURL = repository.providersDirectory.appendingPathComponent(providerFileName)
            try providerData.write(to: providerURL, options: .atomic)
            try secureFile(at: providerURL)
            installedProviderURL = providerURL
        }
        guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
        try repository.validate(configURL: temporary, coreURL: coreURL)
        try prepared.configData.write(to: destination, options: .atomic)
        try secureFile(at: destination)
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let source = remoteURL == nil ? "\(prepared.label) · 本地配置" : "\(prepared.label) · 远程订阅"
        let profile = Profile(id: id, name: name, source: source, updated: "刚刚更新", size: size, fileName: fileName, remoteURL: remoteURL, format: prepared.label, payloadFileName: prepared.providerFileName)
        let updatedProfiles = profiles + [profile]
        try repository.saveProfiles(updatedProfiles)
        profiles = updatedProfiles
        if let response { markSubscriptionUpdated(profileID: id, response: response) }
        committed = true
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: "activeProfileID")
        Task { await startCore() }
        let nodeSummary = prepared.nodeCount.map { " · \($0) 个节点" } ?? ""
        showToast("配置校验通过并已导入\(nodeSummary)")
    }

    func replaceProfile(_ profile: Profile, with data: Data, response: HTTPURLResponse) throws {
        guard data.count < 20_000_000 else { throw AeroRuntimeError.commandFailed("配置文件超过 20 MB") }
        try repository.prepare()
        let prepared = try SubscriptionFormatter.prepare(data: data, id: profile.id)
        let destination = repository.fileURL(for: profile)
        let temporary = repository.root.appendingPathComponent("update-\(UUID().uuidString).yaml")
        let previousConfig = try Data(contentsOf: destination)
        let oldProviderURL = profile.payloadFileName.map { repository.providersDirectory.appendingPathComponent($0) }
        let previousProvider = oldProviderURL.flatMap { try? Data(contentsOf: $0) }
        var newProviderURL: URL?
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed {
                try? previousConfig.write(to: destination, options: .atomic)
                if let newProviderURL {
                    if newProviderURL == oldProviderURL, let previousProvider {
                        try? previousProvider.write(to: newProviderURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: newProviderURL)
                    }
                }
            }
        }

        try repository.backup(profile)
        try prepared.configData.write(to: temporary, options: .atomic)
        if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
            let providerURL = repository.providersDirectory.appendingPathComponent(providerFileName)
            try providerData.write(to: providerURL, options: .atomic)
            try secureFile(at: providerURL)
            newProviderURL = providerURL
        }
        guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
        try repository.validate(configURL: temporary, coreURL: coreURL)
        try prepared.configData.write(to: destination, options: .atomic)
        try secureFile(at: destination)

        let displayName = subscriptionName(from: response) ?? profile.name
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let updated = Profile(id: profile.id, name: displayName, source: "\(prepared.label) · 远程订阅", updated: "刚刚更新", size: size, fileName: profile.fileName, remoteURL: profile.remoteURL, format: prepared.label, payloadFileName: prepared.providerFileName)
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw AeroRuntimeError.missingProfile }
        var updatedProfiles = profiles
        updatedProfiles[index] = updated
        try repository.saveProfiles(updatedProfiles)
        profiles = updatedProfiles
        committed = true
        if let oldProviderURL, oldProviderURL != newProviderURL { try? FileManager.default.removeItem(at: oldProviderURL) }
    }

    func downloadSubscription(from url: URL, profileID: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let userAgent = profileID.flatMap { runtimeSettings.subscriptionPreferences[$0]?.userAgent }
        let result = try await SubscriptionDownloader.download(from: url, preferredUserAgent: userAgent)
        recordDiagnostic("subscription-client-profile=\(result.clientProfile)")
        return (result.data, result.response)
    }

    func preference(for profile: Profile) -> SubscriptionPreference {
        runtimeSettings.subscriptionPreferences[profile.id] ?? SubscriptionPreference()
    }

    func usage(for profile: Profile) -> SubscriptionUsage? {
        runtimeSettings.subscriptionUsage[profile.id]
    }

    func editSettings(for profile: Profile) {
        profileBeingEdited = profile
        showProfileSettings = true
    }

    func savePreference(for profile: Profile, intervalHours: Int, userAgent: String) {
        var preference = preference(for: profile)
        preference.updateIntervalHours = min(720, max(1, intervalHours))
        preference.userAgent = String(userAgent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        runtimeSettings.subscriptionPreferences[profile.id] = preference
        try? settingsStore.save(runtimeSettings)
        showToast("订阅更新设置已保存")
    }

    func updateAllSubscriptions(force: Bool = true) {
        guard !subscriptionUpdateInProgress else { return }
        subscriptionUpdateInProgress = true
        Task {
            defer { subscriptionUpdateInProgress = false }
            var updated = 0
            var activeUpdated = false
            for profile in profiles where profile.remoteURL != nil {
                let preference = preference(for: profile)
                let due = preference.lastUpdated.map { Date().timeIntervalSince($0) >= Double(preference.updateIntervalHours * 3600) } ?? true
                guard force || due else { continue }
                guard let remote = profile.remoteURL, let url = URL(string: remote) else { continue }
                do {
                    let (data, response) = try await downloadSubscription(from: url, profileID: profile.id)
                    try replaceProfile(profile, with: data, response: response)
                    markSubscriptionUpdated(profileID: profile.id, response: response)
                    updated += 1
                    if profile.id == activeProfileID { activeUpdated = true }
                } catch {
                    appendLog(level: "WARN", message: "自动更新“\(profile.name)”失败：\(error.localizedDescription)")
                }
            }
            if force { showToast("订阅更新完成 · \(updated) 个") }
            if activeUpdated { await startCore() }
        }
    }

    func markSubscriptionUpdated(profileID: String, response: HTTPURLResponse) {
        var preference = runtimeSettings.subscriptionPreferences[profileID] ?? SubscriptionPreference()
        preference.lastUpdated = Date()
        runtimeSettings.subscriptionPreferences[profileID] = preference
        if let raw = response.value(forHTTPHeaderField: "subscription-userinfo"), let usage = parseSubscriptionUsage(raw) {
            runtimeSettings.subscriptionUsage[profileID] = usage
        }
        try? settingsStore.save(runtimeSettings)
    }

    func parseSubscriptionUsage(_ raw: String) -> SubscriptionUsage? {
        var values: [String: Int64] = [:]
        for component in raw.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if pair.count == 2, let value = Int64(pair[1]) { values[pair[0].lowercased()] = value }
        }
        let used = (values["upload"] ?? 0) + (values["download"] ?? 0)
        let total = values["total"] ?? 0
        guard used > 0 || total > 0 || values["expire"] != nil else { return nil }
        let expiry = values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SubscriptionUsage(usedBytes: used, totalBytes: total, expiresAt: expiry)
    }

    func subscriptionName(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "profile-title")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let decoded = raw.removingPercentEncoding, !decoded.isEmpty { return String(decoded.prefix(80)) }
        return String(raw.prefix(80))
    }

    func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func refreshRuntime(force: Bool = false) async {
        guard coreState == .running, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        refreshCounter += 1
        do {
            try await refreshConnections()
            if force || refreshCounter % 3 == 0 { await refreshProxies() }
            if force || refreshCounter % 10 == 0 { try await refreshRulesAndConfig() }
            if force || refreshCounter % 10 == 0 {
                detectedCaptureMode = systemProxy.status(httpPort: httpPort, socksPort: socksPort, pacURL: repository.pacURL)
                if runtimeSettings.captureMode != .tun { isConnected = detectedCaptureMode != nil }
            }
            if runtimeSettings.automaticSubscriptionUpdates,
               Date().timeIntervalSince(lastSubscriptionCheck) > 900 {
                lastSubscriptionCheck = Date()
                updateAllSubscriptions(force: false)
            }
        } catch {
            if core.isRunning == false { coreState = .failed(error.localizedDescription) }
        }
    }

    func refreshConnections() async throws {
        let data = try await api.request("/connections")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AeroRuntimeError.invalidResponse }
        let uploadBytes = (root["uploadTotal"] as? NSNumber)?.doubleValue ?? 0
        let downloadBytes = (root["downloadTotal"] as? NSNumber)?.doubleValue ?? 0
        let now = Date()
        let elapsed = max(0.25, now.timeIntervalSince(lastTrafficDate))
        if lastUploadBytes > 0 {
            uploadRate = max(0, uploadBytes - lastUploadBytes) / elapsed / 1_048_576
            downloadRate = max(0, downloadBytes - lastDownloadBytes) / elapsed / 1_048_576
            pendingHistoryUpload += Int64(max(0, uploadBytes - lastUploadBytes))
            pendingHistoryDownload += Int64(max(0, downloadBytes - lastDownloadBytes))
        }
        lastUploadBytes = uploadBytes
        lastDownloadBytes = downloadBytes
        lastTrafficDate = now
        if refreshCounter % 6 == 0, pendingHistoryUpload > 0 || pendingHistoryDownload > 0 {
            if let history = try? trafficHistoryStore.record(uploadBytes: pendingHistoryUpload, downloadBytes: pendingHistoryDownload) {
                trafficHistory = history
                pendingHistoryUpload = 0
                pendingHistoryDownload = 0
            }
        }
        let today = TrafficHistoryStore.dayKey(Date())
        let storedToday = trafficHistory.first(where: { $0.day == today })
        totalUpload = Double((storedToday?.uploadBytes ?? 0) + pendingHistoryUpload) / 1_073_741_824
        totalDownload = Double((storedToday?.downloadBytes ?? 0) + pendingHistoryDownload) / 1_073_741_824
        activity.removeFirst()
        activity.append(min(1, downloadRate / 20))

        let rawConnections = root["connections"] as? [[String: Any]] ?? []
        connections = rawConnections.prefix(250).map { raw in
            let metadata = raw["metadata"] as? [String: Any] ?? [:]
            let host = (metadata["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (metadata["destinationIP"] as? String) ?? "未知目标"
            let processPath = (metadata["processPath"] as? String) ?? (metadata["process"] as? String) ?? "网络进程"
            let appName = URL(fileURLWithPath: processPath).deletingPathExtension().lastPathComponent
            let chains = raw["chains"] as? [String] ?? []
            let rule = raw["rule"] as? String ?? "MATCH"
            let rulePayload = (raw["rulePayload"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let matchedRule = rulePayload.map { "\(rule)(\($0))" } ?? rule
            return ConnectionItem(
                id: raw["id"] as? String ?? UUID().uuidString,
                app: appName.isEmpty ? "网络进程" : appName,
                symbol: symbol(for: appName),
                host: host,
                network: (metadata["network"] as? String ?? "TCP").uppercased(),
                upload: formatBytes((raw["upload"] as? NSNumber)?.int64Value ?? 0),
                download: formatBytes((raw["download"] as? NSNumber)?.int64Value ?? 0),
                rule: "\(matchedRule) → \(chains.first ?? "DIRECT")",
                status: .active
            )
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

    func refreshRulesAndConfig() async throws {
        let configData = try await api.request("/configs")
        if let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            let mixed = (config["mixed-port"] as? NSNumber)?.intValue ?? 0
            let web = (config["port"] as? NSNumber)?.intValue ?? 0
            let socks = (config["socks-port"] as? NSNumber)?.intValue ?? 0
            httpPort = mixed > 0 ? mixed : (web > 0 ? web : 7890)
            socksPort = mixed > 0 ? mixed : (socks > 0 ? socks : httpPort)
            if let apiMode = config["mode"] as? String, let parsed = ProxyMode(apiValue: apiMode) { mode = parsed }
        }
        let rulesData = try await api.request("/rules")
        if let root = try JSONSerialization.jsonObject(with: rulesData) as? [String: Any], let rawRules = root["rules"] as? [[String: Any]] {
            rules = rawRules.prefix(500).map { raw in
                let extra = raw["extra"] as? [String: Any]
                return RuleItem(
                    id: String((raw["index"] as? NSNumber)?.intValue ?? 0),
                    type: raw["type"] as? String ?? "MATCH",
                    payload: raw["payload"] as? String ?? "*",
                    policy: raw["proxy"] as? String ?? "DIRECT",
                    matches: (extra?["hitCount"] as? NSNumber)?.intValue ?? 0
                )
            }
        }
    }

    func appendCoreLog(_ line: String) {
        let lower = line.lowercased()
        let level = lower.contains("error") ? "ERROR" : lower.contains("warn") ? "WARN" : lower.contains("debug") ? "DEBUG" : "INFO"
        appendLog(level: level, message: line)
    }

    func appendLog(level: String, message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append(LogEntry(time: formatter.string(from: Date()), level: level, message: message))
        if logs.count > 1_000 { logs.removeFirst(logs.count - 1_000) }
    }

    func flag(for name: String) -> String {
        let lower = name.lowercased()
        let pairs = [("香港", "🇭🇰"), ("hong kong", "🇭🇰"), ("日本", "🇯🇵"), ("东京", "🇯🇵"), ("japan", "🇯🇵"), ("新加坡", "🇸🇬"), ("狮城", "🇸🇬"), ("singapore", "🇸🇬"), ("美国", "🇺🇸"), ("united states", "🇺🇸"), ("洛杉矶", "🇺🇸"), ("台湾", "🇹🇼"), ("taiwan", "🇹🇼"), ("英国", "🇬🇧"), ("伦敦", "🇬🇧"), ("德国", "🇩🇪"), ("韩国", "🇰🇷")]
        return pairs.first(where: { lower.contains($0.0) })?.1 ?? (name == "DIRECT" ? "🖥" : "🌐")
    }

    func symbol(for app: String) -> String {
        let lower = app.lowercased()
        if lower.contains("safari") { return "safari.fill" }
        if lower.contains("telegram") { return "paperplane.fill" }
        if lower.contains("music") { return "music.note" }
        return "app.fill"
    }

    func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    func validPort(_ port: Int, fallback: Int) -> Int {
        (1...65_535).contains(port) ? port : fallback
    }

    func runtimePortMatches(_ config: [String: Any], settings: RuntimeSettings) -> Bool {
        if settings.useMixedPort {
            return (config["mixed-port"] as? NSNumber)?.intValue == settings.mixedPort
        }
        return (config["port"] as? NSNumber)?.intValue == settings.httpPort &&
            (config["socks-port"] as? NSNumber)?.intValue == settings.socksPort
    }

    func beginEditingActiveYAML() {
        guard let profile = profiles.first(where: { $0.id == activeProfileID }) else { return }
        do {
            editingYAML = try String(contentsOf: repository.fileURL(for: profile), encoding: .utf8)
            showYAMLEditor = true
        } catch { presentError("读取 YAML 失败", error) }
    }

    func saveEditedYAML() {
        guard let profile = profiles.first(where: { $0.id == activeProfileID }),
              let coreURL = Bundle.main.url(forResource: runtimeSettings.coreChannel.resourceName, withExtension: nil) ?? Bundle.main.url(forResource: "mihomo", withExtension: nil) else { return }
        let temporary = repository.root.appendingPathComponent("edited-\(UUID().uuidString).yaml")
        do {
            try editingYAML.write(to: temporary, atomically: true, encoding: .utf8)
            try repository.validate(configURL: temporary, coreURL: coreURL)
            try repository.backup(profile)
            try editingYAML.write(to: repository.fileURL(for: profile), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: temporary)
            showYAMLEditor = false
            Task { await startCore() }
            showToast("YAML 校验通过并已保存")
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            presentError("YAML 校验失败", error)
        }
    }

    func openWebDashboard() {
        guard let url = URL(string: "https://metacubexd.pages.dev") else { return }
        NSWorkspace.shared.open(url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(controllerPort)\n\(api.secret)", forType: .string)
        showToast("控制器地址与密钥已复制")
    }

    func recordDiagnostic(_ message: String) {
        let url = repository.root.appendingPathComponent("last-start.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func presentError(_ title: String, _ error: Error) {
        let detail = String(error.localizedDescription.prefix(1_200))
        let diagnostic = detail.replacingOccurrences(of: "\n", with: " ")
        recordDiagnostic("subscription-error=\(diagnostic)")
        appendLog(level: "ERROR", message: "\(title)：\(detail)")
        alertMessage = "\(title)：\n\n\(detail)"
    }

    @objc private func applicationWillTerminate() {
        if pendingHistoryUpload > 0 || pendingHistoryDownload > 0 {
            _ = try? trafficHistoryStore.record(uploadBytes: pendingHistoryUpload, downloadBytes: pendingHistoryDownload)
            pendingHistoryUpload = 0
            pendingHistoryDownload = 0
        }
        if systemProxy.hasActiveSnapshot, (try? systemProxy.disable()) != nil {
            UserDefaults.standard.removeObject(forKey: "systemProxyAppliedPort")
        }
        coreState = .stopped
        core.stop()
    }

    func showToast(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}
