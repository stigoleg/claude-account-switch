import SwiftUI

/// "Diagnose & Repair" window: read-only findings grouped by severity, with a
/// per-finding Fix button and a copyable plain-text report for support.
public struct DiagnosticsView: View {
    @Bindable var vm: AppViewModel
    @Environment(\.openWindow) private var openWindow

    public init(vm: AppViewModel) {
        self._vm = Bindable(wrappedValue: vm)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diagnose & Repair").font(.title2).bold()
                Text(
                    "Checks the profile layout, the files Claude Desktop's Cowork VM opens, and the Claude Code shell integration. Checking never changes anything."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            Divider()
            List {
                section("Errors", severity: .error)
                section("Warnings", severity: .warning)
                section("OK", severity: .ok)
            }
            Divider()
            HStack {
                Button("Re-run") { vm.runDiagnostics() }
                Button("Copy Report") { vm.copyDiagnosticsReport() }
                if vm.repairsFolderExists {
                    Button("Reveal Repairs Folder") { vm.revealRepairsFolder() }
                        .help("Folders moved aside by repairs. Delete them once Claude Desktop works again.")
                }
                Spacer()
                Button("Fix All Safe Issues") { vm.applySafeRepairs() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.safeRepairActions.isEmpty || vm.isSwitching)
                    .help("Moves broken Cowork VM folders aside, removes stale links and reinstalls shell integration.")
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { vm.runDiagnostics() }
    }

    @ViewBuilder
    private func section(_ title: String, severity: DiagnosticSeverity) -> some View {
        let findings = vm.diagnosticFindings.filter { $0.severity == severity }
        if !findings.isEmpty {
            Section(title) {
                ForEach(findings) { finding in
                    row(finding)
                }
            }
        }
    }

    private func row(_ finding: DiagnosticFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(finding.severity)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).bold()
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let repair = finding.repair {
                Button(repair.title) { fix(repair) }
                    .disabled(vm.isSwitching)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ severity: DiagnosticSeverity) -> some View {
        switch severity {
        case .error:
            return Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning:
            return Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ok:
            return Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func fix(_ repair: RepairAction) {
        guard repair == .runMigration else {
            vm.applyRepair(repair)
            return
        }
        // Migration has its own sheet on the Profiles window.
        openWindow(id: "profiles")
        vm.showMigrationSheet = true
        NSApp.activate(ignoringOtherApps: true)
    }
}
