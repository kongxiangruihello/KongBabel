import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "晚上好", subtitle: model.coreState == .running ? "Mihomo 内核运行正常" : model.coreState.label) { StatusBadge() }
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        ConnectionHero().frame(maxWidth: .infinity)
                        TrafficCard().frame(maxWidth: .infinity)
                    }.frame(height: 270)
                    HStack(spacing: 16) {
                        QuickStat(icon: "arrow.up", label: "今日上传", value: String(format: "%.1f GB", model.totalUpload), tint: Theme.accent2)
                        QuickStat(icon: "arrow.down", label: "今日下载", value: String(format: "%.1f GB", model.totalDownload), tint: Theme.accent)
                        QuickStat(icon: "bolt.fill", label: "活动连接", value: "\(model.activeConnections.count)", tint: Theme.warning)
                        QuickStat(icon: "clock.fill", label: "运行时间", value: model.uptimeText, tint: Color.purple.opacity(0.9))
                    }
                    HStack(alignment: .top, spacing: 16) {
                        QuickActions().frame(maxWidth: .infinity)
                        RecentConnections().frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 30).padding(.bottom, 28)
            }
        }
    }
}

struct ConnectionHero: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            HStack { SectionTitle(title: "系统代理", detail: model.isConnected ? "保护中" : "已暂停") }
            Spacer()
            Button { model.toggleConnection() } label: {
                ZStack {
                    Circle().fill(model.isConnected ? Theme.accent.opacity(0.14) : Theme.panelStrong).frame(width: 112, height: 112)
                    Circle().stroke(model.isConnected ? Theme.accent.opacity(0.4) : Theme.stroke, lineWidth: 1).frame(width: 90, height: 90)
                    Image(systemName: model.isConnected ? "power" : "power").font(.system(size: 34, weight: .medium)).foregroundStyle(model.isConnected ? Theme.accent : Theme.secondary)
                }
            }.buttonStyle(.plain)
            VStack(spacing: 4) {
                Text(model.isConnected ? "连接已开启" : "点击以连接").font(.system(size: 15, weight: .bold))
                Text(model.isConnected ? "流量正在由 KongBabel 安全转发" : "当前使用系统网络设置").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }.card()
    }
}

struct TrafficCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "实时速率", detail: "最近 30 秒")
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(model.rateParts(model.downloadRate).value).font(.system(size: 34, weight: .bold, design: .rounded))
                Text(model.rateParts(model.downloadRate).unit).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Label(model.rateText(model.uploadRate), systemImage: "arrow.up").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent2)
                    Text("上传").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            ActivityChart(values: model.activity).frame(height: 115)
        }.card()
    }
}

struct ActivityChart: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Path { p in
                    for i in 0..<4 {
                        let y = geo.size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }.stroke(Theme.grid, style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                let points = values.enumerated().map { index, value in
                    CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1)), y: geo.size.height * (1 - CGFloat(value) * 0.88))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height)); p.addLine(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                    if let last = points.last { p.addLine(to: CGPoint(x: last.x, y: geo.size.height)) }
                    p.closeSubpath()
                }.fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }; p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct QuickStat: View {
    let icon: String, label: String, value: String, tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(tint).frame(width: 34, height: 34).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 10)).foregroundStyle(Theme.secondary); Text(value).font(.system(size: 14, weight: .bold)) }
            Spacer(minLength: 0)
        }.card(14)
    }
}

struct QuickActions: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            SectionTitle(title: "快速控制")
            ModePicker(selection: model.modeBinding)
            HStack(spacing: 10) {
                ActionTile(icon: "scope", title: "节点测速", subtitle: model.latencyTesting ? "测速中…" : "全部节点", tint: Theme.accent) { model.testLatency() }
                ActionTile(icon: "arrow.clockwise", title: "更新配置", subtitle: "当前订阅", tint: Theme.accent2) {
                    if let profile = model.profiles.first(where: { $0.id == model.activeProfileID }) { model.updateProfile(profile) }
                }
                ActionTile(icon: "hammer.fill", title: "诊断网络", subtitle: "检查内核与接管", tint: Theme.warning) { model.runNetworkDiagnostics() }
            }
        }.card()
    }
}

struct ActionTile: View {
    let icon: String, title: String, subtitle: String, tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 30, height: 30).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 11, weight: .semibold)); Text(subtitle).font(.system(size: 9)).foregroundStyle(Theme.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Theme.surfaceMuted).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.stroke))
        }.buttonStyle(.plain)
    }
}

struct RecentConnections: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 13) {
            SectionTitle(title: "最近连接", detail: "查看全部")
            ForEach(model.connections.prefix(3)) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 30, height: 30).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) { Text(item.host).font(.system(size: 11, weight: .medium)).lineLimit(1); Text(item.rule).font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                    Spacer(); Text(item.download).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
        }.card()
    }
}

// MARK: - Proxies
