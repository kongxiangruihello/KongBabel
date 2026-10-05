import Foundation
import Network

// MARK: - Network issues

/// 需要弹窗提醒用户的网络故障类型。
enum NetworkIssue: Equatable {
    /// macOS 报告当前没有任何可用的网络接口（Wi‑Fi / 有线均未连接）。
    case offline
    /// 已连接 Wi‑Fi 或有线，但不经代理也无法访问互联网（如校园网/酒店网络未登录、路由器断网）。
    case internetUnreachable
    /// 本机网络正常，但经 Mihomo 代理无法访问外网（节点失效、订阅过期等）。
    case proxyUnreachable
    /// Mihomo 内核异常退出或启动失败。
    case coreStopped

    var title: String {
        switch self {
        case .offline: return "网络未连接"
        case .internetUnreachable: return "无法访问互联网"
        case .proxyUnreachable: return "代理网络连接失败"
        case .coreStopped: return "Mihomo 内核未运行"
        }
    }

    var logMessage: String {
        switch self {
        case .offline: return "网络检测：Mac 未连接到任何网络"
        case .internetUnreachable: return "网络检测：已连接网络，但无法访问互联网"
        case .proxyUnreachable: return "网络检测：经代理访问外网连续失败"
        case .coreStopped: return "网络检测：Mihomo 内核未运行"
        }
    }
}

// MARK: - Connectivity probe

/// 真实访问探测：分别经 Mihomo 本地代理端口、以及绕过代理直连，请求一个轻量的 204 地址。
enum ConnectivityProbe {
    /// 经代理探测的目标（均为常见“需走代理”的域名，避免被直连规则掩盖节点故障）。
    static let proxyTargets = [
        "https://www.gstatic.com/generate_204",
        "https://www.google.com/generate_204"
    ]
    /// 直连探测的目标（国内可直接访问，用于区分“本机网络不通”和“节点不通”）。
    static let directTargets = [
        "http://captive.apple.com/hotspot-detect.html",
        "https://www.baidu.com"
    ]

    static func checkThroughProxy(port: Int, timeout: TimeInterval = 8) async -> Bool {
        let proxy: [AnyHashable: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port
        ]
        return await check(targets: proxyTargets, proxy: proxy, timeout: timeout)
    }

    static func checkDirect(timeout: TimeInterval = 6) async -> Bool {
        // 空字典表示显式不使用任何代理，绕过系统代理设置。
        await check(targets: directTargets, proxy: [:], timeout: timeout)
    }

    private static func check(targets: [String], proxy: [AnyHashable: Any], timeout: TimeInterval) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = proxy
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for target in targets {
            guard let url = URL(string: target) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Kong-Connectivity-Check", forHTTPHeaderField: "User-Agent")
            if let result = try? await session.data(for: request),
               let http = result.1 as? HTTPURLResponse,
               (200..<400).contains(http.statusCode) {
                return true
            }
        }
        return false
    }
}

// MARK: - Watchdog

/// 持续监测网络：NWPathMonitor 监听网络接口变化，定时器驱动经代理的真实访问探测。
/// 每次故障只提醒一次，恢复后自动复位。
@MainActor
final class NetworkWatchdog {
    struct Context {
        var coreState: CoreState
        /// Kong 是否正在接管系统流量（系统代理 / PAC / TUN）。
        var isCapturing: Bool
        /// 当前是否为直连模式（直连模式下不检测代理）。
        var isDirectMode: Bool
        var proxyPort: Int
    }

    var onIssue: (@MainActor (NetworkIssue) -> Void)?
    var onRecover: (@MainActor (NetworkIssue) -> Void)?
    var context: (@MainActor () -> Context)?
    var isEnabled = true {
        didSet { if !isEnabled { currentIssue = nil; proxyFailures = 0 } }
    }

    private(set) var currentIssue: NetworkIssue?
    private let monitor = NWPathMonitor()
    private var pathSatisfied = true
    private var proxyFailures = 0
    private var lastProbe = Date.distantPast
    private var probeInFlight = false
    /// 自动切换节点后允许对同一故障再次上报（新节点仍不可用时需要再次提醒）。
    private var reReportAllowed = false

