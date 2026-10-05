import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "配置", subtitle: "管理订阅与本地配置文件") {
                HStack(spacing: 9) {
                    PillButton(title: "编辑 YAML", icon: "chevron.left.forwardslash.chevron.right") { model.beginEditingActiveYAML() }
                    PillButton(title: model.subscriptionUpdateInProgress ? "更新中" : "全部更新", icon: "arrow.clockwise") { model.updateAllSubscriptions() }
                    PillButton(title: "导入配置", icon: "plus", active: true) { model.showImportSheet = true }
                }
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.activateProfile(profile)
                        } label: {
                            HStack(spacing: 15) {
                                Image(systemName: profile.id == "default" ? "cloud.fill" : "doc.text.fill").font(.system(size: 18)).foregroundStyle(profile.id == model.activeProfileID ? Theme.accent : Theme.secondary).frame(width: 42, height: 42).background((profile.id == model.activeProfileID ? Theme.accent : Theme.secondary).opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(profile.name).font(.system(size: 14, weight: .bold)); if profile.id == model.activeProfileID { Text("使用中").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent).clipShape(Capsule()) } }
                                    Text(profile.source).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                    if let usage = model.usage(for: profile) {
                                        Text([usage.summary, usage.expiryText].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(Theme.accent2)
                                    }
                                }
                                Spacer(); VStack(alignment: .trailing, spacing: 4) { Text(profile.updated).font(.system(size: 10, weight: .medium)); Text(profile.size).font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                                Button { model.updateProfile(profile) } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 30).background(Theme.panelStrong).clipShape(Circle()) }.buttonStyle(.plain)
                                Button { model.editSettings(for: profile) } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }.buttonStyle(.plain)
                            }.padding(16).background(profile.id == model.activeProfileID ? Theme.accent.opacity(0.065) : Theme.panel).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(profile.id == model.activeProfileID ? Theme.accent.opacity(0.45) : Theme.stroke))
                        }.buttonStyle(.plain)
                    }
                    Button { model.showImportSheet = true } label: {
                        HStack { Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent); Text("添加订阅或本地配置").font(.system(size: 12, weight: .semibold)) }.frame(maxWidth: .infinity).frame(height: 70).background(Theme.panel.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 30)
                HStack(alignment: .top, spacing: 12) {
                    InfoTile(icon: "clock.arrow.circlepath", title: "自动更新", subtitle: "按每个订阅设置的间隔独立检查")
                    InfoTile(icon: "checkmark.shield.fill", title: "配置检查", subtitle: "导入前由 Mihomo 内核验证")
                    InfoTile(icon: "externaldrive.fill", title: "自动备份", subtitle: "保留最近 5 个可用版本")
                }.padding(30)
            }
        }
    }
}

struct ProfileSettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let profile: Profile
    @StoredState private var intervalHours: Int
    @StoredState private var userAgent: String

    init(profile: Profile) {
        self.profile = profile
        _intervalHours = StoredState(initialValue: 24)
        _userAgent = StoredState(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.system(size: 18, weight: .bold))
                    Text("单独设置更新间隔与订阅 User-Agent").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let remote = profile.remoteURL { QRCodeView(value: remote).frame(width: 88, height: 88) }
            }
            HStack {
                Text("更新间隔").font(.system(size: 11, weight: .semibold))
                Spacer()
                Stepper("\(intervalHours) 小时", value: $intervalHours, in: 1...720).frame(width: 145)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("User-Agent").font(.system(size: 11, weight: .semibold))
                TextField("留空时自动尝试 Clash.Meta 等常用标识", text: $userAgent).textFieldStyle(.roundedBorder)
            }
            if let usage = model.usage(for: profile) {
                Text([usage.summary, usage.expiryText].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(Theme.accent2)
            }
            HStack {
                Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                Spacer()
                Button("立即更新") { model.updateProfile(profile) }.buttonStyle(.plain)
                Button("保存") { model.savePreference(for: profile, intervalHours: intervalHours, userAgent: userAgent); dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(24).frame(width: 500).background(Theme.bg)
        .onAppear {
            let preference = model.preference(for: profile)
            intervalHours = preference.updateIntervalHours
            userAgent = preference.userAgent
        }
    }
}

struct QRCodeView: View {
    let value: String
    var body: some View {
        if let image = makeImage() {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(5).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        }
    }

    private func makeImage() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct YAMLEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("YAML 配置编辑器").font(.system(size: 17, weight: .bold))
                    Text("保存前由当前 Mihomo 内核验证；原文件自动备份，最多保留 5 份。")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.plain)
                Button("校验并保存") { model.saveEditedYAML() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }.padding(18)
            Divider().overlay(Theme.stroke)
            YAMLSyntaxEditor(text: $model.editingYAML)
                .padding(12).background(Theme.panel)
        }.frame(minWidth: 780, minHeight: 560).background(Theme.bg)
    }
}

