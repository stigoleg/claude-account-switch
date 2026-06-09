import SwiftUI

/// Three-step sheet for copying configuration (MCP servers, plugins, skills,
/// settings) from another profile into `target`:
/// configure → review (with per-conflict resolution) → done.
public struct CopyConfigSheet: View {
    @Bindable var vm: AppViewModel
    public let target: Profile
    public let onDone: () -> Void

    private enum Step {
        case configure
        case review(CopyPlan)
        case done(CopySummary)
    }

    @State private var step: Step = .configure
    @State private var source: Profile?
    @State private var categories: Set<CopyCategory> = []
    @State private var mode: CopyMode = .merge
    @State private var resolutions: [CopyItem.ID: ConflictResolution] = [:]
    @State private var isWorking = false
    @State private var errorMessage: String?

    public init(vm: AppViewModel, target: Profile, onDone: @escaping () -> Void) {
        self._vm = Bindable(wrappedValue: vm)
        self.target = target
        self.onDone = onDone
    }

    private var sourceCandidates: [Profile] {
        vm.store.profiles.filter { $0.id != target.id }
    }

    private var availability: Set<CopyCategory> {
        guard let source else { return [] }
        return vm.manager.copyConfigAvailability(source: source)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .configure: configureStep
            case .review(let plan): reviewStep(plan)
            case .done(let summary): doneStep(summary)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: - Step 1: configure

    @ViewBuilder
    private var configureStep: some View {
        Text("Copy configuration into “\(target.name)”").font(.title2).bold()
        Text("Pick the profile to copy from and what to bring over. Sign-in state and credentials are never copied.")
            .foregroundStyle(.secondary)

        Picker("From profile", selection: $source) {
            Text("Choose…").tag(Profile?.none)
            ForEach(sourceCandidates) { profile in
                Text(profile.name).tag(Profile?.some(profile))
            }
        }
        .onChange(of: source) { _, _ in
            // Sensible defaults: everything available except settings.json
            // (permissions/hooks are the most surprising silent overwrite).
            categories = availability.subtracting([.cliSettings])
        }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(CopyCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(
                        category.displayName,
                        isOn: Binding(
                            get: { categories.contains(category) },
                            set: { on in
                                if on { categories.insert(category) } else { categories.remove(category) }
                            }
                        )
                    )
                    .disabled(source == nil || !availability.contains(category))
                    Text(category.explanation)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
        }

        Picker("Mode", selection: $mode) {
            Text("Merge").tag(CopyMode.merge)
            Text("Overwrite").tag(CopyMode.overwrite)
        }
        .pickerStyle(.segmented)
        Text(
            mode == .merge
                ? "Merge adds what's missing; when both profiles have the same item you choose per item which wins."
                : "Overwrite replaces the selected categories in “\(target.name)”. Replaced items are moved to the Trash and can be restored."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if let errorMessage {
            errorRow(errorMessage)
        }

        HStack {
            Spacer()
            Button("Cancel") { onDone() }
            Button("Continue") { runPlan() }
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || categories.isEmpty || isWorking)
        }
    }

    private func runPlan() {
        guard let source else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let plan = try vm.planConfigCopy(
                from: source, to: target, categories: categories, mode: mode)
            // Default every conflict to "use source" — the user is copying
            // FROM that profile because it's the configured one.
            resolutions = Dictionary(
                uniqueKeysWithValues: plan.allConflicts.map { ($0.id, ConflictResolution.useSource) })
            step = .review(plan)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Step 2: review

    @ViewBuilder
    private func reviewStep(_ plan: CopyPlan) -> some View {
        Text("Review copy into “\(target.name)”").font(.title2).bold()

        VStack(alignment: .leading, spacing: 4) {
            ForEach(plan.categories, id: \.category) { categoryPlan in
                HStack(spacing: 6) {
                    Text(categoryPlan.category.displayName).fontWeight(.medium)
                    Spacer()
                    Text(summaryLine(categoryPlan, mode: plan.mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if plan.mode == .merge, !plan.allConflicts.isEmpty {
            Divider()
            HStack {
                Text("\(plan.allConflicts.count) conflict(s) — choose which side wins:")
                    .font(.callout).fontWeight(.medium)
                Spacer()
                Button("Use source for all") {
                    for conflict in plan.allConflicts { resolutions[conflict.id] = .useSource }
                }
                .controlSize(.small)
                Button("Use target for all") {
                    for conflict in plan.allConflicts { resolutions[conflict.id] = .keepTarget }
                }
                .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.allConflicts) { conflict in
                        conflictRow(conflict)
                    }
                }
            }
            .frame(maxHeight: 220)
        }

        if plan.isEmpty {
            Label("Nothing to copy — everything selected is already identical.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }

        if shouldWarnDesktopQuit(plan) {
            Label(
                "Claude Desktop will be quit before copying — unsaved work in the active conversation may be lost.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        if let errorMessage {
            errorRow(errorMessage)
        }

        HStack {
            Button("Back") {
                errorMessage = nil
                step = .configure
            }
            Spacer()
            Button("Cancel") { onDone() }
            Button("Copy") { runExecute(plan) }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isSwitching || isWorking || plan.isEmpty)
        }
    }

    private func conflictRow(_ conflict: CopyConflict) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conflict.item.displayName).fontWeight(.medium)
            HStack(spacing: 12) {
                Text("Source: \(conflict.sourceDetail)")
                Text("Target: \(conflict.targetDetail)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Picker(
                "",
                selection: Binding(
                    get: { resolutions[conflict.id] ?? .useSource },
                    set: { resolutions[conflict.id] = $0 }
                )
            ) {
                Text("Use “\(source?.name ?? "source")”").tag(ConflictResolution.useSource)
                Text("Keep “\(target.name)”").tag(ConflictResolution.keepTarget)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    private func summaryLine(_ categoryPlan: CopyPlan.CategoryPlan, mode: CopyMode) -> String {
        var parts: [String] = []
        if !categoryPlan.additions.isEmpty { parts.append("\(categoryPlan.additions.count) to copy") }
        if !categoryPlan.conflicts.isEmpty { parts.append("\(categoryPlan.conflicts.count) conflict(s)") }
        if mode == .overwrite, !categoryPlan.replacements.isEmpty {
            parts.append("\(categoryPlan.replacements.count) replaced → Trash")
        }
        if !categoryPlan.identical.isEmpty { parts.append("\(categoryPlan.identical.count) unchanged") }
        return parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
    }

    private func shouldWarnDesktopQuit(_ plan: CopyPlan) -> Bool {
        plan.mutatesDesktop
            && vm.store.activeProfileID == target.id
            && vm.manager.claudeApp.isClaudeRunning
    }

    private func runExecute(_ plan: CopyPlan) {
        guard let source else { return }
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            if let summary = await vm.performConfigCopy(
                plan: plan, resolutions: resolutions, source: source, target: target)
            {
                step = .done(summary)
            }
        }
    }

    // MARK: - Step 3: done

    @ViewBuilder
    private func doneStep(_ summary: CopySummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.title2)
            Text("Copied into “\(target.name)”").font(.title2).bold()
        }
        VStack(alignment: .leading, spacing: 4) {
            summaryCount("Copied", summary.copied.count)
            summaryCount("Kept from target", summary.keptTarget.count)
            summaryCount("Already identical", summary.skippedIdentical.count)
            summaryCount("Moved to Trash", summary.trashed.count)
        }
        .font(.callout)
        HStack {
            Spacer()
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func summaryCount(_ label: String, _ count: Int) -> some View {
        if count > 0 {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text("\(count)").fontWeight(.medium)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
