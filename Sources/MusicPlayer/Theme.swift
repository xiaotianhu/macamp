import SwiftUI

enum PlayerTheme {
    static let background = Color(red: 0.09, green: 0.11, blue: 0.10)
    static let panel = Color(red: 0.13, green: 0.16, blue: 0.15)
    static let panelLight = Color(red: 0.20, green: 0.24, blue: 0.22)
    static let line = Color(red: 0.33, green: 0.39, blue: 0.36)
    static let text = Color(red: 0.78, green: 0.83, blue: 0.79)
    static let muted = Color(red: 0.49, green: 0.56, blue: 0.52)
    static let green = Color(red: 0.31, green: 0.98, blue: 0.72)
    static let amber = Color(red: 1.00, green: 0.62, blue: 0.16)
    static let red = Color(red: 0.91, green: 0.30, blue: 0.22)
}

struct Bezel: ViewModifier {
    var radius: CGFloat = 10
    var padding: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(PlayerTheme.panel)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PlayerTheme.line.opacity(0.75), lineWidth: 1)
            )
    }
}

extension View {
    func bezel(radius: CGFloat = 10, padding: CGFloat = 1) -> some View {
        modifier(Bezel(radius: radius, padding: padding))
    }
}
