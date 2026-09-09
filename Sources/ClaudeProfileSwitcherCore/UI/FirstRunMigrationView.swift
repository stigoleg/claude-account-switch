import SwiftUI

public struct FirstRunMigrationView: View {
    @Bindable var vm: AppViewModel

    public init(vm: AppViewModel) {
        self._vm = Bindable(wrappedValue: vm)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Claude Profile Switcher").font(.title2).bold()

            Text(
                "Your existing profiles will be protected by an APFS copy-on-write backup. Claude Desktop will then use a real folder so Cowork can mount it safely. Nothing is deleted."
            )

            VStack(alignment: .leading, spacing: 4) {
                Label("Existing CLI profile folders stay byte-for-byte intact", systemImage: "terminal")
                Label("Claude Desktop symlink → real active profile folder", systemImage: "app.badge")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)

            Text("Quit Claude Desktop before continuing — it caches its config at launch.")
                .font(.callout)
                .foregroundStyle(.orange)

            if vm.isSwitching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Creating and verifying the pre-v2 backup…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = vm.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("migration-error")
            }

            HStack {
                Spacer()
                Button("Later") { vm.showMigrationSheet = false }
                Button("Run Migration") {
                    vm.lastError = nil
                    vm.performMigration()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isSwitching)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
