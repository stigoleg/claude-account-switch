import XCTest

@testable import ClaudeProfileSwitcherCore

final class SharedConfigServiceTests: XCTestCase {
    private var fm: FileManager { .default }

    /// The repository's SharedConfig directory — the same content build-app.sh bundles.
    private static let repoBundle = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SharedConfig", isDirectory: true)

    private struct Harness {
        let service: SharedConfigService
        let root: URL
        let deployed: URL
        let profileID: UUID
        let cli: URL
        let cleanup: () -> Void

        var settingsURL: URL { cli.appendingPathComponent("settings.json") }
    }

    private func makeHarness() throws -> Harness {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let deployed = root.appendingPathComponent("home/.config/claude-shared", isDirectory: true)
        let id = UUID()
        let cli = profiles.appendingPathComponent("\(id.uuidString)/cli", isDirectory: true)
        try fm.createDirectory(at: cli, withIntermediateDirectories: true)
        let service = SharedConfigService(
            bundleURL: Self.repoBundle,
            deployedURL: deployed,
            profilesDirectory: profiles,
            runner: TestModeClaudeCodeRunner())
        return Harness(service: service, root: root, deployed: deployed, profileID: id, cli: cli, cleanup: cleanup)
    }

    private func writeSettings(_ value: [String: Any], _ h: Harness) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
        try data.write(to: h.settingsURL)
    }

    private func readSettings(_ h: Harness) throws -> [String: Any] {
        let data = try Data(contentsOf: h.settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func linkDestination(_ url: URL) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: url.path)
    }

    private func preToolUse(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]) ?? []
    }

    private func commands(_ entry: [String: Any]) -> [String] {
        ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    private func backups(_ h: Harness, prefix: String) throws -> [String] {
        try fm.contentsOfDirectory(atPath: h.cli.path).filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Install

    func testFreshInstallCreatesLinksAndSettings() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try h.service.install(profileID: h.profileID, yolo: false)

        let shared = h.deployed.path
        XCTAssertEqual(linkDestination(h.cli.appendingPathComponent("CLAUDE.md")), "\(shared)/CLAUDE.md")
        XCTAssertEqual(linkDestination(h.cli.appendingPathComponent("agents")), "\(shared)/agents")
        for skill in h.service.bundledContents().skills {
            XCTAssertEqual(
                linkDestination(h.cli.appendingPathComponent("skills/\(skill)")), "\(shared)/skills/\(skill)")
        }
        XCTAssertTrue(fm.isExecutableFile(atPath: "\(shared)/statusline.sh"))
        XCTAssertTrue(fm.isExecutableFile(atPath: "\(shared)/hooks/pin-subagent-model.sh"))
        XCTAssertEqual(
            try String(contentsOf: h.deployed.appendingPathComponent(".version"), encoding: .utf8)
                .split(separator: "\n").first.map(String.init),
            h.service.bundledVersion)

        let settings = try readSettings(h)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(settings["fallbackModel"] as? [String], ["sonnet"])
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String, "\(shared)/statusline.sh")
        let entries = preToolUse(settings)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["matcher"] as? String, "Agent|Task")
        XCTAssertEqual(entries.first.map(commands), ["bash \(shared)/hooks/pin-subagent-model.sh"])
        XCTAssertNil(settings["permissions"])
        XCTAssertNil(settings["skipDangerousModePermissionPrompt"])
        XCTAssertEqual(h.service.status(profileID: h.profileID), .installed(yolo: false))
    }

    func testReinstallIsIdempotent() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeSettings(["theme": "dark"], h)

        try h.service.install(profileID: h.profileID, yolo: true)
        let first = try Data(contentsOf: h.settingsURL)
        let backupsAfterFirst = try backups(h, prefix: "settings.json.bak-")
        try h.service.install(profileID: h.profileID, yolo: true)

        XCTAssertEqual(try Data(contentsOf: h.settingsURL), first)
        XCTAssertEqual(try backups(h, prefix: "settings.json.bak-"), backupsAfterFirst)
        XCTAssertEqual(backupsAfterFirst.count, 1)
        XCTAssertEqual(preToolUse(try readSettings(h)).count, 1)
    }

    func testPreservesProfileLocalSkillAndForeignHook() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let localSkill = h.cli.appendingPathComponent("skills/my-skill/SKILL.md")
        try fm.createDirectory(at: localSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "local".write(to: localSkill, atomically: true, encoding: .utf8)
        let foreign: [String: Any] = [
            "matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]],
        ]
        try writeSettings(["hooks": ["PreToolUse": [foreign], "Stop": [foreign]]], h)

        try h.service.install(profileID: h.profileID, yolo: false)
        try h.service.install(profileID: h.profileID, yolo: false)

        XCTAssertEqual(try String(contentsOf: localSkill, encoding: .utf8), "local")
        let settings = try readSettings(h)
        let entries = preToolUse(settings)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first.map(commands), ["/usr/local/bin/guard.sh"])
        XCTAssertNotNil((settings["hooks"] as? [String: Any])?["Stop"])
    }

    func testExistingModelIsPreserved() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeSettings(["model": "sonnet"], h)

        try h.service.install(profileID: h.profileID, yolo: false)

        XCTAssertEqual(try readSettings(h)["model"] as? String, "sonnet")
    }

    func testEffortEnvRemovedOtherEnvKept() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeSettings(["env": ["CLAUDE_CODE_EFFORT_LEVEL": "high", "FOO": "bar"]], h)

        try h.service.install(profileID: h.profileID, yolo: false)

        XCTAssertEqual(try readSettings(h)["env"] as? [String: String], ["FOO": "bar"])
    }

    func testYoloOffSetsNoPermissionKeysAndKeepsAllowList() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeSettings(["permissions": ["allow": ["Bash(ls:*)"]]], h)

        try h.service.install(profileID: h.profileID, yolo: false)

        let settings = try readSettings(h)
        XCTAssertEqual(settings["permissions"] as? [String: [String]], ["allow": ["Bash(ls:*)"]])
        XCTAssertNil(settings["skipDangerousModePermissionPrompt"])
    }

    func testYoloOnSetsBothKeys() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeSettings(["permissions": ["allow": ["Bash(ls:*)"]]], h)

        try h.service.install(profileID: h.profileID, yolo: true)

        let settings = try readSettings(h)
        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["defaultMode"] as? String, "bypassPermissions")
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual(settings["skipDangerousModePermissionPrompt"] as? Bool, true)
        XCTAssertEqual(h.service.status(profileID: h.profileID), .installed(yolo: true))

        // nil keeps an explicit opt-in.
        try h.service.install(profileID: h.profileID, yolo: nil)
        XCTAssertEqual(h.service.status(profileID: h.profileID), .installed(yolo: true))

        try h.service.install(profileID: h.profileID, yolo: false)

        let after = try readSettings(h)
        XCTAssertEqual(after["permissions"] as? [String: [String]], ["allow": ["Bash(ls:*)"]])
        XCTAssertNil(after["skipDangerousModePermissionPrompt"])
    }

    func testYoloNilNeverCompletesPartialYolo() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeSettings(["permissions": ["defaultMode": "bypassPermissions"]], h)

        XCTAssertFalse(h.service.isYoloEnabled(profileID: h.profileID))
        try h.service.install(profileID: h.profileID, yolo: nil)

        let settings = try readSettings(h)
        XCTAssertEqual(settings["permissions"] as? [String: String], ["defaultMode": "bypassPermissions"])
        XCTAssertNil(settings["skipDangerousModePermissionPrompt"])
        XCTAssertEqual(h.service.status(profileID: h.profileID), .installed(yolo: false))
    }

    func testHookGroupWithForeignCommandKeepsForeignHook() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let foreignHook: [String: Any] = ["type": "command", "command": "/usr/local/bin/audit.sh"]
        let oldShared: [String: Any] = [
            "type": "command", "command": "bash \(h.deployed.path)/hooks/pin-subagent-model.sh", "timeout": 5,
        ]
        try writeSettings(
            ["hooks": ["PreToolUse": [["matcher": "Agent|Task", "hooks": [foreignHook, oldShared]]]]], h)

        try h.service.install(profileID: h.profileID, yolo: false)

        var entries = preToolUse(try readSettings(h))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["matcher"] as? String, "Agent|Task")
        XCTAssertEqual(
            entries.first.map(commands),
            ["/usr/local/bin/audit.sh", "bash \(h.deployed.path)/hooks/pin-subagent-model.sh"])
        let hooks = try XCTUnwrap(entries.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(hooks[1]["timeout"] as? Int, 10)

        try h.service.uninstall(profileID: h.profileID)

        entries = preToolUse(try readSettings(h))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first.map(commands), ["/usr/local/bin/audit.sh"])
    }

    func testJQLookup() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let jq = h.root.appendingPathComponent("bin/jq")
        try fm.createDirectory(at: jq.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: jq, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
        func service(_ paths: [String]) -> SharedConfigService {
            SharedConfigService(
                bundleURL: Self.repoBundle, deployedURL: h.deployed,
                profilesDirectory: h.root.appendingPathComponent("profiles"),
                runner: TestModeClaudeCodeRunner(), jqSearchPaths: paths)
        }

        XCTAssertNil(service([h.root.appendingPathComponent("missing/jq").path]).jqURL())
        XCTAssertEqual(service(["/nonexistent/jq", jq.path]).jqURL()?.path, jq.path)
        XCTAssertTrue(
            SharedConfigService.defaultJQSearchPaths(environment: ["PATH": "/a:/b"]).suffix(2) == ["/a/jq", "/b/jq"])
    }

    func testConflictingRealClaudeMDRenamedToBackup() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try "mine".write(to: h.cli.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        try h.service.install(profileID: h.profileID, yolo: false)

        let backups = try backups(h, prefix: "CLAUDE.md.backup-")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try String(contentsOf: h.cli.appendingPathComponent(backups[0]), encoding: .utf8), "mine")
        XCTAssertEqual(linkDestination(h.cli.appendingPathComponent("CLAUDE.md")), "\(h.deployed.path)/CLAUDE.md")
    }

    func testInvalidSettingsThrowsAndLeavesFileUnchanged() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let broken = Data("{ \"model\": ".utf8)
        try broken.write(to: h.settingsURL)

        XCTAssertThrowsError(try h.service.install(profileID: h.profileID, yolo: true)) { error in
            guard case SharedConfigError.invalidSettings = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: h.settingsURL), broken)
        XCTAssertNil(linkDestination(h.cli.appendingPathComponent("CLAUDE.md")))
        XCTAssertTrue(try backups(h, prefix: "settings.json.bak-").isEmpty)
    }

    func testDanglingSharedSkillLinkRemoved() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try h.service.install(profileID: h.profileID, yolo: false)
        let stale = h.cli.appendingPathComponent("skills/retired-skill")
        try fm.createSymbolicLink(
            atPath: stale.path, withDestinationPath: h.deployed.appendingPathComponent("skills/retired-skill").path)

        try h.service.install(profileID: h.profileID, yolo: false)

        XCTAssertNil(linkDestination(stale))
    }

    // MARK: - Uninstall

    func testUninstallRemovesOwnedAndKeepsForeign() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let foreign: [String: Any] = [
            "matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]],
        ]
        try writeSettings(["theme": "dark", "hooks": ["PreToolUse": [foreign]]], h)
        let localSkill = h.cli.appendingPathComponent("skills/my-skill", isDirectory: true)
        try fm.createDirectory(at: localSkill, withIntermediateDirectories: true)
        try h.service.install(profileID: h.profileID, yolo: true)

        try h.service.uninstall(profileID: h.profileID)

        XCTAssertNil(linkDestination(h.cli.appendingPathComponent("CLAUDE.md")))
        XCTAssertNil(linkDestination(h.cli.appendingPathComponent("agents")))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: h.cli.appendingPathComponent("skills").path), ["my-skill"])
        let settings = try readSettings(h)
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertNil(settings["fallbackModel"])
        XCTAssertNil(settings["statusLine"])
        XCTAssertNil(settings["permissions"])
        XCTAssertNil(settings["skipDangerousModePermissionPrompt"])
        XCTAssertEqual(preToolUse(settings).map(commands), [["/usr/local/bin/guard.sh"]])
        XCTAssertEqual(h.service.status(profileID: h.profileID), .notInstalled)
    }

    func testUninstallKeepsChangedOwnedValues() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try h.service.install(profileID: h.profileID, yolo: false)
        var settings = try readSettings(h)
        settings["fallbackModel"] = ["haiku"]
        settings["permissions"] = ["defaultMode": "acceptEdits"]
        try writeSettings(settings, h)

        try h.service.uninstall(profileID: h.profileID)

        let after = try readSettings(h)
        XCTAssertEqual(after["fallbackModel"] as? [String], ["haiku"])
        XCTAssertEqual(after["permissions"] as? [String: String], ["defaultMode": "acceptEdits"])
    }

    // MARK: - Deploy and status

    func testDeployDetectsLocalEdits() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try h.service.deploy()
        XCTAssertFalse(h.service.deployedHasLocalEdits())
        XCTAssertEqual(try h.service.deploy(), .unchanged)

        let claudeMD = h.deployed.appendingPathComponent("CLAUDE.md")
        try "edited".write(to: claudeMD, atomically: true, encoding: .utf8)

        XCTAssertTrue(h.service.deployedHasLocalEdits())
        XCTAssertThrowsError(try h.service.deploy()) { error in
            guard case SharedConfigError.localEdits = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertThrowsError(try h.service.install(profileID: h.profileID, yolo: false))
        XCTAssertEqual(try String(contentsOf: claudeMD, encoding: .utf8), "edited")

        let outcome = try h.service.deploy(overwriteLocalEdits: true)
        XCTAssertFalse(h.service.deployedHasLocalEdits())
        XCTAssertNotEqual(try String(contentsOf: claudeMD, encoding: .utf8), "edited")
        let kept = try XCTUnwrap(keptCopy(outcome))
        XCTAssertTrue(kept.lastPathComponent.hasPrefix("claude-shared.backup-"))
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "edited")
    }

    private func keptCopy(_ outcome: SharedConfigDeployOutcome) -> URL? {
        guard case .deployed(let kept) = outcome else { return nil }
        return kept
    }

    func testLegacyCopyWithoutVersionThatDiffersCountsAsLocalEdits() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try fm.createDirectory(at: h.deployed.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "old".write(to: h.deployed.appendingPathComponent("agents/old.md"), atomically: true, encoding: .utf8)

        XCTAssertTrue(h.service.deployedHasLocalEdits())
        XCTAssertThrowsError(try h.service.deploy())
        XCTAssertTrue(fm.fileExists(atPath: h.deployed.appendingPathComponent("agents/old.md").path))

        let kept = try XCTUnwrap(keptCopy(try h.service.deploy(overwriteLocalEdits: true)))

        XCTAssertFalse(fm.fileExists(atPath: h.deployed.appendingPathComponent("agents/old.md").path))
        XCTAssertTrue(fm.fileExists(atPath: h.deployed.appendingPathComponent("agents/implementer.md").path))
        XCTAssertEqual(
            try String(contentsOf: kept.appendingPathComponent("agents/old.md"), encoding: .utf8), "old")
        let siblings = try fm.contentsOfDirectory(atPath: h.deployed.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(siblings, ["claude-shared", kept.lastPathComponent])
    }

    func testLegacyCopyMatchingBundleIsReplacedWithoutBackup() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try fm.createDirectory(at: h.deployed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.repoBundle.appendingPathComponent("claude-shared"), to: h.deployed)

        XCTAssertFalse(h.service.deployedHasLocalEdits())
        XCTAssertEqual(try h.service.deploy(), .deployed(keptPrevious: nil))

        XCTAssertTrue(fm.fileExists(atPath: h.deployed.appendingPathComponent(".version").path))
        let siblings = try fm.contentsOfDirectory(atPath: h.deployed.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["claude-shared"])
    }

    func testStatusTransitions() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        XCTAssertEqual(h.service.status(profileID: h.profileID), .notInstalled)

        try h.service.install(profileID: h.profileID, yolo: false)
        XCTAssertEqual(h.service.status(profileID: h.profileID), .installed(yolo: false))

        // An older deployed copy: the recorded version no longer matches the bundle.
        let versionURL = h.deployed.appendingPathComponent(".version")
        let lines = try String(contentsOf: versionURL, encoding: .utf8).split(separator: "\n")
        try "0000\n\(lines[1])\n".write(to: versionURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(h.service.status(profileID: h.profileID), .outdated)
        XCTAssertFalse(h.service.deployedHasLocalEdits())
        try h.service.install(profileID: h.profileID, yolo: false)
        XCTAssertEqual(h.service.status(profileID: h.profileID), .installed(yolo: false))

        try fm.removeItem(at: h.cli.appendingPathComponent("agents"))
        guard case .broken(let problems) = h.service.status(profileID: h.profileID) else {
            return XCTFail("expected broken, got \(h.service.status(profileID: h.profileID))")
        }
        XCTAssertTrue(problems.contains { $0.contains("agents") }, "\(problems)")

        try h.service.uninstall(profileID: h.profileID)
        XCTAssertEqual(h.service.status(profileID: h.profileID), .notInstalled)
    }

    func testMissingHookEntryIsBroken() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try h.service.install(profileID: h.profileID, yolo: false)
        var settings = try readSettings(h)
        settings.removeValue(forKey: "hooks")
        try writeSettings(settings, h)

        guard case .broken(let problems) = h.service.status(profileID: h.profileID) else {
            return XCTFail("expected broken")
        }
        XCTAssertTrue(problems.contains { $0.contains("PreToolUse") }, "\(problems)")
    }

    func testUnavailableBundle() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let service = SharedConfigService(
            bundleURL: h.root.appendingPathComponent("missing"),
            deployedURL: h.deployed,
            profilesDirectory: h.root.appendingPathComponent("profiles"),
            runner: TestModeClaudeCodeRunner())

        XCTAssertFalse(service.isAvailable)
        XCTAssertNil(service.bundledVersion)
        XCTAssertThrowsError(try service.install(profileID: h.profileID, yolo: false))
    }

    func testBundledContentsListsAgentsAndSkills() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let contents = h.service.bundledContents()
        XCTAssertEqual(contents.agents, ["code-scout", "doc-researcher", "implementer", "verifier"])
        XCTAssertTrue(contents.skills.contains("deliverable-production"))
    }
}
