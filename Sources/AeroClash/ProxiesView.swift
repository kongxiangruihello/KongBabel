import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct ProxiesView: View {
    @EnvironmentObject var model: AppModel
    var filtered: [ProxyNode] { model.sortedNodes(model.nodes.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || $0.city.localizedCaseInsensitiveContains(model.searchText) }) }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "代理", subtitle: "选择流量出口与策略组") {
                HStack(spacing: 10) {
                    PillButton(title: model.latencyTesting ? "测速中" : "全部测速", icon: "scope", action: model.testLatency)
                    StatusBadge()
                }
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("策略组").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                    ForEach(model.proxyGroups) { item in
                        Button { model.selectProxyGroup(item.name) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.type == "Selector" ? "point.3.filled.connected.trianglepath.dotted" : "bolt.fill").frame(width: 18).foregroundStyle(model.selectedProxyGroup == item.name ? Theme.accent : Theme.secondary)
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(); Text("\(item.members.count)").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                            }.padding(.horizontal, 11).frame(height: 38).background(model.selectedProxyGroup == item.name ? Theme.panelStrong : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    if model.proxyGroups.isEmpty {
                        Text(model.coreState.label).font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(12)
                    }
                    Spacer()
                    ModePicker(selection: model.modeBinding).padding(10)
                }.frame(width: 190).padding(.leading, 18).padding(.bottom, 20)
                Divider().overlay(Theme.stroke)
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(model.selectedProxyGroup).font(.system(size: 18, weight: .bold)); Text("当前：\(model.selectedNode.name) · 右键节点可设为常用或跳过").font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1) }
                        Spacer()
                        Picker("排序", selection: Binding(get: { model.nodeSortOrder }, set: model.setNodeSortOrder)) {
                            Text("默认顺序").tag("default")
                            Text("按倍率").tag("multiplier")
                            Text("按延迟").tag("latency")
                        }.labelsHidden().frame(width: 104)
                        SearchField(text: $model.searchText, placeholder: "搜索节点").frame(width: 210)
                    }.padding(.horizontal, 22).padding(.bottom, 14)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { node in ProxyNodeCard(node: node) }
                        }.padding(.horizontal, 22).padding(.bottom, 24)
                    }
                }
            }
        }
    }
}

struct ProxyNodeCard: View {
    @EnvironmentObject var model: AppModel
    let node: ProxyNode
    var selected: Bool { model.selectedNodeID == node.id }
    var latencyColor: Color { node.latency < 90 ? Theme.accent : node.latency < 180 ? Theme.warning : Theme.danger }
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { model.selectNode(node) }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(node.countryCode).font(.system(size: 26)); Spacer()
                    if let rate = model.multiplierLabel(for: node.name) {
                        Text(rate)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent2.opacity(0.12))
                            .foregroundStyle(Theme.accent2)
                            .clipShape(Capsule())
                            .help("流量倍率 \(rate)：使用 1 GB 流量扣除 \(rate.dropFirst()) GB 订阅流量")
                    }
                    if model.isFavorite(node.name) { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.warning).help("常用节点：自动切换时优先选择") }
                    if model.isExcluded(node.name) { Image(systemName: "nosign").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).help("自动切换不会切到这里") }
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                }
                VStack(alignment: .leading, spacing: 3) { Text(node.name).font(.system(size: 14, weight: .bold)).lineLimit(1).truncationMode(.middle); Text("\(node.city) · \(node.type)").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.help(node.name)
                HStack {
                    Circle().fill(latencyColor).frame(width: 6, height: 6); Text("\(node.latency) ms").font(.system(size: 10, weight: .semibold)).foregroundStyle(latencyColor)
                    Spacer(); Text("负载 \(Int(node.load * 100))%").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) { Capsule().fill(Theme.panelStrong); Capsule().fill(latencyColor.opacity(0.75)).frame(width: geo.size.width * node.load) }
                }.frame(height: 3)
                Text((model.nodeStats[node.name] ?? NodeStats()).compactSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .help((model.nodeStats[node.name] ?? NodeStats()).fullSummary)
            }.padding(15).background(selected ? Theme.accent.opacity(0.085) : Theme.panel).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.accent.opacity(0.65) : Theme.stroke, lineWidth: 1))
            .opacity(model.isExcluded(node.name) ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(model.isFavorite(node.name) ? "取消常用" : "设为常用（自动切换时优先）") { model.toggleFavorite(node.name) }
            Button(model.isExcluded(node.name) ? "允许自动切换到此节点" : "自动切换时跳过此节点") { model.toggleExcluded(node.name) }
        }
    }
}

// MARK: - Connections
