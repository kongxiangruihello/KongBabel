import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

@MainActor
final class KongApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func installStatusBar(for model: AppModel) {
        guard statusBarController == nil else { return }
        statusBarController = StatusBarController(model: model)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showMainWindow()
        return true
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let contextPopover = NSPopover()
    private let noticePopover = NSPopover()
    private let rateView = StatusRateView()
    private var noticeCloseWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var mainWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        contextPopover.behavior = .transient
        contextPopover.animates = true
        let trayHost = NSHostingController(
            rootView: TrayContextMenuView(
                openSection: { [weak self] section in self?.showMainWindow(section: section) },
                dismiss: { [weak self] in self?.contextPopover.performClose(nil) },
                quit: { [weak self] in
                    self?.contextPopover.performClose(nil)
                    NSApp.terminate(nil)
                }
            )
            .environmentObject(model)
            .preferredColorScheme(.light)
        )
        // 弹出窗口的大小跟随内容（展开/收起节点组时自动变高变矮）
        trayHost.sizingOptions = [.preferredContentSize]
        contextPopover.contentViewController = trayHost

        noticePopover.behavior = .transient
        noticePopover.animates = true
        noticePopover.delegate = self

        if let button = statusItem.button {
            button.addSubview(rateView)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .light)
            button.toolTip = "KongBabel · 点击打开快捷面板"
        }

        model.$uploadRate
            .combineLatest(model.$downloadRate, model.$showMenuBarRates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.$networkIssueBadge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.$networkNotice
            .receive(on: RunLoop.main)
            .sink { [weak self] notice in self?.showNetworkNotice(notice) }
            .store(in: &cancellables)
        updateStatusItem()
        DispatchQueue.main.async { [weak self] in
            self?.mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey })
        }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        let issue = model.networkIssueBadge
        rateView.update(
            icon: model.menuBarIcon,
            upload: model.menuBarUploadRateText,
            download: model.menuBarDownloadRateText,
            showsRates: model.showMenuBarRates,
            badge: issue.map { $0 == .proxyUnreachable ? NSColor.systemOrange : NSColor.systemRed }
        )
        statusItem.length = rateView.preferredWidth
        rateView.frame = NSRect(x: 0, y: 0, width: rateView.preferredWidth, height: button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness)
        button.toolTip = issue.map { "KongBabel · \($0.title)" } ?? "KongBabel · 点击打开快捷面板"
    }

    private func showNetworkNotice(_ notice: NetworkNotice?) {
        noticeCloseWork?.cancel()
        guard let notice, let button = statusItem.button else {
            if noticePopover.isShown { noticePopover.performClose(nil) }
            return
        }
        contextPopover.performClose(nil)
        let host = NSHostingController(
            rootView: NetworkNoticeView(notice: notice)
                .environmentObject(model)
                .preferredColorScheme(.light)
        )
        noticePopover.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        noticePopover.contentSize = host.view.fittingSize
        if !noticePopover.isShown {
            noticePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if let delay = notice.autoDismissAfter {
            // 恢复/提示性消息几秒后自动收起；故障提示保持显示，直到用户处理或点击别处
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.networkNotice?.id == notice.id else { return }
                self.model.dismissNetworkNotice()
            }
            noticeCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === noticePopover, model.networkNotice != nil else { return }
        model.dismissNetworkNotice()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // 左键、右键都打开同一个快捷面板
        if contextPopover.isShown {
            contextPopover.performClose(nil)
        } else {
            if noticePopover.isShown { noticePopover.performClose(nil) }
            contextPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            contextPopover.contentViewController?.view.window?.makeKey()
        }
    }

    func showMainWindow(section: SidebarSection? = nil) {
        if let section { model.selectedSection = section }
        contextPopover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if mainWindow == nil {
            mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey })
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

/// 菜单栏中的“图标 + 上下两行速率”视图（上行在上、下行在下）。
final class StatusRateView: NSView {
    private let iconView = NSImageView()
    private let uploadLabel = NSTextField(labelWithString: "")
    private let downloadLabel = NSTextField(labelWithString: "")
    private let badgeView = NSView()
    private var showsRates = true
    private let iconSize: CGFloat = 20
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    /// 速率文字宽度按实际内容计算，避免短文字后面留出大段空白
    private var labelWidth: CGFloat = 40
    /// 图标与速率文字之间的间距
    private let gap: CGFloat = 3

    var preferredWidth: CGFloat { showsRates ? 2 + iconSize + gap + labelWidth + 1 : 2 + iconSize + 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // 与速率文字使用同一种颜色，避免图标显得发灰
        iconView.contentTintColor = .labelColor
        addSubview(iconView)
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 3.5
        badgeView.isHidden = true
        for label in [uploadLabel, downloadLabel] {
            label.font = rateFont
            label.textColor = .labelColor
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.drawsBackground = false
            label.isBezeled = false
            addSubview(label)
        }
        addSubview(badgeView)
    }

    required init?(coder: NSCoder) { nil }

    // 让点击穿透到菜单栏按钮本身，保留左键/右键弹出面板的行为
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(icon: NSImage, upload: String, download: String, showsRates: Bool, badge: NSColor?) {
        self.showsRates = showsRates
        iconView.image = icon
        uploadLabel.stringValue = "↑ \(upload)"
        downloadLabel.stringValue = "↓ \(download)"
        // NSTextField 左右各有约 2pt 内边距
        let textWidth = [uploadLabel.stringValue, downloadLabel.stringValue]
            .map { ($0 as NSString).size(withAttributes: [.font: rateFont]).width }
            .max() ?? 0
        labelWidth = ceil(textWidth) + 4
        uploadLabel.isHidden = !showsRates
        downloadLabel.isHidden = !showsRates
        badgeView.isHidden = badge == nil
        badgeView.layer?.backgroundColor = badge?.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        iconView.frame = NSRect(x: 2, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        let x = 2 + iconSize + gap
        let lineHeight: CGFloat = 10
        let top = (height + 2 * lineHeight) / 2
        uploadLabel.frame = NSRect(x: x, y: top - lineHeight, width: labelWidth, height: lineHeight + 1)
        downloadLabel.frame = NSRect(x: x, y: top - 2 * lineHeight, width: labelWidth, height: lineHeight + 1)
        // 状态小圆点位于图标右上角
        let badgeSize: CGFloat = 7
        badgeView.frame = NSRect(x: 2 + iconSize - badgeSize + 1, y: (height + iconSize) / 2 - badgeSize, width: badgeSize, height: badgeSize)
    }
}

/// 菜单栏图标下方弹出的网络状态提示。
struct NetworkNoticeView: View {
    @EnvironmentObject var model: AppModel
    let notice: NetworkNotice

    var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint(notice))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                        Text(notice.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { model.dismissNetworkNotice() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
                    }.buttonStyle(.plain)
                }
                if !notice.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(notice.actions, id: \.self) { action in
                            Button { model.performNetworkNoticeAction(action) } label: {
                                Text(action.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(action == notice.actions.first ? Theme.accent : Theme.panelStrong)
                                    .foregroundStyle(action == notice.actions.first ? Theme.onAccent : Theme.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        if notice.issue != nil {
                            Button("30 分钟内不提醒") { model.dismissNetworkNotice(snooze: true) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
            .background(Theme.bg)
    }

    private func tint(_ notice: NetworkNotice) -> Color {
        switch notice.style {
        case .failure: return Theme.danger
        case .warning: return Theme.warning
        case .recovery: return Theme.accent
        case .info, .update: return Theme.accent2
        }
    }
}

struct TrayContextMenuView: View {
    @EnvironmentObject var model: AppModel
    let openSection: (SidebarSection) -> Void
    let dismiss: () -> Void
    let quit: () -> Void

    @StoredState private var modeExpanded = false
    @StoredState private var expandedProxyGroup: String?
    @StoredState private var profilesExpanded = false
    @StoredState private var helpExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            quickPanel
            TrayMenuDivider()
            VStack(spacing: 0) {
                Button { modeExpanded.toggle() } label: {
                    TrayMenuRow(
                        title: "出站模式",
                        detail: model.mode.rawValue,
                        symbol: "point.3.filled.connected.trianglepath.dotted",
                        showsChevron: true,
                        expanded: modeExpanded
                    )
                }
                .buttonStyle(TrayMenuButtonStyle())

                if modeExpanded {
                    ForEach(ProxyMode.allCases) { mode in
                        Button {
                            model.setMode(mode)
                            dismiss()
                        } label: {
                            TrayMenuRow(title: mode.rawValue, checked: model.mode == mode, indented: true)
                        }
                        .buttonStyle(TrayMenuButtonStyle())
                    }
                }

                if model.proxyGroups.isEmpty {
                    TrayMenuRow(title: "暂无可用代理组", symbol: "network.slash", disabled: true)
                } else {
                    ForEach(model.proxyGroups) { group in
                        HStack(spacing: 0) {
                            Button {
                                expandedProxyGroup = expandedProxyGroup == group.name ? nil : group.name
                            } label: {
                                TrayMenuRow(
                                    title: group.name,
                                    detail: group.now,
                                    symbol: "server.rack",
                                    showsChevron: true,
                                    expanded: expandedProxyGroup == group.name,
                                    status: nodeStatusColor(group.now)
                                )
                            }
                            .buttonStyle(TrayMenuButtonStyle())
                            .help(nodeStatusText(group.now))

                            Button {
                                model.testGroupLatency(group.name)
                            } label: {
                                Group {
                                    if model.testingGroups.contains(group.name) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "bolt.horizontal.circle")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.secondary)
                                    }
                                }
                                .frame(width: 30, height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.coreState != .running || model.testingGroups.contains(group.name))
                            .help("测速这一组")
                        }

                        if expandedProxyGroup == group.name {
                            let memberList = VStack(spacing: 0) {
                                ForEach(group.members, id: \.self) { member in
                                    Button {
                                        model.selectNode(named: member, in: group.name)
                                        dismiss()
                                    } label: {
                                        TrayMenuRow(title: member, checked: group.now == member, indented: true, status: nodeStatusColor(member))
                                    }
                                    .buttonStyle(TrayMenuButtonStyle())
                                    .help(nodeStatusText(member))
                                }
                            }
                            if group.members.count > Self.maxVisibleNodes {
                                ScrollView(.vertical, showsIndicators: false) { memberList }
                                    .frame(height: CGFloat(Self.maxVisibleNodes) * 34)
                            } else {
                                memberList
                            }
                        }
                    }
                }

                TrayMenuDivider()

                Button {
                    model.copyTerminalProxyCommand()
                    dismiss()
                } label: {
                    TrayMenuRow(title: "复制终端代理命令", shortcut: "⌘C", symbol: "terminal")
                }
                .buttonStyle(TrayMenuButtonStyle())

                TrayMenuDivider()

                Button {
                    model.setLaunchAtLogin(!model.launchAtLogin)
                    dismiss()
                } label: {
                    TrayMenuRow(title: "开机启动", checked: model.launchAtLogin, symbol: model.launchAtLogin ? nil : "power.circle")
                }
                .buttonStyle(TrayMenuButtonStyle())

                Button {
                    model.setShowMenuBarRates(!model.showMenuBarRates)
                    dismiss()
                } label: {
                    TrayMenuRow(title: "显示实时速率", checked: model.showMenuBarRates, symbol: model.showMenuBarRates ? nil : "speedometer")
                }
                .buttonStyle(TrayMenuButtonStyle())

                Button {
                    model.setAllowLAN(!model.runtimeSettings.allowLAN)
                    dismiss()
                } label: {
                    TrayMenuRow(title: "允许局域网连接", checked: model.runtimeSettings.allowLAN, symbol: model.runtimeSettings.allowLAN ? nil : "wifi.router")
                }
                .buttonStyle(TrayMenuButtonStyle())

                TrayMenuDivider()

                Button {
                    model.testLatency()
                    dismiss()
                } label: {
                    TrayMenuRow(
                        title: model.latencyTesting ? "正在测速…" : "延迟测速",
                        shortcut: "⌘T",
                        symbol: "scope",
                        disabled: model.coreState != .running || model.latencyTesting
                    )
                }
                .buttonStyle(TrayMenuButtonStyle())
                .disabled(model.coreState != .running || model.latencyTesting)

                Button { openSection(.connections) } label: {
                    TrayMenuRow(title: "连接查看器", shortcut: "⇧⌘D", symbol: "arrow.triangle.branch")
                }
                .buttonStyle(TrayMenuButtonStyle())

                TrayMenuDivider()

                Button { profilesExpanded.toggle() } label: {
                    TrayMenuRow(title: "配置", symbol: "slider.horizontal.3", showsChevron: true, expanded: profilesExpanded)
                }
                .buttonStyle(TrayMenuButtonStyle())

                if profilesExpanded {
                    Button { openSection(.overview) } label: {
                        TrayMenuRow(title: "控制台", shortcut: "⌘D", symbol: "rectangle.3.group", indented: true)
                    }
                    .buttonStyle(TrayMenuButtonStyle())

                    Button { openSection(.settings) } label: {
                        TrayMenuRow(title: "更多设置", symbol: "gearshape", indented: true)
                    }
                    .buttonStyle(TrayMenuButtonStyle())

                    ForEach(model.profiles) { profile in
                        Button {
                            model.activateProfile(profile)
                            dismiss()
                        } label: {
                            TrayMenuRow(
                                title: profile.name,
                                detail: profile.id == model.activeProfileID ? "使用中" : nil,
                                checked: profile.id == model.activeProfileID,
                                symbol: "doc.text",
                                indented: true
                            )
                        }
                        .buttonStyle(TrayMenuButtonStyle())
                    }
                }

                Button { helpExpanded.toggle() } label: {
                    TrayMenuRow(title: "帮助", symbol: "questionmark.circle", showsChevron: true, expanded: helpExpanded)
                }
                .buttonStyle(TrayMenuButtonStyle())

                if helpExpanded {
                    Button { model.checkForUpdates(manual: true) } label: {
                        TrayMenuRow(title: "版本", detail: versionDetail, symbol: "info.circle", indented: true)
                    }
                    .buttonStyle(TrayMenuButtonStyle())
                    .help("点击检查更新")

                    Button { openSection(.developer) } label: {
                        TrayMenuRow(title: "开发者", detail: "孔祥瑞", symbol: "person.crop.circle", indented: true)
                    }
                    .buttonStyle(TrayMenuButtonStyle())
                }

                TrayMenuDivider()

                Button(action: quit) {
                    TrayMenuRow(title: "退出 KongBabel", shortcut: "⌘Q", symbol: "power")
                }
                .buttonStyle(TrayMenuButtonStyle())
            }
            .padding(8)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg)
    }

    private var quickPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("KongBabel")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(model.isConnected ? "\(model.runtimeSettings.captureMode.rawValue)已开启" : "流量接管已关闭")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let issue = model.networkIssueBadge {
                    Label(issue.title, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(issue == .proxyUnreachable ? Theme.warning : Theme.danger)
                        .lineLimit(1)
                }
            }
            Button { model.toggleConnection() } label: {
                Label(model.isConnected ? "关闭系统代理" : "开启系统代理", systemImage: "power")
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(model.isConnected ? Theme.panelStrong : Theme.accent)
                    .foregroundStyle(model.isConnected ? Theme.text : Theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// 展开的节点组最多直接显示的节点数，超过后该组列表可滚动
    static let maxVisibleNodes = 16

    private var versionDetail: String {
        if let release = model.latestRelease, UpdateChecker.isNewer(release.version, than: AppInfo.version) {
            return "\(AppInfo.version) · 有新版本 \(release.version)"
        }
        return AppInfo.version
    }

    private func isSpecialProxy(_ name: String) -> Bool {
        ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"].contains(name.uppercased())
    }

    /// 节点连接状态：绿色有效、红色失效、灰色还没测速
    private func nodeStatusColor(_ name: String) -> Color? {
        guard !isSpecialProxy(name) else { return nil }
        guard let delay = model.proxyDelays[name] else { return Theme.secondary.opacity(0.35) }
        return delay > 0 ? Theme.accent : Theme.danger
    }

    private func nodeStatusText(_ name: String) -> String {
        guard !isSpecialProxy(name) else { return name }
        guard let delay = model.proxyDelays[name] else { return "\(name)：还没有测速，可点击“延迟测速”" }
        return delay > 0 ? "\(name)：可用，\(delay) ms" : "\(name)：最近一次测速失败"
    }

    private func latencyColor(_ latency: Int) -> Color {
        guard latency > 0 else { return Theme.secondary }
        let limit = model.highLatencyThreshold > 0 ? model.highLatencyThreshold : 1_000
        if latency >= limit { return Theme.danger }
        if latency >= limit / 2 { return Theme.warning }
        return Theme.secondary
    }
}

private struct TrayMenuRow: View {
    let title: String
    var detail: String? = nil
    var shortcut: String? = nil
    var checked = false
    var symbol: String? = nil
    var showsChevron = false
    var expanded = false
    var indented = false
    var disabled = false
    /// 右侧的状态圆点颜色（绿色有效、红色失效、灰色未测速）；nil 表示不显示
    var status: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 142, alignment: .trailing)
            }
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.secondary.opacity(0.78))
            }
            if let status {
                Circle()
                    .fill(status)
                    .frame(width: 7, height: 7)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.leading, indented ? 18 : 8)
        .padding(.trailing, 8)
        .frame(height: 34)
        .opacity(disabled ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}

private struct TrayMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.stroke.opacity(0.72))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

private struct TrayMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Theme.panelStrong : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
