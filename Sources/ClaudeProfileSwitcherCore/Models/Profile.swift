import Foundation
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

public struct Profile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public let createdAt: Date
    /// Bumped on every mutation. Used by the iCloud Drive sync layer to resolve
    /// per-profile conflicts (last-writer-wins). Decoded as `.distantPast` when
    /// missing from older on-disk JSON.
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = Profile.defaultColors.randomElement()!,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.colorHex = try c.decode(String.self, forKey: .colorHex)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    public var color: Color { Color(hex: colorHex) ?? .accentColor }

    public static let defaultColors: [String] = [
        "#E07856",  // claude orange
        "#5B8DEF",  // blue
        "#4FB286",  // green
        "#B968C7",  // purple
        "#F2C14E",  // amber
        "#E16B6B",  // red
    ]
}

extension Color {
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// Best-effort conversion to a `#RRGGBB` hex string in sRGB. Returns nil
    /// for colors that don't have an sRGB representation (e.g. some dynamic
    /// system colors).
    public var hexString: String? {
        #if canImport(AppKit)
            let nsColor = NSColor(self)
            guard let converted = nsColor.usingColorSpace(.sRGB) else { return nil }
            let r = Int(round(converted.redComponent * 255))
            let g = Int(round(converted.greenComponent * 255))
            let b = Int(round(converted.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        #else
            return nil
        #endif
    }
}
