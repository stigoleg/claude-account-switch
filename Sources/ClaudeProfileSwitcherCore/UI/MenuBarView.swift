import SwiftUI

public struct MenuBarView: View {
    @Bindable var vm: AppViewModel
    @Environment(\.openWindow) private var openWindow

    public init(vm: AppViewModel) {
        self._vm = Bindable(wrappedValue: vm)
    }

    public var body: some View {
        if let active = vm.store.activeProfile {
            Text("Active: \(active.name)")
                .font(.headline)
            Divider()
        } else if !vm.store.profiles.isEmpty {
            Text("No profile active")
            Divider()
        }

        ForEach(vm.store.profiles) { profile in
            Button {
                vm.requestSwitch(to: profile)
            } label: {
                let active = profile.id == vm.store.activeProfileID ? "✓ " : "  "
                let status = vm.status(for: profile)
                let suffix: String = {
                    if status.bothSignedIn { return "" }
                    if status.anySignedIn { return "  ⚠︎ partial" }
                    return "  ✗ not signed in"
                }()
                Text("\(active)\(profile.name)\(suffix)")
            }
            .disabled(vm.isSwitching)
        }

        if vm.store.profiles.isEmpty {
            Text("No profiles yet — create one below.")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("New Profile…") { openProfilesWindow() }
            .keyboardShortcut("n", modifiers: [.command])
            // Menus rebuild their body on every open — piggyback a cheap,
            // TTL-cached availability refresh so the items below stay accurate.
            .onAppear { vm.surfaces.refreshSoon() }
        Button("Manage Profiles…") { openProfilesWindow() }
            .keyboardShortcut(",", modifiers: [.command])

        Divider()

        if vm.surfaces.desktop == .notInstalled {
            Button("Open Claude Desktop (not installed)") {}
                .disabled(true)
        } else {
            Button("Open Claude Desktop") { vm.openClaudeDesktop() }
        }
        Button("Reveal Active Profile in Finder") { vm.revealActiveProfileInFinder() }
            .disabled(vm.store.activeProfile == nil)

        Divider()

        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { vm.launchAtLoginEnabled },
                set: { _ in vm.toggleLaunchAtLogin() }
            ))

        Toggle(
            "Sync profiles via iCloud Drive",
            isOn: Binding(
                get: { vm.syncEnabled },
                set: { vm.syncEnabled = $0 }
            ))

        Divider()

        Button("Disable & Restore Default Layout…") {
            vm.requestDisableAndRestore()
        }
        .disabled(vm.store.activeProfile == nil || vm.isSwitching)

        Button("Quit Claude Profile Switcher") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }

    private func openProfilesWindow() {
        openWindow(id: "profiles")
        NSApp.activate(ignoringOtherApps: true)
    }
}
