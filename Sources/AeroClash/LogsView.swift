import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @StoredState private var level = "全部"
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "日志", subtitle: "实时查看内核运行信息") {
                HStack(spacing: 10) { PillButton(title: "清空", icon: "trash") { model.logs.removeAll(); model.showToast("日志已清空") }; PillButton(title: "复制", icon: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logs.map { "\($0.time) [\($0.level)] \($0.message)" }.joined(separator: "\n"), forType: .string); model.showToast("日志已复制") } }
            }
            HStack { Picker("级别", selection: $level) { ForEach(["全部", "INFO", "WARN", "DEBUG"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 260); Spacer(); Label("自动滚动", systemImage: "arrow.down.to.line").font(.system(size: 10)).foregroundStyle(Theme.secondary) }.padding(.horizontal, 30).padding(.bottom, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.logs.filter { level == "全部" || $0.level == level }) { log in
                        HStack(alignment: .top, spacing: 12) { Text(log.time).foregroundStyle(Theme.secondary).frame(width: 60, alignment: .leading); Text(log.level).foregroundStyle(log.level == "WARN" ? Theme.warning : log.level == "DEBUG" ? Theme.accent2 : Theme.accent).frame(width: 50, alignment: .leading); Text(log.message).foregroundStyle(Theme.text.opacity(0.86)).textSelection(.enabled) }.font(.system(size: 10, design: .monospaced)).padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surfaceMuted.opacity(0.55)).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                    }
                }
            }.card(0).padding(.horizontal, 30).padding(.bottom, 26)
        }
    }
}

// MARK: - Network events
