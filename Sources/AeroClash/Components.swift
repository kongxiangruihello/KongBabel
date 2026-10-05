import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 13).frame(height: 34)
                .background(active ? Theme.accent : Theme.panelStrong)
                .clipShape(Capsule()).overlay(Capsule().stroke(active ? Color.clear : Theme.stroke))
        }.buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).frame(height: 34).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
    }
}

struct ModePicker: View {
    @Binding var selection: ProxyMode
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProxyMode.allCases) { mode in
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = mode } } label: {
                    Text(mode.rawValue).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 30)
                        .foregroundStyle(selection == mode ? Theme.text : Theme.secondary)
                        .background(selection == mode ? Theme.panel : .clear).clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
        }.padding(3).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }
}

struct StatusBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggleConnection() } label: {
            HStack(spacing: 8) {
                Circle().fill(model.isConnected ? Theme.accent : Theme.secondary).frame(width: 7, height: 7).shadow(color: model.isConnected ? Theme.accent.opacity(0.8) : .clear, radius: 5)
                Text(model.isChangingConnection ? "处理中" : model.isConnected ? "已连接" : "未连接").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 13).frame(height: 34).background(Theme.panelStrong).clipShape(Capsule()).overlay(Capsule().stroke(Theme.stroke))
        }.buttonStyle(.plain).disabled(model.isChangingConnection)
    }
}

// MARK: - Overview

struct MetricCard: View {
    let label: String, value: String, detail: String, icon: String, tint: Color
    var body: some View {
        HStack(spacing: 13) { Image(systemName: icon).foregroundStyle(tint).frame(width: 38, height: 38).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 10)).foregroundStyle(Theme.secondary); Text(value).font(.system(size: 17, weight: .bold)); Text(detail).font(.system(size: 9)).foregroundStyle(Theme.secondary) }; Spacer() }.frame(maxWidth: .infinity).card(14)
    }
}

// MARK: - Rules

struct InfoTile: View {
    let icon: String, title: String, subtitle: String
    var body: some View { HStack(alignment: .top, spacing: 10) { Image(systemName: icon).foregroundStyle(Theme.accent2); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11, weight: .semibold)); Text(subtitle).font(.system(size: 9)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer() }.frame(maxWidth: .infinity).card(14) }
}
