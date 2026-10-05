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
    /// 正在单独测速的节点组
    @Published var testingGroups: Set<String> = []
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
    /// 自动切换时在延迟相近的节点中优先选低倍率
    @Published var preferLowMultiplier = UserDefaults.standard.object(forKey: "preferLowMultiplier") as? Bool ?? true
    /// 自动切换只选倍率不超过此值的节点；0 表示不限
    @Published var maxAutoSwitchMultiplier = UserDefaults.standard.object(forKey: "maxAutoSwitchMultiplier") as? Double ?? 0
    @Published var nodeSortOrder = UserDefaults.standard.string(forKey: "nodeSortOrder") ?? "default"
    /// 后台定时测速间隔（分钟）；0 表示关闭
    @Published var backgroundTestInterval = UserDefaults.standard.object(forKey: "backgroundTestInterval") as? Int ?? 30
    @Published var backgroundTesting = false
    @Published var chargedTraffic: [ChargedTrafficDay]
    @Published var wifiAutoEnabled = UserDefaults.standard.object(forKey: "wifiAutoEnabled") as? Bool ?? false
    /// Wi‑Fi 名称 → "enable"（连上时开启代理）或 "disable"（连上时关闭代理）
    @Published var wifiRules = UserDefaults.standard.dictionary(forKey: "wifiRules") as? [String: String] ?? [:]
    @Published var currentSSID: String?
    @Published var wifiNeedsPermission = false

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
    let chargedTrafficStore: ChargedTrafficStore
    let wifiMonitor = WiFiMonitor()
    var lastBackgroundTest = Date.distantPast
    var connectionByteCache: [String: Int64] = [:]
    var pendingChargedActual: Int64 = 0
    var pendingChargedBytes: Int64 = 0
    var lastSSIDCheck = Date.distantPast
    var lastHandledSSID: String?
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
        let chargedTrafficStore = ChargedTrafficStore(root: repository.root)
        self.chargedTrafficStore = chargedTrafficStore
        self.chargedTraffic = chargedTrafficStore.load()
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
                self?.checkBackgroundTestIfNeeded()
                self?.checkWiFiIfNeeded()
            }
        }
        configureNetworkWatchdog()
        configureGlobalHotKeys()
        configureWiFiMonitor()
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
        if refreshCounter % 6 == 0 { flushChargedTraffic() }
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
        accountChargedTraffic(rawConnections)
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
        flushChargedTraffic()
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

    /// 操作提示统一显示在菜单栏图标下方，与网络状态提示同一风格；
    /// 正在显示需要处理的故障、订阅或更新提醒时不覆盖它们
    func showToast(_ message: String) {
        if let current = networkNotice, [NetworkNotice.Style.failure, .warning, .update].contains(current.style) {
            appendLog(level: "INFO", message: message)
            return
        }
        networkNotice = .brief(message)
    }
}
