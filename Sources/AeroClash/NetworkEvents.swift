import Foundation

/// 一条网络事件：断网、恢复、自动切换节点、延迟过高、订阅提醒等。
struct NetworkEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case offline
        case internetUnreachable
        case proxyUnreachable
        case coreStopped
        case recovered
        case autoSwitch
        case highLatency
        case subscription

        /// 是否属于“网络故障”（用于统计）
        var isFailure: Bool {
            switch self {
            case .offline, .internetUnreachable, .proxyUnreachable, .coreStopped: return true
            default: return false
            }
        }

        var symbol: String {
            switch self {
            case .offline: return "wifi.slash"
            case .internetUnreachable: return "wifi.exclamationmark"
            case .proxyUnreachable: return "exclamationmark.triangle.fill"
            case .coreStopped: return "xmark.octagon.fill"
            case .recovered: return "checkmark.circle.fill"
            case .autoSwitch: return "arrow.triangle.2.circlepath.circle.fill"
            case .highLatency: return "tortoise.fill"
            case .subscription: return "calendar.badge.clock"
            }
        }

        init(issue: NetworkIssue) {
            switch issue {
            case .offline: self = .offline
            case .internetUnreachable: self = .internetUnreachable
            case .proxyUnreachable: self = .proxyUnreachable
            case .coreStopped: self = .coreStopped
            }
        }
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    /// 故障持续时间（仅“已恢复”事件有）
    var duration: TimeInterval?

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        if total < 3_600 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total / 3_600) 小时 \((total % 3_600) / 60) 分"
    }
}

/// 网络事件持久化：保存在应用支持目录的 network-events.json，最多保留 500 条。
struct NetworkEventStore {
    static let limit = 500
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("network-events.json")
    }

    func load() -> [NetworkEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NetworkEvent].self, from: data)) ?? []
    }

    func save(_ events: [NetworkEvent]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(events.prefix(Self.limit))) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
