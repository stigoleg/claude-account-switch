import SwiftUI

public struct FirstRunMigrationView: View {
    @Bindable var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: AppViewModel) {
        self._vm = Bindable(wrappedValue: vm)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Claude Profile Switcher").font(.title2).bold()

            Text(
                "Your existing Claude data will be moved into a profile named **\"default\"**, and the canonical paths will be replaced with symlinks pointing at it. Nothing is deleted."
            )

            VStack(alignment: .leading, spacing: 4) {
                Label("~/.claude → moved into profile", systemImage: "terminal")
                Label("~/Library/Application Support/Claude → moved into profile", systemImage: "app.badge")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)

            Text("Quit Claude Desktop before continuing — it caches its config at launch.")
                .font(.callout)
                .foregroundStyle(.orange)

            HStack {
                Spacer()
                Button("Later") { dismiss() }
                Button("Run Migration") {
                    vm.performMigration()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
