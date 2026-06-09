import SwiftUI

/// Compact color editor for a profile.
///
/// Shows the six preset colors from `Profile.defaultColors` as clickable
/// swatches, with the currently-selected one highlighted. A `ColorPicker`
/// below provides full custom-color access for anyone who wants a specific
/// shade. Picking either form fires `onPick` with the resulting hex string;
/// the caller persists it.
public struct ColorPickerPopover: View {
    public let currentHex: String
    public let onPick: (String) -> Void

    @State private var custom: Color
    @Environment(\.dismiss) private var dismiss

    public init(currentHex: String, onPick: @escaping (String) -> Void) {
        self.currentHex = currentHex
        self.onPick = onPick
        self._custom = State(initialValue: Color(hex: currentHex) ?? .accentColor)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profile color")
                .font(.headline)

            // Presets grid.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
                ForEach(Profile.defaultColors, id: \.self) { hex in
                    swatch(hex: hex)
                }
            }

            Divider()

            // Custom color row — full system picker.
            HStack {
                Text("Custom").font(.callout)
                Spacer()
                ColorPicker("", selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: custom) { _, newValue in
                        if let hex = newValue.hexString {
                            onPick(hex)
                        }
                    }
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    @ViewBuilder
    private func swatch(hex: String) -> some View {
        let color = Color(hex: hex) ?? .accentColor
        let isSelected = hex.caseInsensitiveCompare(currentHex) == .orderedSame
        Button {
            onPick(hex)
            dismiss()
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 24, height: 24)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(isSelected ? Color.primary.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .help(hex)
    }
}
