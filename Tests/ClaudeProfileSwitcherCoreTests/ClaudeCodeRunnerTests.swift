import XCTest

@testable import ClaudeProfileSwitcherCore

final class ClaudeCodeRunnerTests: XCTestCase {
    func testAuthStatusUsesProfileSpecificConfigDirectory() async throws {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let executable = root.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
              printf '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"%s"}' "$CLAUDE_CONFIG_DIR"
              exit 0
            fi
            printf '%s' "$CLAUDE_CONFIG_DIR" > "$(dirname "$0")/logout-config"
            exit 0
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let config = root.appendingPathComponent("Profile With Spaces/cli")
        let runner = ClaudeCodeRunner(candidates: [executable], timeout: 10)

        let status = try await runner.authStatus(configDirectory: config)
        XCTAssertTrue(status.loggedIn)
        XCTAssertEqual(status.apiProvider, config.path)

        try await runner.logout(configDirectory: config)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("logout-config"), encoding: .utf8),
            config.path)
    }

    func testAuthStatusTerminatesHungClaudeProcess() async throws {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let executable = root.appendingPathComponent("claude")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = ClaudeCodeRunner(candidates: [executable], timeout: 0.1)

        do {
            _ = try await runner.authStatus(configDirectory: root.appendingPathComponent("profile"))
            XCTFail("expected timeout")
        } catch let error as ClaudeCodeRunnerError {
            XCTAssertEqual(error, .timedOut)
        }
    }
}
