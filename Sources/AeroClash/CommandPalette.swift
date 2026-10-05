import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @StoredState private var query = ""
    let commands: [(String, String, SidebarSection?)] = [
        ("切换系统代理", "power", nil), ("打开代理节点", "point.3.connected.trianglepath.dotted", .proxies), ("查看活动连接", "arrow.triangle.branch", .connections), ("导入新配置", "plus", .profiles), ("打开设置", "gearshape", .settings)
    ]
    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture { model.showCommandPalette = false }
            VStack(spacing: 0) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary); TextField("输入命令…", text: $query).textFieldStyle(.plain).font(.system(size: 15)); Text("esc").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary).padding(.horizontal, 6).padding(.vertical, 3).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 4)) }.padding(.horizontal, 16).frame(height: 52)
                Divider().overlay(Theme.stroke)
                VStack(spacing: 3) {
                    ForEach(Array(commands.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }.enumerated()), id: \.offset) { _, cmd in
                        Button { if let section = cmd.2 { model.selectedSection = section }; if cmd.0 == "切换系统代理" { model.toggleConnection() }; if cmd.0 == "导入新配置" { model.showImportSheet = true }; model.showCommandPalette = false } label: { HStack(spacing: 11) { Image(systemName: cmd.1).frame(width: 22).foregroundStyle(Theme.accent); Text(cmd.0).font(.system(size: 12, weight: .medium)); Spacer(); Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }.padding(8)
            }.frame(width: 440).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.stroke)).shadow(color: .black.opacity(0.45), radius: 35, y: 15).offset(y: -100)
        }.onExitCommand { model.showCommandPalette = false }
    }
}
