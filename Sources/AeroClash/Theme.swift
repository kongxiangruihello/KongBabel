import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import CoreImage.CIFilterBuiltins

enum Theme {
    static let bg = Color(red: 0.955, green: 0.970, blue: 0.985)
    static let sidebar = Color(red: 0.925, green: 0.945, blue: 0.970)
    static let panel = Color.white.opacity(0.92)
    static let panelStrong = Color(red: 0.895, green: 0.920, blue: 0.950)
    static let surfaceMuted = Color(red: 0.930, green: 0.948, blue: 0.968)
    static let stroke = Color(red: 0.74, green: 0.79, blue: 0.86).opacity(0.72)
    static let grid = Color(red: 0.55, green: 0.62, blue: 0.72).opacity(0.20)
    static let text = Color(red: 0.10, green: 0.14, blue: 0.21)
    static let secondary = Color(red: 0.38, green: 0.43, blue: 0.52)
    static let accent = Color(red: 0.08, green: 0.62, blue: 0.45)
    static let accent2 = Color(red: 0.23, green: 0.43, blue: 0.86)
    static let warning = Color(red: 0.84, green: 0.52, blue: 0.08)
    static let danger = Color(red: 0.84, green: 0.23, blue: 0.31)
    static let onAccent = Color.white.opacity(0.96)
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

extension View {
    func card(_ padding: CGFloat = 18) -> some View { modifier(CardModifier(padding: padding)) }
}

// MARK: - App
