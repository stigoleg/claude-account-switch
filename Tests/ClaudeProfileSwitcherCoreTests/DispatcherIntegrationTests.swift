import XCTest

@testable import ClaudeProfileSwitcherCore

final class DispatcherIntegrationTests: XCTestCase {
    private let fm = FileManager.default

    func testProjectBindingPreservesSpacesArgumentsEnvironmentAndExitCode() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let workProfile = Profile(name: "Sopra Steria", aliases: ["old work name"])
        let privateProfile = Profile(name: "Privat")
        try prepareManifest(harness, profiles: [privateProfile, workProfile], active: privateProfile)
        let project = harness.root.appendingPathComponent("project/child", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try "  Sopra Steria  \n".write(
            to: project.deletingLastPathComponent().appendingPathComponent(".claude-profile"),
            atomically: true,
            encoding: .utf8)

        let result = try runDispatcher(
            harness, currentDirectory: project, arguments: ["argument with spaces", "--flag"])

        XCTAssertEqual(result.status, 23)
        let captured = try String(contentsOf: harness.capture, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(String(captured[0]), harness.cliDirectory(workProfile).path)
        XCTAssertEqual(String(captured[1]), "2")
        XCTAssertEqual(String(captured[2]), "argument with spaces")
        XCTAssertEqual(String(captured[3]), "--flag")
    }

    func testTwoConcurrentSessionsReceiveDifferentProfileDirectories() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let first = Profile(name: "Privat")
        let second = Profile(name: "Sopra Steria")
        try prepareManifest(harness, profiles: [first, second], active: first)
        let firstProject = harness.root.appendingPathComponent("first", isDirectory: true)
        let secondProject = harness.root.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondProject, withIntermediateDirectories: true)
        try first.id.uuidString.write(
            to: firstProject.appendingPathComponent(".claude-profile"), atomically: true, encoding: .utf8)
        try "Sopra Steria".write(
            to: secondProject.appendingPathComponent(".claude-profile"), atomically: true, encoding: .utf8)

        let firstCapture = harness.root.appendingPathComponent("first.out")
        let secondCapture = harness.root.appendingPathComponent("second.out")
        let firstProcess = try dispatcherProcess(
            harness, currentDirectory: firstProject, capture: firstCapture, arguments: ["one"])
        let secondProcess = try dispatcherProcess(
            harness, currentDirectory: secondProject, capture: secondCapture, arguments: ["two"])
        firstProcess.waitUntilExit()
        secondProcess.waitUntilExit()

        XCTAssertEqual(firstProcess.terminationStatus, 23)
        XCTAssertEqual(secondProcess.terminationStatus, 23)
        XCTAssertTrue(try String(contentsOf: firstCapture).hasPrefix(harness.cliDirectory(first).path))
        XCTAssertTrue(try String(contentsOf: secondCapture).hasPrefix(harness.cliDirectory(second).path))
    }

    func testMissingProfileDirectoryFailsClosed() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let profile = Profile(name: "Privat")
        try prepareManifest(harness, profiles: [profile], active: profile)
        try fm.removeItem(at: harness.cliDirectory(profile))

        let result = try runDispatcher(harness, currentDirectory: harness.root, arguments: [])

        XCTAssertEqual(result.status, 78)
        XCTAssertTrue(result.stderr.contains("missing or unsafe"))
        XCTAssertFalse(fm.fileExists(atPath: harness.capture.path))
    }

    private struct Harness {
        let root: URL
        let home: URL
        let dispatcher: URL
        let fakeClaude: URL
        let capture: URL
        let cleanup: () -> Void

        func cliDirectory(_ profile: Profile) -> URL {
            root.appendingPathComponent("profiles/\(profile.id.uuidString)/cli", isDirectory: true)
        }
    }

    private func makeHarness() throws -> Harness {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        let dispatcher = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent(".build/debug/ClaudeProfileDispatcher")
        guard fm.isExecutableFile(atPath: dispatcher.path) else {
            cleanup()
            throw XCTSkip("ClaudeProfileDispatcher product is not available at \(dispatcher.path)")
        }
        let fake = root.appendingPathComponent("real-claude")
        let script = """
            #!/bin/sh
            printf '%s\n%s\n%s\n%s\n' "$CLAUDE_CONFIG_DIR" "$#" "$1" "$2" > "$CAPTURE"
            exit 23
            """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return Harness(
            root: root,
            home: home,
            dispatcher: dispatcher,
            fakeClaude: fake,
            capture: root.appendingPathComponent("capture"),
            cleanup: cleanup)
    }

    private func prepareManifest(
        _ harness: Harness,
        profiles: [Profile],
        active: Profile
    ) throws {
        for profile in profiles {
            try fm.createDirectory(at: harness.cliDirectory(profile), withIntermediateDirectories: true)
        }
        let manifest = CLIProfileDispatcherManifest(
            activeProfileID: active.id,
            realClaudePath: harness.fakeClaude.path,
            profiles: profiles.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    aliases: $0.aliases,
                    cliPath: harness.cliDirectory($0).path)
            })
        let url = harness.home.appendingPathComponent(".config/claude-profile-switcher/dispatcher.json")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url)
    }

    private func runDispatcher(
        _ harness: Harness,
        currentDirectory: URL,
        arguments: [String]
    ) throws -> (status: Int32, stderr: String) {
        let process = try dispatcherProcess(
            harness,
            currentDirectory: currentDirectory,
            capture: harness.capture,
            arguments: arguments)
        let stderr = process.standardError as! Pipe
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func dispatcherProcess(
        _ harness: Harness,
        currentDirectory: URL,
        capture: URL,
        arguments: [String]
    ) throws -> Process {
        let process = Process()
        process.executableURL = harness.dispatcher
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = [
            "HOME": harness.home.path,
            "PATH": "/usr/bin:/bin",
            "CAPTURE": capture.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }
}
