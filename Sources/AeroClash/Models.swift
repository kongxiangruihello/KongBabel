import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case proxies = "代理"
    case connections = "连接"
    case rules = "规则"
    case profiles = "配置"
    case logs = "日志"
    case events = "网络事件"
    case settings = "设置"
    case developer = "开发者"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .proxies: return "point.3.connected.trianglepath.dotted"
        case .connections: return "arrow.triangle.branch"
        case .rules: return "list.bullet.rectangle.portrait"
        case .profiles: return "doc.on.doc.fill"
        case .logs: return "terminal.fill"
        case .events: return "waveform.path.ecg"
        case .settings: return "gearshape.fill"
        case .developer: return "person.crop.circle.fill"
        }
    }
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case rule = "规则"
    case global = "全局"
    case direct = "直连"
    var id: String { rawValue }
    var apiValue: String {
        switch self {
        case .rule: return "rule"
        case .global: return "global"
        case .direct: return "direct"
        }
    }

    init?(apiValue: String) {
        switch apiValue.lowercased() {
        case "rule": self = .rule
        case "global": self = .global
        case "direct": self = .direct
        default: return nil
        }
    }
}

struct ProxyNode: Identifiable, Hashable {
    let id: String
    let name: String
    let city: String
    let countryCode: String
    let latency: Int
    let load: Double
    let type: String
    let favorite: Bool

    static let placeholder = ProxyNode(id: "DIRECT", name: "DIRECT", city: "等待内核", countryCode: "🖥", latency: 0, load: 0, type: "Direct", favorite: false)

    static let sample: [ProxyNode] = [
        .init(id: "auto", name: "自动选择", city: "智能路由", countryCode: "⚡️", latency: 42, load: 0.31, type: "URL-Test", favorite: true),
        .init(id: "sg-01", name: "狮城 · 01", city: "Singapore", countryCode: "🇸🇬", latency: 58, load: 0.42, type: "VLESS", favorite: true),
        .init(id: "jp-02", name: "东京 · 02", city: "Tokyo", countryCode: "🇯🇵", latency: 76, load: 0.61, type: "Hysteria2", favorite: true),
        .init(id: "hk-03", name: "香港 · 03", city: "Hong Kong", countryCode: "🇭🇰", latency: 84, load: 0.54, type: "Trojan", favorite: false),
        .init(id: "us-01", name: "洛杉矶 · 01", city: "Los Angeles", countryCode: "🇺🇸", latency: 168, load: 0.72, type: "VLESS", favorite: false),
        .init(id: "de-01", name: "法兰克福 · 01", city: "Frankfurt", countryCode: "🇩🇪", latency: 212, load: 0.36, type: "Shadowsocks", favorite: false),
        .init(id: "uk-01", name: "伦敦 · 01", city: "London", countryCode: "🇬🇧", latency: 238, load: 0.83, type: "Trojan", favorite: false)
    ]
}

struct ProxyGroup: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let now: String
    let members: [String]
}

enum ConnectionStatus { case active, idle }

struct ConnectionItem: Identifiable {
    let id: String
    let app: String
    let symbol: String
    let host: String
    let network: String
    let upload: String
    let download: String
    let rule: String
    let status: ConnectionStatus

    static let sample: [ConnectionItem] = [
        .init(id: "sample-1", app: "Safari", symbol: "safari.fill", host: "www.apple.com", network: "TCP", upload: "24 KB", download: "1.8 MB", rule: "Apple → DIRECT", status: .active)
    ]
}

struct RuleItem: Identifiable {
    let id: String
    let type: String
    let payload: String
    let policy: String
    let matches: Int

    static let sample: [RuleItem] = [
        .init(id: "0", type: "MATCH", payload: "*", policy: "DIRECT", matches: 0)
    ]
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: String
    let level: String
    let message: String

    static let sample: [LogEntry] = [
        .init(time: "23:41:28", level: "INFO", message: "[TCP] 127.0.0.1:52182 → github.com:443 match DomainKeyword(github) using 节点选择[狮城 · 01]"),
        .init(time: "23:41:26", level: "INFO", message: "[UDP] 127.0.0.1:59214 → gateway.icloud.com:443 match DomainSuffix(apple.com) using DIRECT"),
        .init(time: "23:41:24", level: "DEBUG", message: "DNS response cache hit: api.telegram.org → 149.154.167.220"),
        .init(time: "23:41:18", level: "INFO", message: "[TCP] 127.0.0.1:52160 → audio-ssl.itunes.apple.com:443 using 媒体服务[狮城 · 01]"),
        .init(time: "23:41:04", level: "WARN", message: "Health check: 洛杉矶 · 01 latency increased to 168 ms"),
        .init(time: "23:40:58", level: "INFO", message: "Profile “默认配置” updated successfully")
    ]
}

struct Profile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let source: String
    let updated: String
    let size: String
    let fileName: String
    let remoteURL: String?
    let format: String?
    let payloadFileName: String?

    static let sample: [Profile] = [
        .init(id: "default", name: "默认直连配置", source: "内置安全配置", updated: "随应用提供", size: "1 KB", fileName: "default.yaml", remoteURL: nil, format: "builtin", payloadFileName: nil)
    ]
}

// MARK: - Theme
