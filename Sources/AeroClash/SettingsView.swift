import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置", subtitle: "调整流量接管、DNS 与 Mihomo 运行方式") {
                HStack(spacing: 10) {
                    PillButton(title: "恢复默认", icon: "arrow.counterclockwise") { model.resetRuntimeSettings() }
                    PillButton(title: "应用设置", icon: "checkmark", active: true) { model.saveAndApplySettings() }
                }
            }
            ScrollView {
                VStack(spacing: 16) {
                    SettingsGroup(title: "通用") {
                        SettingToggle(icon: "power", title: "登录时启动", subtitle: "使用 macOS 原生登录项目运行 KongBabel", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        SettingToggle(icon: "arrow.clockwise", title: "自动更新订阅", subtitle: "按照每个订阅单独设置的更新间隔检查", isOn: $model.runtimeSettings.automaticSubscriptionUpdates)
                        SettingToggle(icon: "wifi.exclamationmark", title: "网络状态提醒", subtitle: "断网、无法访问互联网、节点失效或内核停止时，在菜单栏图标旁弹出提示", isOn: Binding(get: { model.networkAlertsEnabled }, set: model.setNetworkAlertsEnabled))
                        SettingToggle(icon: "arrow.triangle.2.circlepath", title: "节点失效时自动切换", subtitle: "节点连不上或延迟过高时，自动测速并切换到更快的可用节点", isOn: Binding(get: { model.autoSwitchNodeEnabled }, set: model.setAutoSwitchNodeEnabled))
                        if model.autoSwitchNodeEnabled {
                            SettingsRow(icon: "speedometer", title: "延迟上限", subtitle: "当前节点连续两次超过此延迟，自动换到明显更快的节点") {
                                Picker("", selection: Binding(get: { model.highLatencyThreshold }, set: model.setHighLatencyThreshold)) {
                                    Text("关闭").tag(0)
                                    Text("500 ms").tag(500)
                                    Text("800 ms").tag(800)
                                    Text("1000 ms").tag(1_000)
                                    Text("1500 ms").tag(1_500)
                                    Text("2000 ms").tag(2_000)
                                }.labelsHidden().frame(width: 110)
                            }
                        }
                        SettingToggle(icon: "command", title: "全局快捷键", subtitle: "在任何应用中都可使用以下快捷键", isOn: Binding(get: { model.globalHotKeysEnabled }, set: model.setGlobalHotKeysEnabled))
                        if model.globalHotKeysEnabled {
                            ForEach(KongHotKey.allCases) { key in
                                SettingsRow(icon: "keyboard", title: key.title, subtitle: model.unavailableHotKeys.contains(key.rawValue) ? "已被其他应用占用，暂不可用" : "全局可用") {
                                    Text(key.display)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .foregroundStyle(model.unavailableHotKeys.contains(key.rawValue) ? Theme.danger : Theme.text)
                                }
                            }
                        }
                        SettingToggle(icon: "calendar.badge.clock", title: "订阅到期与流量提醒", subtitle: "到期前 3 天、流量剩余 10% 时在菜单栏图标旁提醒一次", isOn: Binding(get: { model.subscriptionRemindersEnabled }, set: model.setSubscriptionRemindersEnabled))
                    }
                    SettingsGroup(title: "流量接管") {
                        SettingsRow(icon: "checkmark.shield", title: "系统实际状态", subtitle: model.detectedCaptureMode?.rawValue ?? (model.isConnected && model.runtimeSettings.captureMode == .tun ? "TUN（由内核接管）" : "未启用")) {
                            StatusBadge()
                        }
                        SettingsRow(icon: "network.badge.shield.half.filled", title: "接管方式", subtitle: "系统代理与 PAC 会自动备份并可靠恢复；TUN 由 Mihomo 接管") {
                            Picker("", selection: $model.runtimeSettings.captureMode) {
                                ForEach(ProxyCaptureMode.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 245)
                        }
                        SettingToggle(icon: "wifi.router", title: "允许局域网连接", subtitle: "启用 allow-lan 并监听所有本机地址", isOn: $model.runtimeSettings.allowLAN)
                        SettingToggle(icon: "arrow.triangle.merge", title: "混合端口", subtitle: "HTTP 与 SOCKS 共用同一个 mixed-port", isOn: $model.runtimeSettings.useMixedPort)
                        SettingsRow(icon: "number", title: "监听端口", subtitle: "端口占用时 KongBabel 会选择相邻可用端口") {
                            if model.runtimeSettings.useMixedPort {
                                IntegerSettingField(label: "MIXED", value: $model.runtimeSettings.mixedPort)
                            } else {
                                IntegerSettingField(label: "HTTP", value: $model.runtimeSettings.httpPort)
                                IntegerSettingField(label: "SOCKS", value: $model.runtimeSettings.socksPort)
                            }
                        }
                    }
                    SettingsGroup(title: "TUN") {
                        SettingsRow(icon: "shield.lefthalf.filled", title: "协议栈", subtitle: "mixed 自动选择；system 与 gVisor 可手动指定") {
                            Picker("", selection: $model.runtimeSettings.tunStack) { ForEach(TUNStack.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 130)
                        }
                        SettingToggle(icon: "point.topleft.down.curvedto.point.bottomright.up", title: "自动路由", subtitle: "对应 auto-route，全局接管系统路由", isOn: $model.runtimeSettings.tunAutoRoute)
                        SettingToggle(icon: "network", title: "自动识别出口", subtitle: "对应 auto-detect-interface", isOn: $model.runtimeSettings.tunAutoDetectInterface)
                        SettingToggle(icon: "globe.badge.chevron.backward", title: "DNS 劫持", subtitle: "接管 UDP/TCP 53 端口查询", isOn: $model.runtimeSettings.tunDNSHijack)
                        Text("首次开启 TUN 若 macOS 拒绝修改路由，KongBabel 会显示内核错误；正式分发版应配套 Developer ID 签名的特权辅助程序。")
                            .font(.system(size: 9)).foregroundStyle(Theme.warning).padding(.vertical, 10)
                    }
                    SettingsGroup(title: "DNS 与防泄漏") {
                        SettingToggle(icon: "server.rack", title: "覆写订阅 DNS", subtitle: "启用分层 DNS，不修改订阅原文件", isOn: $model.runtimeSettings.dnsOverrideEnabled)
                        if model.runtimeSettings.dnsOverrideEnabled {
                            SettingsRow(icon: "arrow.left.arrow.right", title: "增强模式", subtitle: "Fake-IP 或 Redir-Host") {
                                Picker("", selection: $model.runtimeSettings.dnsMode) { ForEach(DNSMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
                            }
                            SettingToggle(icon: "bolt.horizontal", title: "优先 HTTP/3", subtitle: "DoH 上游优先 prefer-h3", isOn: $model.runtimeSettings.preferH3)
                            SettingToggle(icon: "arrow.triangle.branch", title: "DNS 遵循规则", subtitle: "启用 respect-rules，需配置节点域名专用 DNS", isOn: $model.runtimeSettings.respectRules)
                            MultilineSetting(title: "主 DNS（nameserver）", text: $model.runtimeSettings.nameservers)
                            MultilineSetting(title: "备用 DNS（fallback）", text: $model.runtimeSettings.fallbackNameservers)
                            MultilineSetting(title: "节点域名 DNS（proxy-server-nameserver）", text: $model.runtimeSettings.proxyServerNameservers)
                        }
                        SettingToggle(icon: "eye", title: "域名嗅探", subtitle: "从 HTTP、TLS 与 QUIC 恢复真实域名", isOn: $model.runtimeSettings.snifferEnabled)
                        SettingToggle(icon: "arrow.triangle.swap", title: "改写访问目标", subtitle: "启用 override-destination", isOn: $model.runtimeSettings.overrideDestination)
                    }
                    SettingsGroup(title: "规则覆写") {
                        RuleComposer(
                            rules: $model.runtimeSettings.customRules,
                            policies: Array(Set(["DIRECT", "REJECT", "节点选择"] + model.proxyGroups.map(\.name))).sorted()
                        )
                        VStack(alignment: .leading, spacing: 7) {
                            Text("自定义规则").font(.system(size: 11, weight: .semibold))
                            Text("每行一条，支持 DOMAIN、GEOSITE、GEOIP、IP-CIDR、PROCESS-NAME、AND / OR / NOT；自动插入到订阅规则之前。")
                                .font(.system(size: 9)).foregroundStyle(Theme.secondary)
                            TextEditor(text: $model.runtimeSettings.customRules)
                                .font(.system(size: 10, design: .monospaced)).frame(minHeight: 100)
                                .padding(8).background(Theme.surfaceMuted).clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
                        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                        SettingToggle(icon: "square.stack.3d.up", title: "远程 RULE-SET", subtitle: "按间隔下载并在自定义规则前匹配", isOn: $model.runtimeSettings.ruleProvider.enabled)
                        if model.runtimeSettings.ruleProvider.enabled {
                            RuleProviderEditor(provider: $model.runtimeSettings.ruleProvider)
                        }
                    }
                    SettingsGroup(title: "备份与订阅聚合") {
                        WebDAVEditor(
                            settings: $model.webDAVSettings,
                            password: $model.webDAVPassword,
                            busy: model.webDAVBusy,
                            save: model.saveWebDAVSettings,
                            backup: model.backupToWebDAV,
                            restore: model.restoreFromWebDAV
                        )
                        SettingsRow(icon: "square.3.layers.3d", title: "Sub-Store", subtitle: "可直接导入 Sub-Store 生成的 Clash/Mihomo 订阅地址，继续使用自动更新、流量与二维码功能") {
                            PillButton(title: "导入聚合订阅", icon: "plus") { model.showImportSheet = true }
                        }
                    }
                    SettingsGroup(title: "流量历史（最近 90 天）") {
                        TrafficHistorySummary(days: Array(model.trafficHistory.suffix(7)))
                    }
                    SettingsGroup(title: "内核") {
                        SettingsRow(icon: "cpu.fill", title: "Mihomo Core", subtitle: model.coreState.label + " · 控制器仅监听本机") {
                            Picker("", selection: $model.runtimeSettings.coreChannel) { ForEach(CoreChannel.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
                            Text(model.coreVersion).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                            PillButton(title: "重启", icon: "arrow.clockwise") { Task { await model.startCore() } }
                        }
                        SettingsRow(icon: "rectangle.connected.to.line.below", title: "外部控制器", subtitle: "打开 MetaCubeXD；地址与本地密钥会复制到剪贴板") {
                            PillButton(title: "打开面板", icon: "safari") { model.openWebDashboard() }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("内核协议能力").font(.system(size: 11, weight: .semibold))
                            Text("完整 YAML 可使用 Mihomo 支持的 VLESS / Reality / XTLS、Trojan、SS / SS-2022、VMess、Hysteria 1/2、TUIC 4/5、WireGuard、Snell 与 SSH；节点链接导入支持常见 URI 格式。")
                                .font(.system(size: 9)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 12)
                    }
                    Text(AppInfo.versionLine).font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.top, 4)
                }.padding(.horizontal, 30).padding(.bottom, 30)
            }
        }
    }
}

struct DeveloperView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "开发者", subtitle: "KongBabel") { EmptyView() }
            HStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(width: 72, height: 72)
                Text("孔祥瑞")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
            }
            .card(22)
            Spacer()
        }
        .padding(30)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary).padding(.horizontal, 4).padding(.bottom, 8); VStack(spacing: 0) { content() }.padding(.horizontal, 15).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke)) } }
}

