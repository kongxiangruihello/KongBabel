import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 218)
                Divider().overlay(Theme.stroke)
                ZStack {
                    switch model.selectedSection {
                    case .overview: OverviewView()
                    case .proxies: ProxiesView()
                    case .connections: ConnectionsView()
                    case .rules: RulesView()
                    case .profiles: ProfilesView()
                    case .logs: LogsView()
                    case .events: NetworkEventsView()
                    case .settings: SettingsView()
                    case .developer: DeveloperView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.showCommandPalette { CommandPalette() }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.stroke))
                        .shadow(color: Theme.text.opacity(0.16), radius: 20, y: 8)
                        .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $model.showImportSheet) { ImportProfileSheet() }
        .sheet(isPresented: $model.showProfileSettings) {
            if let profile = model.profileBeingEdited { ProfileSettingsSheet(profile: profile) }
        }
        .sheet(isPresented: $model.showYAMLEditor) { YAMLEditorSheet() }
        .alert("操作失败", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("KongBabel").font(.system(size: 17, weight: .bold))
                    Text("网络控制台").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 18)
            .padding(.bottom, 22)

            VStack(spacing: 4) {
                ForEach(SidebarSection.allCases) { section in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { model.selectedSection = section }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.icon).frame(width: 20)
                            Text(section.rawValue).font(.system(size: 13, weight: .medium))
                            Spacer()
                            if section == .connections {
                                Text("\(model.connections.count)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.15)).foregroundStyle(Theme.accent).clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(model.selectedSection == section ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(model.selectedSection == section ? Theme.panelStrong : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 7) {
                        Circle().fill(model.coreState == .running ? Theme.accent : model.coreState == .starting ? Theme.warning : Theme.secondary).frame(width: 7, height: 7)
                        Text(model.coreState.label).font(.system(size: 11, weight: .medium))
                    }
                    Spacer()
                    Text("v\(AppInfo.version)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedNode.name).font(.system(size: 12, weight: .semibold))
                        Text("\(model.selectedNode.latency) ms · \(model.selectedNode.type)").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(model.selectedNode.countryCode).font(.system(size: 18))
                }
            }
            .padding(13)
            .background(Theme.panelStrong)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
        .background(Theme.sidebar)
    }
}

// MARK: - Shared components
