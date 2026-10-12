import ClaudeProfileSwitcherCore
import Foundation

/// Handles `--doctor` before SwiftUI starts, so support can ask for a pasted
/// report without launching the menu bar app. Every other launch goes
/// straight to `ClaudeProfileSwitcherApp`.
@main
@MainActor
enum ClaudeProfileSwitcherEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(helpText)
            exit(EXIT_SUCCESS)
        }
        guard arguments.contains("--doctor") else {
            ClaudeProfileSwitcherApp.main()
            return
        }
        exit(DoctorCommand.run(json: arguments.contains("--json"), fix: arguments.contains("--fix")))
    }

    static let helpText = """
        Usage: ClaudeProfileSwitcher [--doctor [--json] [--fix]]

          --doctor    Print a Diagnose & Repair report and exit. Exit status 1 if any
                      error or warning was found, 0 otherwise.
          --json      With --doctor: print the report as JSON.
          --fix       With --doctor: first apply safe repairs (move broken Cowork VM
                      folders aside, remove stale temp links, reinstall shell
                      integration). Folders are not moved while Claude Desktop
                      runs. Never runs the layout migration or reinstalls the
                      shared Claude setup; those need the app. Exit status 2 if
                      the menu bar app is running.
          -h, --help  Show this help.

        Without arguments the menu bar app starts.
        """
}

@MainActor
enum DoctorCommand {
    static func run(json: Bool, fix: Bool) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let service = DiagnosticsService.make(environment: environment)
        var lock: SingleInstanceLock?
        if fix {
            let lockURL =
                environment["CPS_TEST_ROOT"].map {
                    URL(fileURLWithPath: $0).appendingPathComponent("support/app.lock")
                } ?? ProfileStore.supportDirectory.appendingPathComponent("app.lock")
            do {
                lock = try SingleInstanceLock(lockFileURL: lockURL)
            } catch SingleInstanceError.alreadyRunning {
                fputs("Claude Profile Switcher is running — use Diagnose & Repair in the menu bar app.\n", stderr)
                return 2
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 2
            }
            applySafeRepairs(service, log: json ? stderr : stdout)
        }

        let findings = service.run()
        if json {
            do {
                let data = try DiagnosticsService.jsonReport(findings)
                FileHandle.standardOutput.write(data)
                print()
            } catch {
                fputs("Could not encode the report: \(error.localizedDescription)\n", stderr)
                return 1
            }
        } else {
            print(DiagnosticsService.textReport(findings), terminator: "")
        }
        withExtendedLifetime(lock) {}
        return findings.contains { $0.severity != .ok } ? 1 : 0
    }

    private static func applySafeRepairs(_ service: DiagnosticsService, log: UnsafeMutablePointer<FILE>) {
        var applied: Set<RepairAction> = []
        var printed = false
        for finding in service.run() {
            guard let action = finding.repair else { continue }
            if action.needsApp {
                fputs(
                    "Needs the app: \(finding.title) — use Manage Profiles or Diagnose & Repair in the menu bar app.\n",
                    log)
                printed = true
                continue
            }
            guard action.isSafe, applied.insert(action).inserted else { continue }
            do {
                try service.apply(action)
                fputs("Fixed: \(finding.title)\n", log)
            } catch {
                fputs("Not fixed: \(finding.title) — \(error.localizedDescription)\n", log)
            }
        }
        if printed || !applied.isEmpty { fputs("\n", log) }
    }
}