struct SettingToggle: View {
    let icon: String, title: String, subtitle: String
    @Binding var isOn: Bool
    var body: some View { HStack { VStack(alignment: .leading, spacing: 3) { Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)); Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary) }; Spacer(); Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) } }
}

struct SettingsRow<Accessory: View>: View {
    let icon: String, title: String, subtitle: String
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer(); accessory()
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
    }
}

struct IntegerSettingField: View {
    let label: String
    @Binding var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.plain).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 8).frame(width: 72, height: 27)
                .background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

struct MultilineSetting: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold))
            TextEditor(text: $text).font(.system(size: 9, design: .monospaced)).frame(height: 54)
                .padding(6).background(Theme.surfaceMuted).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        }.padding(.vertical, 9).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
    }
}

struct RuleProviderEditor: View {
    @Binding var provider: RuleProviderOverride
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                TextField("名称", text: $provider.name)
                TextField("匹配策略组", text: $provider.policy)
                Picker("", selection: $provider.behavior) {
                    ForEach(["classical", "domain", "ipcidr"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 110)
            }
            TextField("https://example.com/rules.yaml", text: $provider.url)
            HStack { Text("更新间隔（秒）").font(.system(size: 9)).foregroundStyle(Theme.secondary); IntegerSettingField(label: "INTERVAL", value: $provider.intervalSeconds); Spacer() }
        }.textFieldStyle(.roundedBorder).font(.system(size: 10)).padding(.vertical, 10)
    }
}

