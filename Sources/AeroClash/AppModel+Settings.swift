import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

// 运行设置、WebDAV、登录启动与外部面板

extension AppModel {
    func saveAndApplySettings() {
        do {
            runtimeSettings.mixedPort = validPort(runtimeSettings.mixedPort, fallback: 17_890)
            runtimeSettings.httpPort = validPort(runtimeSettings.httpPort, fallback: 17_890)
            runtimeSettings.socksPort = validPort(runtimeSettings.socksPort, fallback: 17_891)
            try settingsStore.save(runtimeSettings)
            Task {
                let reconnect = isConnected
                if reconnect { await setConnectionEnabled(false) }
                await startCore()
                if reconnect { await setConnectionEnabled(true) }
                showToast("高级网络设置已应用")
            }
        } catch { presentError("保存设置失败", error) }
    }

    func resetRuntimeSettings() {
        runtimeSettings = .standard
        saveAndApplySettings()
    }

    func saveWebDAVSettings() {
        do {
            webDAVSettings.serverURL = webDAVSettings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            webDAVSettings.username = String(webDAVSettings.username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            webDAVSettings.remotePath = String(webDAVSettings.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            try webDAVSettingsStore.save(webDAVSettings)
            try webDAVCredentialStore.savePassword(webDAVPassword)
            showToast("WebDAV 设置已安全保存")
        } catch { presentError("保存 WebDAV 设置失败", error) }
    }

    func backupToWebDAV() {
        guard !webDAVBusy else { return }
        webDAVBusy = true
        Task {
            defer { webDAVBusy = false }
            do {
                try webDAVSettingsStore.save(webDAVSettings)
                try webDAVCredentialStore.savePassword(webDAVPassword)
                let bundle = try repository.makeBackupBundle(profiles: profiles, settings: runtimeSettings)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(bundle)
                try await webDAVClient.upload(data, settings: webDAVSettings, password: webDAVPassword)
                showToast("WebDAV 备份完成 · \(profiles.count) 个配置")
            } catch { presentError("WebDAV 备份失败", error) }
        }
    }

    func restoreFromWebDAV() {
        guard !webDAVBusy else { return }
        let alert = NSAlert()
        alert.messageText = "从 WebDAV 恢复 KongBabel？"
        alert.informativeText = "将恢复配置、订阅偏好和网络覆写设置。当前配置会先保留本地备份。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        webDAVBusy = true
        Task {
            defer { webDAVBusy = false }
            do {
                let data = try await webDAVClient.download(settings: webDAVSettings, password: webDAVPassword)
                let bundle = try JSONDecoder().decode(AeroBackupBundle.self, from: data)
                guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else {
                    throw AeroRuntimeError.missingCore
                }
                let restored = try repository.restoreBackup(bundle, coreURL: coreURL)
                profiles = restored.0
                runtimeSettings = restored.1
                try settingsStore.save(runtimeSettings)
                if !profiles.contains(where: { $0.id == activeProfileID }) {
                    activeProfileID = profiles[0].id
                    UserDefaults.standard.set(activeProfileID, forKey: "activeProfileID")
                }
                await startCore()
                showToast("WebDAV 恢复完成 · \(profiles.count) 个配置")
            } catch { presentError("WebDAV 恢复失败", error) }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            showToast(launchAtLogin ? "已启用登录时启动" : "已关闭登录时启动")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            presentError("开机启动设置失败", error)
        }
    }

    func setShowMenuBarRates(_ enabled: Bool) {
        showMenuBarRates = enabled
        UserDefaults.standard.set(enabled, forKey: "showMenuBarRates")
        showToast(enabled ? "已显示菜单栏实时速率" : "已隐藏菜单栏实时速率")
    }

    func setAllowLAN(_ enabled: Bool) {
        guard runtimeSettings.allowLAN != enabled else { return }
        runtimeSettings.allowLAN = enabled
        saveAndApplySettings()
    }

    func copyTerminalProxyCommand() {
        let command = "export http_proxy=http://127.0.0.1:\(httpPort) https_proxy=http://127.0.0.1:\(httpPort) all_proxy=socks5://127.0.0.1:\(socksPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        showToast("终端代理命令已复制")
    }

    func openWebDashboard() {
        guard let url = URL(string: "https://metacubexd.pages.dev") else { return }
        NSWorkspace.shared.open(url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(controllerPort)\n\(api.secret)", forType: .string)
        showToast("控制器地址与密钥已复制")
    }
}
