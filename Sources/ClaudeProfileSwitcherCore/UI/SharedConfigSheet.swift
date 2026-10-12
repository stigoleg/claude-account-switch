import SwiftUI

/// Installs or updates the bundled shared Claude Code setup in one profile.
public struct SharedConfigSheet: View {
    @Bindable var vm: AppViewModel
    public let profile: Profile
    public let onDone: () -> Void

    @State private var yolo: Bool
    private let initialYolo: Bool
    @State private var documentSkills = false

    public init(vm: AppViewModel, profile: Profile, onDone: @escaping () -> Void) {
        self._vm = Bindable(wrappedValue: vm)
        self.profile = profile
        self.onDone = onDone
        let enabled = vm.sharedConfig.isYoloEnabled(profileID: profile.id)
        self.initialYolo = enabled
        self._yolo = State(initialValue: enabled)
    }

    private var isInstalled: Bool { vm.sharedConfigStatus(for: profile) != .notInstalled }

    public var body: some View {
        let contents = vm.sharedConfig.bundledContents()
        VStack(alignment: .leading, spacing: 14) {
            Text(isInstalled ? "Update Shared Claude Setup" : "Install Shared Claude Setup")
                .font(.title2).bold()
            Text("Gives “\(profile.name)” the curated Claude Code setup bundled with this app:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                item("CLAUDE.md", "the shared operating model")
                item("Agents", contents.agents.joined(separator: ", "))
                item("Skills", contents.skills.joined(separator: ", "))
                item("Settings", "status line, fallback model and a hook that pins subagent models")
            }
            .font(.callout)

            Text(
                "Files are linked from \(vm.sharedConfig.deployedURL.path). settings.json is backed up before it changes, and other settings, hooks and profile-local skills are kept."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Bypass permission prompts (yolo)", isOn: $yolo)
                Text(
                    "Claude Code will run tools, edit files and execute commands without asking. Only enable on accounts and machines where you accept that."
                )
                .font(.caption)
                .foregroundStyle(yolo ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            }

            if vm.sharedConfig.jqURL() == nil {
                Label(
                    "jq was not found. The status line and the subagent model hook do nothing without it; install it with `brew install jq`.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Also install Anthropic document skills (docx, pptx, xlsx, pdf)", isOn: $documentSkills)
                .disabled(vm.surfaces.cli == .notInstalled)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(isInstalled ? "Update" : "Install") {
                    // Only an explicit change touches the permission keys.
                    vm.installSharedConfig(
                        profile, yolo: yolo == initialYolo ? nil : yolo, documentSkills: documentSkills)
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isSwitching)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func item(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark").foregroundStyle(.secondary).font(.caption)
            Text(title).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