    /// 网络正常时的探测间隔；出现失败后缩短间隔以尽快确认。
    private let normalInterval: TimeInterval = 30
    private let retryInterval: TimeInterval = 8
    /// 连续失败多少次才判定为故障，避免偶发抖动误报。
    private let failureThreshold = 2

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.kong.network-watchdog"))
    }

    func stop() {
        monitor.cancel()
    }

    /// 由 AppModel 的刷新定时器调用。
    func tick() {
        guard isEnabled, let context = context?() else { return }

        // 1. 内核状态
        if case .failed = context.coreState {
            report(.coreStopped)
            return
        }
        if context.coreState == .running, currentIssue == .coreStopped {
            resolve()
        }

        // 2. 经代理的真实访问探测：仅在接管流量、非直连模式、网络接口可用时进行
        guard pathSatisfied else { return }
        guard context.coreState == .running, context.isCapturing, !context.isDirectMode else {
            if currentIssue == .proxyUnreachable || currentIssue == .internetUnreachable { resolve() }
            proxyFailures = 0
            return
        }
        guard !probeInFlight else { return }
        let interval = proxyFailures > 0 ? retryInterval : normalInterval
        guard Date().timeIntervalSince(lastProbe) >= interval else { return }
        lastProbe = Date()
        probeInFlight = true
        let port = context.proxyPort
        Task { @MainActor [weak self] in
            let proxyOK = await ConnectivityProbe.checkThroughProxy(port: port)
            var directOK = true
            if !proxyOK { directOK = await ConnectivityProbe.checkDirect() }
            self?.handleProbe(proxyOK: proxyOK, directOK: directOK)
        }
    }

    /// 用户切换节点、配置或重新开启代理后，立即重新检测。
    func recheckSoon() {
        lastProbe = .distantPast
        proxyFailures = 0
    }

    /// 已采取补救措施（如自动切换节点）：立即重新检测，若仍失败则再次上报同一故障。
    func retryAfterRemedy() {
        reReportAllowed = true
        recheckSoon()
    }

    private func handleProbe(proxyOK: Bool, directOK: Bool) {
        probeInFlight = false
        guard isEnabled, pathSatisfied else { return }
        if proxyOK {
            proxyFailures = 0
            if currentIssue == .proxyUnreachable || currentIssue == .internetUnreachable { resolve() }
            return
        }
        proxyFailures += 1
        guard proxyFailures >= failureThreshold else { return }
        report(directOK ? .proxyUnreachable : .internetUnreachable)
    }

    private func pathChanged(satisfied: Bool) {
        pathSatisfied = satisfied
        if satisfied {
            recheckSoon()
            if currentIssue == .offline { resolve() }
            return
        }
        // Wi‑Fi 切换时会短暂断开，延迟 4 秒确认后再提醒
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !self.pathSatisfied else { return }
            self.report(.offline)
        }
    }

    private func report(_ issue: NetworkIssue) {
        guard isEnabled, currentIssue != issue || reReportAllowed else { return }
        reReportAllowed = false
        currentIssue = issue
        onIssue?(issue)
    }

    private func resolve() {
        guard let issue = currentIssue else { return }
        currentIssue = nil
        reReportAllowed = false
        proxyFailures = 0
        onRecover?(issue)
    }
}

// MARK: - Menu bar notice

enum NetworkNoticeAction: Hashable {
    case openNetworkSettings
    case testAndSwitch
    case diagnose
    case restartCore
    case showLogs
    case updateSubscription(profileID: String)
    case openProfiles
    case downloadUpdate(url: String)
    case skipVersion(String)

    var title: String {
        switch self {
        case .openNetworkSettings: return "打开网络设置"
        case .testAndSwitch: return "测速并切换节点"
        case .diagnose: return "诊断网络"
        case .restartCore: return "重启内核"
        case .showLogs: return "查看日志"
        case .updateSubscription: return "更新订阅"
        case .openProfiles: return "查看配置"
        case .downloadUpdate: return "前往下载"
        case .skipVersion: return "跳过此版本"
        }
    }
}

/// 菜单栏图标下方弹出的提示（网络故障、恢复、自动切换、订阅提醒等）。
struct NetworkNotice: Identifiable, Equatable {
    enum Style: Equatable {
        case failure   // 红色：需要处理的故障
        case warning   // 橙色：需要注意
        case recovery  // 绿色：已恢复
        case info      // 蓝色：提示性消息
        case update    // 蓝色：发现新版本（保持显示）
    }

    let id = UUID()
    /// 对应的网络故障；订阅提醒等与网络故障无关的提示为 nil。
    let issue: NetworkIssue?
    let style: Style
    let title: String
    let detail: String
    let symbol: String
    let actions: [NetworkNoticeAction]

    /// 自动收起的秒数；nil 表示保持显示直到用户处理。
    var autoDismissAfter: TimeInterval? {
        switch style {
        case .recovery: return 4
        case .info: return 6
        case .failure, .warning, .update: return nil
        }
    }

    static func failure(_ issue: NetworkIssue, detail: String) -> NetworkNotice {
        let actions: [NetworkNoticeAction]
        let symbol: String
        switch issue {
        case .offline: actions = [.openNetworkSettings]; symbol = "wifi.slash"
        case .internetUnreachable: actions = [.openNetworkSettings]; symbol = "wifi.exclamationmark"
        case .proxyUnreachable: actions = [.testAndSwitch, .diagnose]; symbol = "exclamationmark.triangle.fill"
        case .coreStopped: actions = [.restartCore, .showLogs]; symbol = "xmark.octagon.fill"
        }
        return NetworkNotice(issue: issue, style: issue == .proxyUnreachable ? .warning : .failure,
                             title: issue.title, detail: detail, symbol: symbol, actions: actions)
    }

    static func recovery(_ issue: NetworkIssue, title: String, detail: String) -> NetworkNotice {
        NetworkNotice(issue: issue, style: .recovery, title: title, detail: detail, symbol: "checkmark.circle.fill", actions: [])
    }

    static func info(title: String, detail: String, symbol: String = "arrow.triangle.2.circlepath.circle.fill") -> NetworkNotice {
        NetworkNotice(issue: nil, style: .info, title: title, detail: detail, symbol: symbol, actions: [])
    }
}
