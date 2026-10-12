import Foundation

/// Safe fake surfaces used only when CPS_TEST_ROOT is explicitly set. This
/// makes the menu-bar UI automatable without launching or quitting real Claude
/// processes or touching the user's profile directories.
@MainActor
final class TestModeClaudeAppController: ClaudeAppControlling {
    private var running = false
    var isClaudeRunning: Bool { running }

    func quitClaude(timeout: TimeInterval) async -> Bool {
        running = false
        return true
    }

    func locateClaudeBundleURL() -> URL? {
        URL(fileURLWithPath: "/Applications/Claude.app")
    }

    func launchClaude(activate: Bool) async throws {
        running = true
    }
}

struct TestModeSurfaceLocator: SurfaceLocator {
    func desktopAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Claude.app") }
    func cliExecutableURL() async -> URL? { URL(fileURLWithPath: "/usr/bin/true") }
}

struct TestModeClaudeCodeRunner: ClaudeCodeRunning {
    func executableURL() -> URL? { URL(fileURLWithPath: "/usr/bin/true") }
    func authStatus(configDirectory: URL) async throws -> ClaudeCodeAuthStatus {
        ClaudeCodeAuthStatus(loggedIn: false, authMethod: "none", apiProvider: "test")
    }
    func logout(configDirectory: URL?) async throws {}
    func runCommand(_ arguments: [String], configDirectory: URL, timeout: TimeInterval) async throws {}
}