struct RuleComposer: View {
    @Binding var rules: String
    let policies: [String]
    @StoredState private var type = "DOMAIN-SUFFIX"
    @StoredState private var payload = ""
    @StoredState private var policy = "节点选择"

    private let types = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "GEOSITE", "GEOIP", "IP-CIDR", "PROCESS-NAME", "AND", "OR", "NOT"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可视化添加规则").font(.system(size: 11, weight: .semibold))
            HStack(spacing: 8) {
                Picker("", selection: $type) { ForEach(types, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 150)
                TextField(type == "PROCESS-NAME" ? "例如 curl" : "匹配内容", text: $payload)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $policy) { ForEach(policies, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 145)
                Button("添加") { appendRule() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(cleanPayload.isEmpty)
            }
            Text("复杂逻辑规则可在下方文本编辑区继续调整。")
                .font(.system(size: 9)).foregroundStyle(Theme.secondary)
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
    }

    private var cleanPayload: String {
        payload.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
    }

    private func appendRule() {
        let newRule = "\(type),\(cleanPayload),\(policy)"
        rules += rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? newRule : "\n\(newRule)"
        payload = ""
    }
}

struct WebDAVEditor: View {
    @Binding var settings: WebDAVSettings
    @Binding var password: String
    let busy: Bool
    let save: () -> Void
    let backup: () -> Void
    let restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("WebDAV 一键备份与恢复", systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("保存") { save() }.buttonStyle(.bordered)
                Button("备份") { backup() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("恢复") { restore() }.buttonStyle(.bordered).disabled(busy)
            }
            TextField("WebDAV 目录地址，例如 https://dav.example.com/remote.php/dav/files/me/", text: $settings.serverURL)
            HStack {
                TextField("用户名", text: $settings.username)
                SecureField("密码（存入 macOS 钥匙串）", text: $password)
                TextField("远程文件，例如 Kong-backup.json", text: $settings.remotePath)
            }
            Text("备份包含配置、Provider、订阅偏好与运行时覆写；密码仅保存在本机钥匙串，不写入备份。")
                .font(.system(size: 9)).foregroundStyle(Theme.secondary)
        }.textFieldStyle(.roundedBorder).font(.system(size: 10)).padding(.vertical, 12)
    }
}