struct YAMLSyntaxEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.replaceText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        context.coordinator.replaceText(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: YAMLSyntaxEditor
        weak var textView: NSTextView?
        private var applyingStyle = false

        init(_ parent: YAMLSyntaxEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applyingStyle, let textView else { return }
            parent.text = textView.string
            highlight()
        }

        func replaceText(_ value: String) {
            guard let textView else { return }
            applyingStyle = true
            let selection = textView.selectedRanges
            textView.string = value
            let validSelection = selection.filter { NSMaxRange($0.rangeValue) <= value.utf16.count }
            if validSelection.isEmpty {
                textView.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
            } else {
                textView.selectedRanges = validSelection
            }
            applyingStyle = false
            highlight()
        }

        private func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            applyingStyle = true
            defer { applyingStyle = false }
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.23, alpha: 1)
            ], range: whole)
            apply(#"(?m)^[ \t-]*[A-Za-z0-9_.-]+(?=\s*:)"#, color: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.78, alpha: 1), storage: storage)
            apply(#"(?<![A-Za-z])(true|false|null|yes|no)(?![A-Za-z])"#, color: NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.72, alpha: 1), storage: storage)
            apply(#"(?<![A-Za-z0-9_.-])-?[0-9]+(?:\.[0-9]+)?(?![A-Za-z0-9_.-])"#, color: NSColor(calibratedRed: 0.76, green: 0.37, blue: 0.18, alpha: 1), storage: storage)
            apply(#"(?m)#.*$"#, color: NSColor(calibratedRed: 0.46, green: 0.52, blue: 0.58, alpha: 1), storage: storage)
        }

        private func apply(_ pattern: String, color: NSColor, storage: NSTextStorage) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: storage.length)
            for match in expression.matches(in: storage.string, range: range) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}

struct ImportProfileSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @StoredState private var url = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { ZStack { RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.14)); Image(systemName: "link").foregroundStyle(Theme.accent) }.frame(width: 42, height: 42); VStack(alignment: .leading, spacing: 2) { Text("导入配置").font(.system(size: 18, weight: .bold)); Text("添加订阅链接或选择本地文件").font(.system(size: 11)).foregroundStyle(Theme.secondary) } }
            VStack(alignment: .leading, spacing: 7) {
                Text("订阅地址").font(.system(size: 11, weight: .semibold))
                TextField("https://example.com/subscription", text: $url)
                    .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 38)
                    .background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
                Text("支持 Clash / Mihomo 配置、Provider、Base64 与节点链接订阅")
                    .font(.system(size: 9)).foregroundStyle(Theme.secondary)
            }
            HStack { Rectangle().fill(Theme.stroke).frame(height: 1); Text("或者").font(.system(size: 10)).foregroundStyle(Theme.secondary); Rectangle().fill(Theme.stroke).frame(height: 1) }
            Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.importLocalProfile() } } label: { Label("选择本地文件", systemImage: "folder").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 42).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke)) }.buttonStyle(.plain)
            HStack { Button("取消") { dismiss() }.buttonStyle(.plain).foregroundStyle(Theme.secondary); Spacer(); Button("导入") { dismiss(); model.importProfile(from: url) }.buttonStyle(.plain).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 20).frame(height: 36).background(Theme.accent).clipShape(Capsule()).disabled(url.isEmpty) }
        }.padding(24).frame(width: 470).background(Theme.bg)
    }
}

// MARK: - Logs
