import AppKit
import ClaudeProfileSwitcherCore
import SwiftUI

/// Started by `ClaudeProfileSwitcherEntry` unless `--doctor` was passed.
struct ClaudeProfileSwitcherApp: App {
    @State private var vm: AppViewModel
    private let instanceLock: SingleInstanceLock
    private let testMode: Bool

    init() {
        do {
            let environment = ProcessInfo.processInfo.environment
            self.testMode = environment["CPS_TEST_ROOT"] != nil
            let lockURL = environment["CPS_TEST_ROOT"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("support/app.lock")
            }
            self.instanceLock = try SingleInstanceLock(
                lockFileURL: lockURL ?? ProfileStore.supportDirectory.appendingPathComponent("app.lock"))
            self._vm = State(initialValue: AppViewModel())
        } catch {
            if let existing = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.stigole.ClaudeProfileSwitcher"
            ).first(where: { $0.processIdentifier != getpid() }) {
                existing.activate(options: [.activateAllWindows])
            }
            fputs("\(error.localizedDescription)\n", stderr)
            exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(vm: vm)
        } label: {
            menuBarLabel
                .background(TestModeWindowOpener(enabled: testMode))
        }
        .menuBarExtraStyle(.menu)

        Window("Claude Profiles", id: "profiles") {
            ProfilesWindow(vm: vm)
                .sheet(isPresented: $vm.showMigrationSheet) {
                    FirstRunMigrationView(vm: vm)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Strip CMD+Q from app-level menus. The menu bar dropdown still
            // exposes Quit explicitly, but a stray CMD+Q while typing in
            // Manage Profiles won't terminate the whole app any more.
            CommandGroup(replacing: .appTermination) {}
        }

        Window("Diagnose & Repair", id: "diagnostics") {
            DiagnosticsView(vm: vm)
        }
    }

    /// The menu bar status item label. `MenuBarExtra` is picky about its
    /// label content — custom SwiftUI shapes (ZStack of `Circle().fill()`)
    /// often render at zero size or not at all because the status item lays
    /// out an NSImage, not a SwiftUI view. We pre-bake the brand mark to an
    /// `NSImage`. Text alongside it is fine — `MenuBarExtra` renders text
    /// labels reliably.
    @ViewBuilder
    private var menuBarLabel: some View {
        let active = vm.store.activeProfile
        let hex = active?.colorHex
        HStack(spacing: 5) {
            Image(nsImage: ProfileMenuBarIcon.image(forColorHex: hex))
            if vm.diagnosticsHasErrors {
                Text("⚠︎")
                    .font(.system(size: 13, weight: .medium))
                    .help("Issues found — open Diagnose & Repair")
            }
            if let active {
                Text(active.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

private struct TestModeWindowOpener: View {
    let enabled: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                if enabled { openWindow(id: "profiles") }
            }
    }
}

/// Brand-mark renderer for the menu bar status item.
///
/// Echoes the app icon's "two overlapping circles" motif so the menu bar item,
/// Dock icon, and About box all read as the same brand. When a profile is
/// active, the circles are drawn in that profile's color; when no profile is
/// active, they're drawn black and the image is marked as a template so macOS
/// handles dark/light tinting like any other status-item glyph.
@MainActor
enum ProfileMenuBarIcon {
    /// Cache keyed by color hex (or "template" when there's no active
    /// profile). Status-item images are re-fetched on every menu-bar redraw,
    /// so baking them once per profile color matters.
    private static var cache: [String: NSImage] = [:]

    static func image(forColorHex hex: String?) -> NSImage {
        let key = hex ?? "template"
        if let existing = cache[key] { return existing }
        let image = render(hex: hex)
        cache[key] = image
        return image
    }

    /// Standard macOS status item content size.
    private static let canvas = NSSize(width: 18, height: 18)

    private static func render(hex: String?) -> NSImage {
        // For templates we need pure black + alpha so macOS can recolor. For
        // active profiles we paint the chosen color literally.
        let tint: NSColor = hex.flatMap(Self.nsColor(fromHex:)) ?? .black

        // `NSImage(size:flipped:drawingHandler:)` is the modern, Retina-safe
        // way to compose vector artwork into an NSImage. The handler is
        // called whenever the image needs to be rasterized at the current
        // backing scale, so the result stays crisp on any display.
        let image = NSImage(size: canvas, flipped: false) { _ in
            tint.setFill()
            tint.setStroke()

            // Two overlapping circles. y grows up in unflipped coords, so the
            // "upper-left" circle sits at higher y. The 11×11 circles overlap
            // by ~4 pt at the center of an 18×18 canvas, matching the app
            // icon's two-circle motif.

            // Upper-left, filled.
            let filled = NSBezierPath(ovalIn: NSRect(x: 0, y: 7, width: 11, height: 11))
            filled.fill()

            // Lower-right, outlined. We inset by half the line width so the
            // visible diameter matches the filled circle.
            let lineWidth: CGFloat = 1.6
            let outlineRect = NSRect(x: 7, y: 0, width: 11, height: 11)
                .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let outline = NSBezierPath(ovalIn: outlineRect)
            outline.lineWidth = lineWidth
            outline.stroke()

            return true
        }

        // Template = use shape, macOS picks color (dark/light aware).
        // Non-template = render in the literal color we drew.
        image.isTemplate = (hex == nil)
        return image
    }

    private static func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
