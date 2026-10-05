import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    @StoredState private var query = ""
    private var filteredRules: [RuleItem] {
        model.rules.filter {
            query.isEmpty ||
                $0.type.localizedCaseInsensitiveContains(query) ||
                $0.payload.localizedCaseInsensitiveContains(query) ||
                $0.policy.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "规则", subtitle: "查看规则集与命中策略") { PillButton(title: "更新规则集", icon: "arrow.clockwise", action: model.updateRuleProviders) }
            HStack { SearchField(text: $query, placeholder: "搜索规则").frame(width: 280); Spacer(); Text("已载入 \(model.rules.count) 条规则").font(.system(size: 11)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 30).padding(.bottom, 14)
            MyRulesSection().padding(.horizontal, 30).padding(.bottom, 14)
            VStack(spacing: 0) {
                HStack { Text("类型").frame(width: 130, alignment: .leading); Text("匹配内容").frame(maxWidth: .infinity, alignment: .leading); Text("策略").frame(width: 140, alignment: .leading); Text("命中次数").frame(width: 90, alignment: .trailing) }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).frame(height: 38).background(Theme.surfaceMuted)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRules) { rule in
                            HStack {
                                Text(rule.type).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.accent2).frame(width: 130, alignment: .leading)
                                Text(rule.payload).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(rule.payload).frame(maxWidth: .infinity, alignment: .leading)
                                Text(rule.policy).font(.system(size: 10, weight: .medium)).foregroundStyle(rule.policy == "DIRECT" ? Theme.accent : Theme.warning).frame(width: 140, alignment: .leading)
                                Text("\(rule.matches)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                        }
                    }
                }
            }
            .card(0)
            .frame(maxHeight: .infinity)
            .clipped()
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
        }
    }
}

// MARK: - Profiles

/// “我的规则”：自定义规则列表，可切换走代理/直连、停用或删除
struct MyRulesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.customRuleItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("我的规则").font(.system(size: 12, weight: .semibold))
                Text("\(items.count) 条 · 优先于订阅规则 · 修改后内核会自动重新加载")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 38).background(Theme.surfaceMuted)
            if items.isEmpty {
                Text("还没有自定义规则。在“连接”页右键某条连接，可以把网站或应用设为始终走代理或直连。")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in MyRuleRow(item: item) }
                    }
                }
                .frame(height: min(CGFloat(items.count) * 46, 230))
            }
        }
        .card(0)
    }
}

struct MyRuleRow: View {
    @EnvironmentObject var model: AppModel
    let item: CustomRuleItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).foregroundStyle(Theme.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.payload).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.type).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if item.isSimple {
                Picker("", selection: Binding(get: { item.isDirect }, set: { model.setCustomRuleDirect(item, $0) })) {
                    Text("代理").tag(false)
                    Text("直连").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 110)
            } else {
                Text(item.policy).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Toggle("", isOn: Binding(get: { item.enabled }, set: { model.setCustomRuleEnabled(item, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(item.enabled ? "停用这条规则" : "启用这条规则")
            Button { model.deleteCustomRule(item) } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("删除这条规则")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .opacity(item.enabled ? 1 : 0.55)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
    }
}
