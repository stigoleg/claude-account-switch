import Foundation
import XCTest

@testable import ClaudeProfileSwitcherCore

/// Helpers shared across test files.
enum TestSupport {
    /// A fresh, isolated tmp directory that is removed when the returned
    /// teardown closure fires. Each test creates one of these so it can never
    /// stomp on real user data.
    static func makeTempDirectory(file: StaticString = #file, line: UInt = #line) throws -> (URL, () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cps-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(at: url)
        }
        return (url, cleanup)
    }

    /// Resolve a fixture file from the Tests/.../Fixtures directory copied into
    /// the test bundle's Resources.
    static func fixtureURL(_ name: String, file: StaticString = #file, line: UInt = #line) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            XCTFail("Fixture \(name) not found in test bundle", file: file, line: line)
            throw NSError(
                domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture: \(name)"])
        }
        return url
    }
}

/// Fixed-answer surface locator for sign-in preflight tests.
struct FixedSurfaceLocator: SurfaceLocator {
    var cliURL: URL?

    func desktopAppURL() -> URL? { nil }
    func cliExecutableURL() async -> URL? { cliURL }
}

/// Fake Claude Desktop controller. Tests MUST use this instead of the real
/// `ClaudeAppController` — the real one terminates (and after a timeout
/// force-kills) any running Claude Desktop app, including the developer's.
@MainActor
final class FakeClaudeAppController: ClaudeAppControlling {
    var isClaudeRunning = false
    var installed = true
    var launchShouldFail = false
    private(set) var quitCalls = 0
    private(set) var launchCalls = 0

    func quitClaude(timeout: TimeInterval) async -> Bool {
        quitCalls += 1
        isClaudeRunning = false
        return true
    }

    func locateClaudeBundleURL() -> URL? {
        installed ? URL(fileURLWithPath: "/Applications/Claude.app") : nil
    }

    func launchClaude(activate: Bool) async throws {
        guard installed else { throw ClaudeAppError.desktopNotInstalled }
        if launchShouldFail { throw ClaudeAppError.launchFailed("injected") }
        launchCalls += 1
        isClaudeRunning = true
    }
}