struct TrafficHistorySummary: View {
    let days: [DailyTraffic]

    var body: some View {
        if days.isEmpty {
            Text("连接后会按天记录上传和下载用量，数据仅保存在本机。")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.vertical, 14)
        } else {
            VStack(spacing: 0) {
                ForEach(days.reversed()) { day in
                    HStack {
                        Text(day.day).font(.system(size: 10, design: .monospaced)).frame(width: 100, alignment: .leading)
                        Spacer()
                        Label(ByteCountFormatter.string(fromByteCount: day.uploadBytes, countStyle: .binary), systemImage: "arrow.up")
                            .foregroundStyle(Theme.accent2)
                        Label(ByteCountFormatter.string(fromByteCount: day.downloadBytes, countStyle: .binary), systemImage: "arrow.down")
                            .foregroundStyle(Theme.accent)
                    }.font(.system(size: 10)).padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Divider().overlay(Theme.stroke) }
                }
            }
        }
    }
}

struct LabeledPort: View {
    let label: String
    @Binding var value: String
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9)).foregroundStyle(Theme.secondary); TextField("", text: $value).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).frame(width: 74, height: 28).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke)) } }
}

struct PortBadge: View {
    let label: String
    let value: Int
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(label).font(.system(size: 9)).foregroundStyle(Theme.secondary); Text("\(value)").font(.system(size: 11, design: .monospaced)).padding(.horizontal, 9).frame(height: 28).background(Theme.panelStrong).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke)) } }
}

// MARK: - Command palette & menu bar
