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
