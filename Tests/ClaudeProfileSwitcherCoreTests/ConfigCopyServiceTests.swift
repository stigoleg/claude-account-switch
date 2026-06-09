import XCTest

@testable import ClaudeProfileSwitcherCore

/// Captures trash calls while actually moving items out of the way (into a
/// tmp "trash" dir), so post-conditions are assertable AND the item really
/// leaves the target. Can inject a failure on the Nth call.
private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let trashDir: URL
    private var _urls: [URL] = []
    private var calls = 0
    var failOnCall: Int?

    init(trashDir: URL) {
        self.trashDir = trashDir
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _urls
    }

    func closure() -> @Sendable (URL) throws -> Void {
        { [weak self] url in
            guard let self else { return }
            self.lock.lock()
            self.calls += 1
            let shouldFail = self.calls == self.failOnCall
            if !shouldFail { self._urls.append(url) }
            self.lock.unlock()
            if shouldFail {
                throw NSError(
                    domain: "TrashRecorder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "injected trash failure"])
            }
            let dest = self.trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
        }
    }
}

final class ConfigCopyServiceTests: XCTestCase {
    private var fm: FileManager { .default }

    private struct Harness {
        let svc: ConfigCopyService
        let srcCLI: URL
        let srcDesk: URL
        let tgtCLI: URL
        let tgtDesk: URL
        let trashed: TrashRecorder
        let cleanup: () -> Void
    }

    private func makeHarness() throws -> Harness {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        let recorder = TrashRecorder(trashDir: tmp.appendingPathComponent("trash"))
        let dirs = ["src/cli", "src/desktop", "tgt/cli", "tgt/desktop"].map {
            tmp.appendingPathComponent($0, isDirectory: true)
        }
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Harness(
            svc: ConfigCopyService(trash: recorder.closure()),
            srcCLI: dirs[0], srcDesk: dirs[1], tgtCLI: dirs[2], tgtDesk: dirs[3],
            trashed: recorder, cleanup: cleanup)
    }

    private func writeJSON(_ dict: [String: Any], to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func plan(
        _ h: Harness, categories: Set<CopyCategory>, mode: CopyMode
    ) throws -> CopyPlan {
        try h.svc.plan(
            sourceCLI: h.srcCLI, sourceDesktop: h.srcDesk,
            targetCLI: h.tgtCLI, targetDesktop: h.tgtDesk,
            categories: categories, mode: mode)
    }

    private func categoryPlan(_ plan: CopyPlan, _ category: CopyCategory) throws -> CopyPlan.CategoryPlan {
        try XCTUnwrap(plan.categories.first { $0.category == category })
    }

    // MARK: - Availability

    func testAvailabilityFlipsPerCategory() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        XCTAssertTrue(h.svc.availableCategories(sourceCLI: h.srcCLI, sourceDesktop: h.srcDesk).isEmpty)

        try writeJSON(
            ["mcpServers": ["github": ["command": "npx"]]],
            to: h.srcCLI.appendingPathComponent(".claude.json"))
        try write("plugin", to: h.srcCLI.appendingPathComponent("plugins/installed_plugins.json"))
        try write("skill", to: h.srcCLI.appendingPathComponent("skills/pdf/SKILL.md"))
        try write("{}", to: h.srcCLI.appendingPathComponent("settings.json"))
        try writeJSON([:], to: h.srcDesk.appendingPathComponent("claude_desktop_config.json"))
        try write("[]", to: h.srcDesk.appendingPathComponent("extensions-installations.json"))

        let available = h.svc.availableCategories(sourceCLI: h.srcCLI, sourceDesktop: h.srcDesk)
        XCTAssertEqual(available, Set(CopyCategory.allCases))
    }

