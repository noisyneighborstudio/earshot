import AppKit
import SwiftUI

enum Theme {
    static let recording = Color(nsColor: .systemRed)
    static let detected = Color(nsColor: .systemGreen)

    /// Foreground colours per speaker; chips use them over a 14% tint. Light/dark pairs keep 4.5:1.
    private static let palette: [Color] = [
        .dynamic(light: 0x8A3E00, dark: 0xFFB27A),  // orange
        .dynamic(light: 0x1C6B35, dark: 0x7FD99A),  // green
        .dynamic(light: 0x5B2C9E, dark: 0xC3A6F2),  // purple
        .dynamic(light: 0x0E6262, dark: 0x7FD6D6),  // teal
        .dynamic(light: 0x9B1E52, dark: 0xF59BC0),  // pink
    ]
    static let me = Color.dynamic(light: 0x0B4FB3, dark: 0x8AB8FF)
    static let unknown = Color.secondary

    static func color(for line: Meeting.Line, participants: [String]) -> Color {
        if line.speaker == .me { return me }
        guard let name = line.name else { return unknown }
        return color(forName: name, participants: participants)
    }

    /// Stable per meeting: participants are sorted, so the same person keeps the same colour.
    static func color(forName name: String, participants: [String]) -> Color {
        if name == "Me" { return me }
        let index = participants.firstIndex(of: name) ?? abs(name.hashValue)
        return palette[index % palette.count]
    }
}

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A rounded label tinted with its own colour, for people and statuses.
struct Chip: View {
    let text: String
    let color: Color
    var bold = false

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(bold ? .semibold : .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct Keycap: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.caption.weight(.semibold))
            .frame(minWidth: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

/// The app icon, so the tray matches the Dock, Finder and notifications.
struct AppGlyph: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Bars that follow a 0...1 level.
struct LevelMeter: View {
    let level: Float
    var color: Color = .accentColor
    private let weights: [CGFloat] = [0.4, 0.7, 1, 0.65, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 16 * CGFloat(level) * weights[i])
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
