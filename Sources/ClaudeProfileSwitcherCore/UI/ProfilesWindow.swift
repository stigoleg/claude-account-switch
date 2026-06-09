import SwiftUI

public struct ProfilesWindow: View {
    @Bindable var vm: AppViewModel
    @State private var newName: String = ""
    @State private var renaming: Profile?
    @State private var renameText: String = ""
    @State private var confirmDelete: Profile?
    @State private var showAddProfileSheet: Bool = false
    @State private var sheetName: String = ""
    @FocusState private var newProfileFieldFocused: Bool

    public init(vm: AppViewModel) {
        self._vm = Bindable(wrappedValue: vm)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            shellIntegrationSection
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 620)
        .sheet(item: $vm.pendingSignInProfile) { profile in
            SignInPickerView(profile: profile, surfaces: vm.surfaces) { method in
                if let method {
                    vm.signIn(profile, method: method)
                }
                vm.pendingSignInProfile = nil
            }
        }
        .sheet(item: $vm.copyConfigTarget) { profile in
            CopyConfigSheet(vm: vm, target: profile) {
                vm.copyConfigTarget = nil
            }
        }
        .sheet(isPresented: $showAddProfileSheet) {
            AddProfileSheet(
                initialName: sheetName,
                onCreate: { name in
                    vm.createProfile(named: name)
                    showAddProfileSheet = false
                    sheetName = ""
                },
                onCancel: {
                    showAddProfileSheet = false
                    sheetName = ""
                }
            )
        }
        .alert(
            item: Binding(
                get: { vm.lastError.map { ErrorBox(message: $0) } },
                set: { _ in vm.lastError = nil }
            )
        ) { box in
            Alert(
                title: Text("Something went wrong"),
                message: Text(box.message),
                dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.name ?? "")?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { profile in
            Button("Move to Trash", role: .destructive) {
                vm.delete(profile)
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { _ in
            Text("The profile's files will be moved to the Trash — you can restore them from there.")
        }
        .onAppear {
            vm.profilesWindowVisible = true
            vm.refreshLoginStatuses()
            vm.refreshShellIntegrationState()
            vm.surfaces.refreshSoon()
        }
        .onDisappear {
            vm.profilesWindowVisible = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Profiles").font(.title2).bold()
                Text(
                    "One profile per Claude account. Switching swaps the symlinks at ~/.claude and the Claude Desktop support folder."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    sheetName = ""
                    showAddProfileSheet = true
                } label: {
                    Label("New Profile", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("n", modifiers: [.command])

                if vm.store.activeProfile != nil {
                    Menu {
                        Button(role: .destructive) {
                            vm.requestDisableAndRestore()
                        } label: {
                            Label("Disable & Restore Default Layout…", systemImage: "arrow.uturn.backward")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 90, alignment: .trailing)
                    .help("Other operations: restore the default Claude layout.")
                }
            }
        }
        .padding()
    }

    // MARK: - List / empty state

    @ViewBuilder
    private var list: some View {
        if vm.store.profiles.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(vm.store.profiles) { profile in
                        ProfileCardView(
                            vm: vm,
                            profile: profile,
                            isRenaming: renaming?.id == profile.id,
                            renameText: $renameText,
                            beginRename: {
                                renaming = profile
                                renameText = profile.name
                            },
                            commitRename: { commitRename(profile) },
                            cancelRename: {
                                renaming = nil; renameText = ""
                            },
                            requestDelete: { confirmDelete = profile }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No profiles yet")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Create one for each Claude account you want to switch between.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                sheetName = ""
                showAddProfileSheet = true
            } label: {
                Label("Add Your First Profile", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Shell integration

    private var shellIntegrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("Shell integration").font(.headline)
                Spacer()
                shellStatusChip
            }

            Text(
                "Bind a profile to a project so `claude` automatically uses the right account when you're inside that folder."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // How-it-works: tiny three-step explainer with example.
            VStack(alignment: .leading, spacing: 6) {
                howStep(number: "1", text: "Install the integration below — adds a zsh function.")
                howStep(
                    number: "2",
                    text: "Drop a `.claude-profile` file in any project with the profile name as the first line.")
                howStep(
                    number: "3",
                    text:
                        "Run `claude` from anywhere inside that project — uses the bound profile, isolated per-keychain."
                )
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )

            HStack(spacing: 8) {
                if vm.shellIntegrationInstalled {
                    Button(role: .destructive) {
                        vm.uninstallShellIntegration()
                    } label: {
                        Label("Uninstall", systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        vm.installShellIntegration()
                    } label: {
                        Label("Install", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    vm.revealShellFunctionInFinder()
                } label: {
                    Label("Reveal File", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            // Desktop hint — separate row with explanation under it. The
            // earlier inline checkbox was too cramped to communicate intent.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $vm.desktopHintsEnabled) {
                    Label("Suggest Desktop switches", systemImage: "bell.badge")
                }
                .toggleStyle(.switch)
                Text(
                    "Show a macOS notification offering to switch Claude Desktop too when you enter a project bound to a different profile. The CLI binding works regardless of this setting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .padding()
    }

    private func howStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption2).fontWeight(.bold)
                .frame(width: 16, height: 16)
                .background(Color.accentColor.opacity(0.18), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(.init(text))  // markdown for the inline code
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shellStatusChip: some View {
        let installed = vm.shellIntegrationInstalled
        return HStack(spacing: 4) {
            Image(systemName: installed ? "checkmark.seal.fill" : "circle.dashed")
                .foregroundStyle(installed ? Color.green : Color.secondary)
            Text(installed ? "Installed" : "Not installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(
            Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
        )
    }

    // MARK: - Footer (quick create)

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("Quick add — type a profile name and press Return", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($newProfileFieldFocused)
                .onSubmit { commitCreate() }
            Button("Add") { commitCreate() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Actions

    private func commitCreate() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        vm.createProfile(named: name)
        newName = ""
    }

    private func commitRename(_ profile: Profile) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        vm.rename(profile, to: name)
        renaming = nil
        renameText = ""
    }
}

// MARK: - Add Profile Sheet

private struct AddProfileSheet: View {
    let initialName: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = ""
    @FocusState private var fieldFocused: Bool

    init(initialName: String, onCreate: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.onCreate = onCreate
        self.onCancel = onCancel
        self._name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("New Claude Profile").font(.title2).bold()
            }
            Text(
                "Give your new profile a short name — typically the account purpose like \"work\" or \"personal\". You'll be prompted to sign in next."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create + Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        onCreate(n)
    }
}

// MARK: - Profile Card

private struct ProfileCardView: View {
    @Bindable var vm: AppViewModel
    let profile: Profile
    let isRenaming: Bool
    @Binding var renameText: String
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void
    let requestDelete: () -> Void

    @State private var showColorPicker = false

    private var status: ProfileLoginStatus { vm.status(for: profile) }
    private var isActive: Bool { profile.id == vm.store.activeProfileID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            statusRow
            actionRow
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isActive ? profile.color.opacity(0.7) : Color.secondary.opacity(0.15),
                    lineWidth: isActive ? 2 : 1)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button {
                showColorPicker = true
            } label: {
                Circle()
                    .fill(profile.color)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Change color")
            .popover(isPresented: $showColorPicker, arrowEdge: .top) {
                ColorPickerPopover(currentHex: profile.colorHex) { hex in
                    vm.setColor(profile, hex: hex)
                }
            }

            if isRenaming {
                TextField("Name", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Button("Save", action: commitRename)
                Button("Cancel", action: cancelRename)
            } else {
                Text(profile.name).font(.title3).fontWeight(.semibold)
                if isActive {
                    Text("Active")
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(profile.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(profile.color)
                }
            }

            Spacer()

            if !isRenaming {
                Menu {
                    Button("Rename", action: beginRename)
                    Button("Reveal in Finder") {
                        let url = vm.store.profileDirectory(profile)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Copy Config From…") {
                        vm.copyConfigTarget = profile
                    }
                    .disabled(vm.store.profiles.count < 2 || vm.isSwitching)
                    Divider()
                    Button("Delete…", role: .destructive, action: requestDelete)
                        .disabled(isActive)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 18) {
            statusPill(label: "Desktop", surface: status.desktop)
            statusPill(label: "CLI", surface: status.cli)
            Spacer()
        }
    }

    private func statusPill(label: String, surface: SurfaceStatus) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch surface.state {
            case .signedIn: return ("checkmark.circle.fill", .green, "Signed in")
            case .unknown: return ("questionmark.circle.fill", .orange, "Can't verify")
            case .signedOut: return ("xmark.circle", .secondary, "Not signed in")
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption).fontWeight(.medium)
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(surface.note ?? text)
    }

    // The action row: Switch is the dominant CTA when this isn't the active
    // profile. Sign-in / sign-out are secondary actions.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !isActive {
                    Button {
                        vm.requestSwitch(to: profile)
                    } label: {
                        Label("Switch to this profile", systemImage: "arrow.left.arrow.right")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(profile.color)
                    .disabled(vm.isSwitching)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(profile.color)
                        Text("Currently active")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }

            HStack(spacing: 8) {
                // Default sign-in method follows what's installed: both when
                // both surfaces exist, otherwise the single available one.
                let desktopAvailable = vm.surfaces.desktop != .notInstalled
                let cliAvailable = vm.surfaces.cli != .notInstalled
                let primaryMethod: ProfileManager.SignInMethod =
                    desktopAvailable && cliAvailable ? .both : (desktopAvailable ? .desktop : .cli)

                Button {
                    vm.signIn(profile, method: primaryMethod)
                } label: {
                    Label(
                        status.bothSignedIn ? "Re-sign in" : "Sign in",
                        systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.bordered)
                .disabled(vm.isSwitching || (!desktopAvailable && !cliAvailable))

                Menu {
                    if desktopAvailable {
                        Button("Sign in Desktop only") { vm.signIn(profile, method: .desktop) }
                    }
                    if cliAvailable {
                        Button("Sign in CLI only") { vm.signIn(profile, method: .cli) }
                    }
                    Divider()
                    if status.desktop.isSignedIn {
                        Button("Sign out Desktop only", role: .destructive) {
                            vm.signOut(profile, surfaces: [.desktop])
                        }
                    }
                    if status.cli.isSignedIn {
                        Button("Sign out CLI only", role: .destructive) {
                            vm.signOut(profile, surfaces: [.cli])
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .disabled(vm.isSwitching)

                Spacer()

                if status.anySignedIn {
                    Button(role: .destructive) {
                        vm.signOut(profile)
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isSwitching)
                }
            }
            .controlSize(.regular)

            if vm.signingInProfileID == profile.id, let text = vm.signInStatusText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                    if let started = vm.signInStartedAt {
                        Text(started, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Button("Cancel") { vm.cancelSignIn() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }

            if let failure = vm.signInFailure, failure.profileID == profile.id {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Retry") {
                        vm.signInFailure = nil
                        vm.signIn(profile, method: failure.method)
                    }
                    .controlSize(.small)
                    Button("Dismiss") { vm.signInFailure = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct ErrorBox: Identifiable {
    let id = UUID()
    let message: String
}
