import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct NetworkEventsView: View {
    @EnvironmentObject var model: AppModel

    private var recentWeek: [NetworkEvent] {
        let since = Date().addingTimeInterval(-7 * 86_400)
        return model.networkEvents.filter { $0.date >= since }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "网络事件", subtitle: "断网、节点切换与订阅提醒的记录") {
                HStack(spacing: 10) {
                    PillButton(title: "复制", icon: "doc.on.doc") { model.copyNetworkEvents() }
                    PillButton(title: "清空", icon: "trash") { model.clearNetworkEvents() }
                }
            }
            HStack(spacing: 12) {
                let failures = recentWeek.filter { $0.kind.isFailure }.count
                let switches = recentWeek.filter { $0.kind == .autoSwitch }.count
                let downtime = recentWeek.compactMap(\.duration).reduce(0, +)
                MetricCard(label: "近 7 天网络故障", value: "\(failures) 次", detail: "断网、无法上网、节点不通、内核停止", icon: "exclamationmark.triangle.fill", tint: Theme.danger)
                MetricCard(label: "近 7 天切换节点", value: "\(switches) 次", detail: "自动切换与快捷键切换", icon: "arrow.triangle.2.circlepath", tint: Theme.accent2)
                MetricCard(label: "近 7 天故障时长", value: downtime > 0 ? NetworkEvent.durationText(downtime) : "0 秒", detail: "从发现故障到恢复", icon: "clock.fill", tint: Theme.warning)
            }
            .padding(.horizontal, 30).padding(.bottom, 14)
            if model.networkEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.system(size: 28)).foregroundStyle(Theme.accent)
                    Text("暂无网络事件").font(.system(size: 13, weight: .semibold))
                    Text("断网、恢复、自动切换节点和订阅提醒都会记录在这里").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.networkEvents) { event in
                            NetworkEventRow(event: event)
                        }
                    }
                }
                .card(0).padding(.horizontal, 30).padding(.bottom, 26)
            }
        }
    }
}

struct NetworkEventRow: View {
    let event: NetworkEvent

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private var tint: Color {
        switch event.kind {
        case .offline, .internetUnreachable, .coreStopped: return Theme.danger
        case .proxyUnreachable, .highLatency, .subscription: return Theme.warning
        case .recovered: return Theme.accent
        case .autoSwitch: return Theme.accent2
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let duration = event.duration {
                        Text(NetworkEvent.durationText(duration))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tint.opacity(0.12)).foregroundStyle(tint).clipShape(Capsule())
                    }
                }
                Text(event.detail).font(.system(size: 10)).foregroundStyle(Theme.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(Self.formatter.string(from: event.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
    }
}

// MARK: - Settings