    func testAvailabilityRequiresNonEmptyMCPServers() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try writeJSON(["mcpServers": [:]], to: h.srcCLI.appendingPathComponent(".claude.json"))
        let available = h.svc.availableCategories(sourceCLI: h.srcCLI, sourceDesktop: h.srcDesk)
        XCTAssertFalse(available.contains(.cliMCPServers))
    }

    // MARK: - Plan classification

    func testPlanClassifiesJSONEntries() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try writeJSON(
            [
                "mcpServers": [
                    "only-in-source": ["command": "a"],
                    "same": ["command": "b"],
                    "differs": ["command": "c1"],
                ]
            ],
            to: h.srcCLI.appendingPathComponent(".claude.json"))
        try writeJSON(
            [
                "mcpServers": [
                    "same": ["command": "b"],
                    "differs": ["command": "c2"],
                    "only-in-target": ["command": "d"],
                ]
            ],
            to: h.tgtCLI.appendingPathComponent(".claude.json"))

        let p = try plan(h, categories: [.cliMCPServers], mode: .merge)
        let cat = try categoryPlan(p, .cliMCPServers)
        XCTAssertEqual(cat.additions.map(\.displayName), ["only-in-source"])
        XCTAssertEqual(cat.conflicts.map(\.item.displayName), ["differs"])
        XCTAssertEqual(cat.identical.map(\.displayName), ["same"])
        XCTAssertTrue(cat.replacements.isEmpty)
        // Conflict details are value-redacted: keys only, never values.
        XCTAssertEqual(cat.conflicts[0].sourceDetail, "keys: command")
        XCTAssertFalse(cat.conflicts[0].sourceDetail.contains("c1"))
    }

    func testPlanClassifiesDirectoryItems() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try write("new", to: h.srcCLI.appendingPathComponent("skills/new-skill/SKILL.md"))
        try write("same", to: h.srcCLI.appendingPathComponent("commands/same.md"))
        try write("same", to: h.tgtCLI.appendingPathComponent("commands/same.md"))
        try write("v1", to: h.srcCLI.appendingPathComponent("agents/helper.md"))
        try write("v2", to: h.tgtCLI.appendingPathComponent("agents/helper.md"))
        try write("memo", to: h.srcCLI.appendingPathComponent("CLAUDE.md"))

        let p = try plan(h, categories: [.cliSkillsAndCommands], mode: .merge)
        let cat = try categoryPlan(p, .cliSkillsAndCommands)
        XCTAssertEqual(
            Set(cat.additions.map(\.displayName)), ["skills/new-skill", "CLAUDE.md"])
        XCTAssertEqual(cat.conflicts.map(\.item.displayName), ["agents/helper.md"])
        XCTAssertEqual(cat.identical.map(\.displayName), ["commands/same.md"])
    }

    // MARK: - Merge execution

    func testMergeResolutionsForJSONEntries() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try writeJSON(
            ["mcpServers": ["win": ["command": "source"], "lose": ["command": "source"]]],
            to: h.srcCLI.appendingPathComponent(".claude.json"))
        try writeJSON(
            ["mcpServers": ["win": ["command": "target"], "lose": ["command": "target"]]],
            to: h.tgtCLI.appendingPathComponent(".claude.json"))

        let p = try plan(h, categories: [.cliMCPServers], mode: .merge)
        let resolutions: [CopyItem.ID: ConflictResolution] = [
            "cliMCPServers|win": .useSource,
            "cliMCPServers|lose": .keepTarget,
        ]
        let summary = try h.svc.execute(p, resolutions: resolutions)

        let servers = try XCTUnwrap(
            readJSON(h.tgtCLI.appendingPathComponent(".claude.json"))["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["win"] as? [String: Any])?["command"] as? String, "source")
        XCTAssertEqual((servers["lose"] as? [String: Any])?["command"] as? String, "target")
        XCTAssertEqual(summary.copied.map(\.displayName), ["win"])
        XCTAssertEqual(summary.keptTarget.map(\.displayName), ["lose"])
    }

    func testMergeResolutionsForDirectoryItems() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try write("source", to: h.srcCLI.appendingPathComponent("skills/win/SKILL.md"))
        try write("target", to: h.tgtCLI.appendingPathComponent("skills/win/SKILL.md"))
        try write("source", to: h.srcCLI.appendingPathComponent("skills/lose/SKILL.md"))
        try write("target", to: h.tgtCLI.appendingPathComponent("skills/lose/SKILL.md"))
        try write("added", to: h.srcCLI.appendingPathComponent("skills/added/SKILL.md"))

        let p = try plan(h, categories: [.cliSkillsAndCommands], mode: .merge)
        let summary = try h.svc.execute(
            p,
            resolutions: [
                "cliSkillsAndCommands|skills/win": .useSource,
                "cliSkillsAndCommands|skills/lose": .keepTarget,
            ])

        XCTAssertEqual(
            try String(contentsOf: h.tgtCLI.appendingPathComponent("skills/win/SKILL.md"), encoding: .utf8),
            "source")
        XCTAssertEqual(
            try String(contentsOf: h.tgtCLI.appendingPathComponent("skills/lose/SKILL.md"), encoding: .utf8),
            "target")
        XCTAssertEqual(
            try String(contentsOf: h.tgtCLI.appendingPathComponent("skills/added/SKILL.md"), encoding: .utf8),
            "added")
        // The replaced "win" went to the Trash (recoverable), not into the void.
        XCTAssertTrue(h.trashed.urls.contains { $0.path.hasSuffix("skills/win") })
        XCTAssertEqual(Set(summary.copied.map(\.displayName)), ["skills/win", "skills/added"])
    }

    // MARK: - Identity keys & credentials

    func testClaudeJSONIdentityKeysPreserved() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try writeJSON(
            [
                "mcpServers": ["github": ["command": "source"]],
                "oauthAccount": ["email": "source@example.com"],
            ],
            to: h.srcCLI.appendingPathComponent(".claude.json"))
        try writeJSON(
            [
                "mcpServers": ["old": ["command": "target"]],
                "oauthAccount": ["email": "target@example.com"],
                "userID": "target-user",
                "projects": ["/tmp/x": ["history": []]],
            ],
            to: h.tgtCLI.appendingPathComponent(".claude.json"))

        for mode in [CopyMode.merge, .overwrite] {
            let p = try plan(h, categories: [.cliMCPServers], mode: mode)
            _ = try h.svc.execute(p, resolutions: [:])

            let result = try readJSON(h.tgtCLI.appendingPathComponent(".claude.json"))
            XCTAssertEqual(
                (result["oauthAccount"] as? [String: Any])?["email"] as? String,
                "target@example.com", "identity keys must never be copied (mode \(mode))")
            XCTAssertEqual(result["userID"] as? String, "target-user")
            XCTAssertNotNil(result["projects"], "projects must survive the merge")
            let servers = try XCTUnwrap(result["mcpServers"] as? [String: Any])
            XCTAssertNotNil(servers["github"])
            if mode == .overwrite {
                XCTAssertNil(servers["old"], "overwrite replaces the whole mcpServers dict")
            } else {
                XCTAssertNotNil(servers["old"], "merge keeps target-only entries")
            }
        }
    }

    func testCredentialsNeverTouched() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        // Source side: credentials + history that must never travel.
        try write("SOURCE-SECRET", to: h.srcCLI.appendingPathComponent(".credentials.json"))
        try write("source history", to: h.srcCLI.appendingPathComponent("history.jsonl"))
        try writeJSON(
            ["oauth:tokenCache": "SOURCE-TOKEN"], to: h.srcDesk.appendingPathComponent("config.json"))
        try write("source cookies", to: h.srcDesk.appendingPathComponent("Cookies"))
        // Target originals to compare after.
        try write("TARGET-SECRET", to: h.tgtCLI.appendingPathComponent(".credentials.json"))
        try writeJSON(
            ["oauth:tokenCache": "TARGET-TOKEN"], to: h.tgtDesk.appendingPathComponent("config.json"))
        // Something copyable so the run isn't a no-op.
        try write("skill", to: h.srcCLI.appendingPathComponent("skills/x/SKILL.md"))
        try writeJSON(
            ["mcpServers": ["s": ["command": "x"]], "preferences": ["theme": "dark"]],
            to: h.srcDesk.appendingPathComponent("claude_desktop_config.json"))

        for mode in [CopyMode.merge, .overwrite] {
            let p = try plan(h, categories: Set(CopyCategory.allCases), mode: mode)
            _ = try h.svc.execute(p, resolutions: [:])

            XCTAssertEqual(
                try String(contentsOf: h.tgtCLI.appendingPathComponent(".credentials.json"), encoding: .utf8),
                "TARGET-SECRET", "CLI credentials must be untouched (mode \(mode))")
            let config = try readJSON(h.tgtDesk.appendingPathComponent("config.json"))
            XCTAssertEqual(config["oauth:tokenCache"] as? String, "TARGET-TOKEN")
            XCTAssertFalse(
                fm.fileExists(atPath: h.tgtCLI.appendingPathComponent("history.jsonl").path),
                "history must not be copied")
            XCTAssertFalse(
                fm.fileExists(atPath: h.tgtDesk.appendingPathComponent("Cookies").path),
                "cookies must not be copied")
        }
    }

    // MARK: - Overwrite

    func testOverwriteTrashesReplacedItemsAndMirrorsSource() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try write("source", to: h.srcCLI.appendingPathComponent("skills/keep/SKILL.md"))
        try write("target-old", to: h.tgtCLI.appendingPathComponent("skills/keep/SKILL.md"))
        try write("target-only", to: h.tgtCLI.appendingPathComponent("skills/orphan/SKILL.md"))

        let p = try plan(h, categories: [.cliSkillsAndCommands], mode: .overwrite)
        let cat = try categoryPlan(p, .cliSkillsAndCommands)
        XCTAssertEqual(
            Set(cat.replacements.map(\.displayName)), ["skills/keep", "skills/orphan"])

        let summary = try h.svc.execute(p, resolutions: [:])

        XCTAssertEqual(
            try String(contentsOf: h.tgtCLI.appendingPathComponent("skills/keep/SKILL.md"), encoding: .utf8),
            "source")
        XCTAssertFalse(
            fm.fileExists(atPath: h.tgtCLI.appendingPathComponent("skills/orphan").path),
            "target-only items are removed in overwrite so the category mirrors the source")
        XCTAssertEqual(h.trashed.urls.count, 2)
        XCTAssertEqual(summary.trashed.count, 2)
    }

    // MARK: - Wholesale composites

    func testPluginsWholesaleConflictAndCacheExcluded() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try write("v1", to: h.srcCLI.appendingPathComponent("plugins/installed_plugins.json"))
        try write("v1", to: h.tgtCLI.appendingPathComponent("plugins/installed_plugins.json"))
        // Only the (excluded) cache differs → identical.
        try write("source-cache", to: h.srcCLI.appendingPathComponent("plugins/cache/x.json"))
        try write("target-cache", to: h.tgtCLI.appendingPathComponent("plugins/cache/x.json"))

        var p = try plan(h, categories: [.cliPlugins], mode: .merge)
        var cat = try categoryPlan(p, .cliPlugins)
        XCTAssertEqual(cat.identical.count, 1, "cache/ differences alone must classify as identical")
        XCTAssertTrue(cat.conflicts.isEmpty)

        // A real difference produces exactly ONE wholesale conflict.
        try write("v2", to: h.srcCLI.appendingPathComponent("plugins/data/new-plugin/index.js"))
        p = try plan(h, categories: [.cliPlugins], mode: .merge)
        cat = try categoryPlan(p, .cliPlugins)
        XCTAssertEqual(cat.conflicts.count, 1)
        XCTAssertEqual(cat.conflicts[0].item.displayName, "Plugins")

        // Resolving useSource copies the manifest AND data together.
        let summary = try h.svc.execute(p, resolutions: ["cliPlugins|Plugins": .useSource])
        XCTAssertEqual(summary.copied.map(\.displayName), ["Plugins"])
        XCTAssertTrue(
            fm.fileExists(atPath: h.tgtCLI.appendingPathComponent("plugins/data/new-plugin/index.js").path))
        XCTAssertEqual(
            try String(
                contentsOf: h.tgtCLI.appendingPathComponent("plugins/cache/x.json"), encoding: .utf8),
            "target-cache", "cache/ is never copied")
    }

    // MARK: - Desktop config remainder

    func testJSONRemainderMerge() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try writeJSON(
            [
                "mcpServers": ["s": ["command": "x"]],
                "preferences": ["theme": "dark"],
                "coworkUserFilesPath": "/source/path",
            ],
            to: h.srcDesk.appendingPathComponent("claude_desktop_config.json"))
        try writeJSON(
            [
                "preferences": ["theme": "light"],
                "targetOnlyKey": "kept",
            ],
            to: h.tgtDesk.appendingPathComponent("claude_desktop_config.json"))

        let p = try plan(h, categories: [.desktopMCPAndConfig], mode: .merge)
        let cat = try categoryPlan(p, .desktopMCPAndConfig)
        XCTAssertEqual(cat.additions.map(\.displayName), ["s"])
        XCTAssertEqual(cat.conflicts.map(\.item.displayName), ["Desktop settings"])

        // keepTarget: remainder untouched.
        _ = try h.svc.execute(p, resolutions: ["desktopMCPAndConfig|Desktop settings": .keepTarget])
        var result = try readJSON(h.tgtDesk.appendingPathComponent("claude_desktop_config.json"))
        XCTAssertEqual((result["preferences"] as? [String: Any])?["theme"] as? String, "light")
        XCTAssertNotNil((result["mcpServers"] as? [String: Any])?["s"], "mcp entry still added")

        // useSource: source-wins union; target-only keys survive.
        let p2 = try plan(h, categories: [.desktopMCPAndConfig], mode: .merge)
        _ = try h.svc.execute(p2, resolutions: ["desktopMCPAndConfig|Desktop settings": .useSource])
        result = try readJSON(h.tgtDesk.appendingPathComponent("claude_desktop_config.json"))
        XCTAssertEqual((result["preferences"] as? [String: Any])?["theme"] as? String, "dark")
        XCTAssertEqual(result["coworkUserFilesPath"] as? String, "/source/path")
        XCTAssertEqual(result["targetOnlyKey"] as? String, "kept")
    }

    // MARK: - Edge cases

    func testAbsentCategoriesAreGracefulNoOps() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        let p = try plan(h, categories: Set(CopyCategory.allCases), mode: .merge)
        XCTAssertTrue(p.isEmpty)
        let summary = try h.svc.execute(p, resolutions: [:])
        XCTAssertTrue(summary.copied.isEmpty)
        XCTAssertTrue(summary.trashed.isEmpty)
    }

    func testUnreadableJSONRefusedEarly() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        try write("not json {{{", to: h.tgtCLI.appendingPathComponent(".claude.json"))
        try writeJSON(
            ["mcpServers": ["s": ["command": "x"]]],
            to: h.srcCLI.appendingPathComponent(".claude.json"))

        XCTAssertThrowsError(try plan(h, categories: [.cliMCPServers], mode: .merge)) { error in
            guard case ConfigCopyError.unreadableJSON = error else {
                return XCTFail("expected unreadableJSON, got \(error)")
            }
        }
    }

    func testPartialFailureReportsCompletedWork() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try write("a", to: h.tgtCLI.appendingPathComponent("skills/one/SKILL.md"))
        try write("b", to: h.tgtCLI.appendingPathComponent("skills/two/SKILL.md"))
        // Source has neither → both are target-only replacements in overwrite.
        try write("c", to: h.srcCLI.appendingPathComponent("commands/keep.md"))

        h.trashed.failOnCall = 2

        let p = try plan(h, categories: [.cliSkillsAndCommands], mode: .overwrite)
        do {
            _ = try h.svc.execute(p, resolutions: [:])
            XCTFail("expected partialFailure")
        } catch let ConfigCopyError.partialFailure(completed, failedItem, _) {
            XCTAssertEqual(completed.trashed.count, 1, "the first trash completed")
            XCTAssertTrue(failedItem.displayName.hasPrefix("skills/"))
        }
    }

    func testSourceEqualsTargetRefused() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        XCTAssertThrowsError(
            try h.svc.plan(
                sourceCLI: h.srcCLI, sourceDesktop: h.srcDesk,
                targetCLI: h.srcCLI, targetDesktop: h.srcDesk,
                categories: [.cliSettings], mode: .merge)
        ) { error in
            guard case ConfigCopyError.sourceEqualsTarget = error else {
                return XCTFail("expected sourceEqualsTarget, got \(error)")
            }
        }
    }
}
