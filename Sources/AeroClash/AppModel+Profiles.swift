import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

// 配置文件、订阅导入与更新、YAML 编辑

extension AppModel {
    func activateProfile(_ profile: Profile) {
        guard profile.id != activeProfileID else { return }
        activeProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "activeProfileID")
        Task {
            await startCore()
            showToast("已应用配置“\(profile.name)”")
        }
    }

    func importProfile(from urlString: String) {
        guard let url = SubscriptionDownloader.normalizedURL(from: urlString) else {
            presentError("无法添加订阅", SubscriptionDownloadError.invalidURL)
            return
        }
        Task {
            do {
                let (data, response) = try await downloadSubscription(from: url)
                let name = subscriptionName(from: response) ?? url.host ?? "订阅配置"
                try installProfile(data: data, name: name, remoteURL: url.absoluteString, response: response)
            } catch { presentError("添加订阅失败", error) }
        }
    }

    func importLocalProfile() {
        let panel = NSOpenPanel()
        panel.title = "选择 Mihomo / Clash 配置"
        panel.allowedContentTypes = [.data, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try installProfile(data: data, name: url.deletingPathExtension().lastPathComponent, remoteURL: nil, response: nil)
        } catch { presentError("导入配置失败", error) }
    }

    func updateProfile(_ profile: Profile) {
        guard let remote = profile.remoteURL, let url = URL(string: remote) else {
            showToast("本地配置没有远程更新地址")
            return
        }
        Task {
            do {
                let (data, response) = try await downloadSubscription(from: url, profileID: profile.id)
                try replaceProfile(profile, with: data, response: response)
                markSubscriptionUpdated(profileID: profile.id, response: response)
                showToast("“\(profile.name)”已更新")
                if profile.id == activeProfileID { await startCore() }
            } catch { presentError("更新订阅失败", error) }
        }
    }

    func installProfile(data: Data, name: String, remoteURL: String?, response: HTTPURLResponse?) throws {
        guard data.count < 20_000_000 else { throw AeroRuntimeError.commandFailed("配置文件超过 20 MB") }
        try repository.prepare()
        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).yaml"
        let destination = repository.profilesDirectory.appendingPathComponent(fileName)
        let temporary = repository.root.appendingPathComponent("import-\(id).yaml")
        let prepared = try SubscriptionFormatter.prepare(data: data, id: id)
        var installedProviderURL: URL?
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed {
                try? FileManager.default.removeItem(at: destination)
                if let installedProviderURL { try? FileManager.default.removeItem(at: installedProviderURL) }
            }
        }
        try prepared.configData.write(to: temporary, options: .atomic)
        if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
            let providerURL = repository.providersDirectory.appendingPathComponent(providerFileName)
            try providerData.write(to: providerURL, options: .atomic)
            try secureFile(at: providerURL)
            installedProviderURL = providerURL
        }
        guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
        try repository.validate(configURL: temporary, coreURL: coreURL)
        try prepared.configData.write(to: destination, options: .atomic)
        try secureFile(at: destination)
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let source = remoteURL == nil ? "\(prepared.label) · 本地配置" : "\(prepared.label) · 远程订阅"
        let profile = Profile(id: id, name: name, source: source, updated: "刚刚更新", size: size, fileName: fileName, remoteURL: remoteURL, format: prepared.label, payloadFileName: prepared.providerFileName)
        let updatedProfiles = profiles + [profile]
        try repository.saveProfiles(updatedProfiles)
        profiles = updatedProfiles
        if let response { markSubscriptionUpdated(profileID: id, response: response) }
        committed = true
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: "activeProfileID")
        Task { await startCore() }
        let nodeSummary = prepared.nodeCount.map { " · \($0) 个节点" } ?? ""
        showToast("配置校验通过并已导入\(nodeSummary)")
    }

    func replaceProfile(_ profile: Profile, with data: Data, response: HTTPURLResponse) throws {
        guard data.count < 20_000_000 else { throw AeroRuntimeError.commandFailed("配置文件超过 20 MB") }
        try repository.prepare()
        let prepared = try SubscriptionFormatter.prepare(data: data, id: profile.id)
        let destination = repository.fileURL(for: profile)
        let temporary = repository.root.appendingPathComponent("update-\(UUID().uuidString).yaml")
        let previousConfig = try Data(contentsOf: destination)
        let oldProviderURL = profile.payloadFileName.map { repository.providersDirectory.appendingPathComponent($0) }
        let previousProvider = oldProviderURL.flatMap { try? Data(contentsOf: $0) }
        var newProviderURL: URL?
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed {
                try? previousConfig.write(to: destination, options: .atomic)
                if let newProviderURL {
                    if newProviderURL == oldProviderURL, let previousProvider {
                        try? previousProvider.write(to: newProviderURL, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: newProviderURL)
                    }
                }
            }
        }

        try repository.backup(profile)
        try prepared.configData.write(to: temporary, options: .atomic)
        if let providerData = prepared.providerData, let providerFileName = prepared.providerFileName {
            let providerURL = repository.providersDirectory.appendingPathComponent(providerFileName)
            try providerData.write(to: providerURL, options: .atomic)
            try secureFile(at: providerURL)
            newProviderURL = providerURL
        }
        guard let coreURL = Bundle.main.url(forResource: "mihomo", withExtension: nil) else { throw AeroRuntimeError.missingCore }
        try repository.validate(configURL: temporary, coreURL: coreURL)
        try prepared.configData.write(to: destination, options: .atomic)
        try secureFile(at: destination)

        let displayName = subscriptionName(from: response) ?? profile.name
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let updated = Profile(id: profile.id, name: displayName, source: "\(prepared.label) · 远程订阅", updated: "刚刚更新", size: size, fileName: profile.fileName, remoteURL: profile.remoteURL, format: prepared.label, payloadFileName: prepared.providerFileName)
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw AeroRuntimeError.missingProfile }
        var updatedProfiles = profiles
        updatedProfiles[index] = updated
        try repository.saveProfiles(updatedProfiles)
        profiles = updatedProfiles
        committed = true
        if let oldProviderURL, oldProviderURL != newProviderURL { try? FileManager.default.removeItem(at: oldProviderURL) }
    }

    func downloadSubscription(from url: URL, profileID: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let userAgent = profileID.flatMap { runtimeSettings.subscriptionPreferences[$0]?.userAgent }
        let result = try await SubscriptionDownloader.download(from: url, preferredUserAgent: userAgent)
        recordDiagnostic("subscription-client-profile=\(result.clientProfile)")
        return (result.data, result.response)
    }

    func preference(for profile: Profile) -> SubscriptionPreference {
        runtimeSettings.subscriptionPreferences[profile.id] ?? SubscriptionPreference()
    }

    func usage(for profile: Profile) -> SubscriptionUsage? {
        runtimeSettings.subscriptionUsage[profile.id]
    }

    func editSettings(for profile: Profile) {
        profileBeingEdited = profile
        showProfileSettings = true
    }

    func savePreference(for profile: Profile, intervalHours: Int, userAgent: String) {
        var preference = preference(for: profile)
        preference.updateIntervalHours = min(720, max(1, intervalHours))
        preference.userAgent = String(userAgent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        runtimeSettings.subscriptionPreferences[profile.id] = preference
        try? settingsStore.save(runtimeSettings)
        showToast("订阅更新设置已保存")
    }

    func updateAllSubscriptions(force: Bool = true) {
        guard !subscriptionUpdateInProgress else { return }
        subscriptionUpdateInProgress = true
        Task {
            defer { subscriptionUpdateInProgress = false }
            var updated = 0
            var activeUpdated = false
            for profile in profiles where profile.remoteURL != nil {
                let preference = preference(for: profile)
                let due = preference.lastUpdated.map { Date().timeIntervalSince($0) >= Double(preference.updateIntervalHours * 3600) } ?? true
                guard force || due else { continue }
                guard let remote = profile.remoteURL, let url = URL(string: remote) else { continue }
                do {
                    let (data, response) = try await downloadSubscription(from: url, profileID: profile.id)
                    try replaceProfile(profile, with: data, response: response)
                    markSubscriptionUpdated(profileID: profile.id, response: response)
                    updated += 1
                    if profile.id == activeProfileID { activeUpdated = true }
                } catch {
                    appendLog(level: "WARN", message: "自动更新“\(profile.name)”失败：\(error.localizedDescription)")
                }
            }
            if force { showToast("订阅更新完成 · \(updated) 个") }
            if activeUpdated { await startCore() }
        }
    }

    func markSubscriptionUpdated(profileID: String, response: HTTPURLResponse) {
        var preference = runtimeSettings.subscriptionPreferences[profileID] ?? SubscriptionPreference()
        preference.lastUpdated = Date()
        runtimeSettings.subscriptionPreferences[profileID] = preference
        if let raw = response.value(forHTTPHeaderField: "subscription-userinfo"), let usage = parseSubscriptionUsage(raw) {
            runtimeSettings.subscriptionUsage[profileID] = usage
        }
        try? settingsStore.save(runtimeSettings)
    }

    func parseSubscriptionUsage(_ raw: String) -> SubscriptionUsage? {
        var values: [String: Int64] = [:]
        for component in raw.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if pair.count == 2, let value = Int64(pair[1]) { values[pair[0].lowercased()] = value }
        }
        let used = (values["upload"] ?? 0) + (values["download"] ?? 0)
        let total = values["total"] ?? 0
        guard used > 0 || total > 0 || values["expire"] != nil else { return nil }
        let expiry = values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SubscriptionUsage(usedBytes: used, totalBytes: total, expiresAt: expiry)
    }

    func subscriptionName(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "profile-title")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let decoded = raw.removingPercentEncoding, !decoded.isEmpty { return String(decoded.prefix(80)) }
        return String(raw.prefix(80))
    }

    func secureFile(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func beginEditingActiveYAML() {
        guard let profile = profiles.first(where: { $0.id == activeProfileID }) else { return }
        do {
            editingYAML = try String(contentsOf: repository.fileURL(for: profile), encoding: .utf8)
            showYAMLEditor = true
        } catch { presentError("读取 YAML 失败", error) }
    }

    func saveEditedYAML() {
        guard let profile = profiles.first(where: { $0.id == activeProfileID }),
              let coreURL = Bundle.main.url(forResource: runtimeSettings.coreChannel.resourceName, withExtension: nil) ?? Bundle.main.url(forResource: "mihomo", withExtension: nil) else { return }
        let temporary = repository.root.appendingPathComponent("edited-\(UUID().uuidString).yaml")
        do {
            try editingYAML.write(to: temporary, atomically: true, encoding: .utf8)
            try repository.validate(configURL: temporary, coreURL: coreURL)
            try repository.backup(profile)
            try editingYAML.write(to: repository.fileURL(for: profile), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: temporary)
            showYAMLEditor = false
            Task { await startCore() }
            showToast("YAML 校验通过并已保存")
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            presentError("YAML 校验失败", error)
        }
    }

    /// 快捷面板第一行显示的订阅到期与剩余流量；isUrgent 表示 7 天内到期或流量剩余不足 10%
    var subscriptionSummary: (text: String, isUrgent: Bool)? {
        if let profile = profiles.first(where: { $0.id == activeProfileID }), let usage = usage(for: profile) {
            var parts: [String] = []
            var urgent = false
            if let expiresAt = usage.expiresAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let days = Int((expiresAt.timeIntervalSinceNow / 86_400).rounded(.up))
                parts.append(days > 0 ? "有效期至 \(formatter.string(from: expiresAt))（还有 \(days) 天）" : "已于 \(formatter.string(from: expiresAt)) 到期")
                urgent = days <= 7
            }
            if usage.totalBytes > 0 {
                let remaining = max(0, usage.totalBytes - usage.usedBytes)
                parts.append("剩余 \(ByteCountFormatter.string(fromByteCount: remaining, countStyle: .decimal))")
                if Double(remaining) / Double(usage.totalBytes) <= 0.1 { urgent = true }
            }
            if !parts.isEmpty { return (parts.joined(separator: " · "), urgent) }
        }
        // 订阅没有提供到期信息时，退而使用订阅里的“信息节点”名称，例如“有效期2029-11-09, 剩余85.40 GB”
        let infoNames = proxyGroups.flatMap(\.members).filter { Self.isInfoNodeName($0) }
        if let name = infoNames.first(where: { $0.contains("有效期") || $0.contains("到期") }) ?? infoNames.first {
            return (name, false)
        }
        return nil
    }
}
