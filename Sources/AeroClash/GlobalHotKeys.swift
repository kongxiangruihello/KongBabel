import Foundation
import Carbon

/// KongBabel 的全局快捷键（任何应用在前台时都能使用）。
/// 使用 Carbon 的 RegisterEventHotKey，不需要“辅助功能”权限。
enum KongHotKey: UInt32, CaseIterable, Identifiable {
    case toggleProxy = 1
    case cycleMode = 2
    case fastestNode = 3

    var id: UInt32 { rawValue }

    /// ⌃⌥ 组合较少与其他应用冲突
    static let modifiers = UInt32(controlKey | optionKey)

    var keyCode: UInt32 {
        switch self {
        case .toggleProxy: return UInt32(kVK_ANSI_P)
        case .cycleMode: return UInt32(kVK_ANSI_M)
        case .fastestNode: return UInt32(kVK_ANSI_N)
        }
    }

    var display: String {
        switch self {
        case .toggleProxy: return "⌃⌥P"
        case .cycleMode: return "⌃⌥M"
        case .fastestNode: return "⌃⌥N"
        }
    }

    var title: String {
        switch self {
        case .toggleProxy: return "开关系统代理"
        case .cycleMode: return "切换模式（规则 → 全局 → 直连）"
        case .fastestNode: return "测速并切换到最快节点"
        }
    }
}

@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// 注册快捷键；返回 false 表示该组合已被其他应用占用。
    @discardableResult
    func register(_ key: KongHotKey, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(key)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B42_4C42), id: key.rawValue) // 'KBLB'
        let status = RegisterEventHotKey(key.keyCode, KongHotKey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[key.rawValue] = ref
        handlers[key.rawValue] = handler
        return true
    }

    func unregister(_ key: KongHotKey) {
        if let ref = refs.removeValue(forKey: key.rawValue) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: key.rawValue)
    }

    func unregisterAll() {
        KongHotKey.allCases.forEach(unregister)
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in GlobalHotKeys.shared.fire(id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
