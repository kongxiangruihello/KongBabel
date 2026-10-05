import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    @StoredState private var query = ""
    @StoredState private var onlyActive = true
    var items: [ConnectionItem] { model.connections.filter { (!onlyActive || $0.status == .active) && (query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.app.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "连接", subtitle: "检查当前网络会话与流量 · 右键连接可设置网站或应用走代理/直连") {
                HStack(spacing: 10) { PillButton(title: "关闭全部", icon: "xmark.circle", action: model.closeAllConnections); StatusBadge() }
            }
            HStack(spacing: 12) {
                MetricCard(label: "活动连接", value: "\(model.activeConnections.count)", detail: "Mihomo 实时会话", icon: "bolt.horizontal.fill", tint: Theme.accent)
                MetricCard(label: "上传速率", value: model.rateText(model.uploadRate), detail: String(format: "今日 %.2f GB", model.totalUpload), icon: "arrow.up", tint: Theme.accent2)
                MetricCard(label: "下载速率", value: model.rateText(model.downloadRate), detail: String(format: "今日 %.2f GB", model.totalDownload), icon: "arrow.down", tint: Theme.warning)
            }.padding(.horizontal, 30).padding(.bottom, 16)
            VStack(spacing: 0) {
                HStack { SearchField(text: $query, placeholder: "搜索域名或应用").frame(width: 260); Toggle("仅活动", isOn: $onlyActive).toggleStyle(.switch).controlSize(.small).font(.system(size: 11)); Spacer(); Text("按下载流量排序").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.padding(14)
                Divider().overlay(Theme.stroke)
                HStack { Text("应用 / 目标").frame(maxWidth: .infinity, alignment: .leading); Text("网络").frame(width: 70); Text("上传").frame(width: 78, alignment: .trailing); Text("下载").frame(width: 78, alignment: .trailing); Text("规则 / 出站").frame(width: 220, alignment: .trailing); Color.clear.frame(width: 24) }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 15).frame(height: 34)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack {
                                HStack(spacing: 10) { Image(systemName: item.symbol).frame(width: 28, height: 28).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 2) { Text(item.host).font(.system(size: 11, weight: .medium)); Text(item.app).font(.system(size: 9)).foregroundStyle(Theme.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.network).frame(width: 70)
                                Text(item.upload).frame(width: 78, alignment: .trailing)
                                Text(item.download).frame(width: 78, alignment: .trailing)
                                Text(item.rule).lineLimit(1).help(item.rule).foregroundStyle(Theme.accent).frame(width: 220, alignment: .trailing)
                                Button { model.closeConnection(id: item.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
                                }.buttonStyle(.plain).frame(width: 24).help("关闭此连接")
                            }.font(.system(size: 10)).padding(.horizontal, 15).frame(height: 52).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                            .contentShape(Rectangle())
                            .contextMenu { ConnectionRuleMenu(item: item) }
                        }
                    }
                }
            }.card(0).padding(.horizontal, 30).padding(.bottom, 26)
        }
    }
}

/// 连接右键菜单：一键把网站或应用设为始终走代理/直连
struct ConnectionRuleMenu: View {
    @EnvironmentObject var model: AppModel
    let item: ConnectionItem

    private var siteRule: (type: String, payload: String, label: String)? {
        if let domain = AppModel.ruleDomain(for: item.host) {
            return ("DOMAIN-SUFFIX", domain, "网站 \(domain)")
        }
        if AppModel.isIPAddress(item.host) {
            let cidr = item.host.contains(":") ? "\(item.host)/128" : "\(item.host)/32"
            return (item.host.contains(":") ? "IP-CIDR6" : "IP-CIDR", cidr, "地址 \(item.host)")
        }
        return nil
    }

    private var appRule: (type: String, payload: String, label: String)? {
        guard item.app != "网络进程", !item.app.isEmpty else { return nil }
        return ("PROCESS-NAME", item.app, "应用 \(item.app)")
    }

    var body: some View {
        if let rule = siteRule { ruleSection(rule) }
        if let rule = appRule { ruleSection(rule) }
        Divider()
        Button("复制目标地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.host, forType: .string)
        }
        Button("关闭此连接") { model.closeConnection(id: item.id) }
    }

    @ViewBuilder
    private func ruleSection(_ rule: (type: String, payload: String, label: String)) -> some View {
        let current = model.quickRuleTarget(type: rule.type, payload: rule.payload)
        Section(rule.label) {
            Button(current != nil && current != "DIRECT" ? "✓ 始终走代理" : "始终走代理") {
                model.addQuickRule(type: rule.type, payload: rule.payload, policy: .proxy)
            }
            Button(current == "DIRECT" ? "✓ 始终直连" : "始终直连") {
                model.addQuickRule(type: rule.type, payload: rule.payload, policy: .direct)
            }
            if current != nil {
                Button("删除这条规则") { model.removeQuickRules(type: rule.type, payload: rule.payload) }
            }
        }
    }
}
