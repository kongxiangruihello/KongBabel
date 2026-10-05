import Foundation
import AppKit
import Carbon

/// KongBabel 的全局快捷键（任何应用在前台时都能使用）。
/// 使用 Carbon 的 RegisterEventHotKey，不需要“辅助功能”权限。
enum KongHotKey: UInt32, CaseIterable, Identifiable {
    case toggleProxy = 1
    case cycleMode = 2
    case fastestNode = 3

    var id: UInt32 { rawValue }

    /// 默认使用 ⌃⌥ 组合，较少与其他应用冲突
    static let modifiers = UInt32(controlKey | optionKey)

    var keyCode: UInt32 {
        switch self {
        case .toggleProxy: return UInt32(kVK_ANSI_P)
        case .cycleMode: return UInt32(kVK_ANSI_M)
        case .fastestNode: return UInt32(kVK_ANSI_N)
        }
    }

    /// 默认快捷键的显示文字
    var display: String {
        switch self {
        case .toggleProxy: return "⌃⌥P"
        case .cycleMode: return "⌃⌥M"
        case .fastestNode: return "⌃⌥N"
        }
    }

    var defaultBinding: HotKeyBinding {
        HotKeyBinding(keyCode: keyCode, modifiers: KongHotKey.modifiers, display: display)
    }

    var title: String {
        switch self {
        case .toggleProxy: return "开关系统代理"
        case .cycleMode: return "切换模式（规则 → 全局 → 直连）"
        case .fastestNode: return "测速并切换到最快节点"
        }
    }
}

/// 一个快捷键组合：按键码 + Carbon 修饰键 + 显示文字。
struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    func sameKeys(as other: HotKeyBinding) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// 把 NSEvent 的修饰键转换成 Carbon 修饰键
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// 生成形如 “⌃⌥P” 的显示文字（按 macOS 惯例排序：⌃⌥⇧⌘）
    static func displayString(flags: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyName(keyCode: keyCode, characters: characters)
    }

    static func keyName(keyCode: UInt16, characters: String?) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let name = special[keyCode] { return name }
        let trimmed = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? "键\(keyCode)" : trimmed
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
    func register(_ key: KongHotKey, binding: HotKeyBinding, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(key)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B42_4C42), id: key.rawValue) // 'KBLB'
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
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
