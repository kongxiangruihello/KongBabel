import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

// Keep source-compatible property-wrapper state when building with Command Line Tools
// whose SDK exposes the newer SwiftUI @State macro without bundling its compiler plug-in.
typealias StoredState<Value> = SwiftUI.State<Value>


@main
struct KongApp: App {
    @NSApplicationDelegateAdaptor(KongApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { appDelegate.installStatusBar(for: model) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandMenu("KongBabel") {
                Button(model.isConnected ? "关闭系统代理" : "开启系统代理") { model.toggleConnection() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("打开命令面板") { model.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

    }
}
