import CryptoKit
import Foundation

// MARK: - Model types

/// What can be copied between profiles. Strict allow-list: every category maps
/// to a fixed set of known-safe paths — credential files (`config.json` with
/// `oauth:tokenCache`, `.credentials.json`, Cookies, browser storage…) are
/// never enumerated, so copying them is structurally impossible.
public enum CopyCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case cliMCPServers
    case cliPlugins
    case cliSkillsAndCommands
    case cliSettings
    case desktopMCPAndConfig
    case desktopExtensions

    public var id: String { rawValue }

    public var isDesktop: Bool {
        self == .desktopMCPAndConfig || self == .desktopExtensions
    }

    public var displayName: String {
        switch self {
        case .cliMCPServers: return "MCP servers (CLI)"
        case .cliPlugins: return "Plugins (CLI)"
        case .cliSkillsAndCommands: return "Skills, commands & agents (CLI)"
        case .cliSettings: return "Settings (CLI)"
        case .desktopMCPAndConfig: return "MCP servers & settings (Desktop)"
        case .desktopExtensions: return "Extensions (Desktop)"
        }
    }

    public var explanation: String {
        switch self {
        case .cliMCPServers:
            return
                "Per-profile CLI MCP servers exist only with shell integration (CLAUDE_CONFIG_DIR). Without it, the CLI reads the global ~/.claude.json, which this app doesn't manage."
        case .cliPlugins:
            return
                "Installed plugins, marketplaces and blocklist — copied as one unit so the manifest stays consistent."
        case .cliSkillsAndCommands:
            return "skills/, commands/, agents/ and CLAUDE.md."
        case .cliSettings:
            return "settings.json — includes permissions and hooks."
        case .desktopMCPAndConfig:
            return "MCP servers and preferences from claude_desktop_config.json. Sign-in state is never copied."
        case .desktopExtensions:
            return "Installed Desktop extensions and their settings — copied as one unit."
        }
    }
}

public enum CopyMode: String, Sendable, Equatable {
    case merge
    case overwrite
}

/// One copyable unit. `relativePath`s are relative to the surface root
/// (the profile's cli/ or desktop/ dir, chosen by `category.isDesktop`).
public struct CopyItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// One entry under a top-level dict key of a JSON file (e.g. mcpServers["github"]).
        case jsonEntry(file: String, topLevelKey: String, entryKey: String)
        /// The non-`excludingKey` remainder of a JSON file, merged key-by-key.
        case jsonRemainder(file: String, excludingKey: String)
        /// A single top-level directory or file entry.
        case path(relativePath: String)
        /// Several paths treated as one atomic unit (plugins, Desktop extensions).
        case composite(relativePaths: [String])
    }

    public let category: CopyCategory
    public let kind: Kind
    public let displayName: String
    public var id: String { "\(category.rawValue)|\(displayName)" }
}

public struct CopyConflict: Identifiable, Hashable, Sendable {
    public let item: CopyItem
    /// Short, value-redacted descriptions ("keys: command, args, env" /
    /// "12 files") — never raw JSON values, which can contain secrets.
    public let sourceDetail: String
    public let targetDetail: String
    public var id: String { item.id }
}

public enum ConflictResolution: Sendable, Equatable {
    case useSource
    case keepTarget
}

public struct CopyPlan: Sendable {
    public struct CategoryPlan: Sendable {
        public let category: CopyCategory
        /// In source, to be copied (merge: absent in target; overwrite: every
        /// non-identical source item).
        public let additions: [CopyItem]
        /// Same key on both sides with differing content (merge mode only).
        public let conflicts: [CopyConflict]
        /// Equal on both sides — skipped.
        public let identical: [CopyItem]
        /// Overwrite mode only: existing target items moved to the Trash.
        public let replacements: [CopyItem]
    }

    public let sourceCLI: URL
    public let sourceDesktop: URL
    public let targetCLI: URL
    public let targetDesktop: URL
    public let mode: CopyMode
    public let categories: [CategoryPlan]

    public var allConflicts: [CopyConflict] { categories.flatMap(\.conflicts) }
    public var isEmpty: Bool {
        categories.allSatisfy { $0.additions.isEmpty && $0.conflicts.isEmpty && $0.replacements.isEmpty }
    }
    /// True when executing this plan will write into the target's desktop dir.
    public var mutatesDesktop: Bool {
        categories.contains {
            $0.category.isDesktop && (!$0.additions.isEmpty || !$0.conflicts.isEmpty || !$0.replacements.isEmpty)
        }
    }
}

public struct CopySummary: Sendable {
    public var copied: [CopyItem] = []
    public var trashed: [CopyItem] = []
    public var keptTarget: [CopyItem] = []
    public var skippedIdentical: [CopyItem] = []
    public init() {}
}

public enum ConfigCopyError: LocalizedError {
    case sourceEqualsTarget
    case unreadableJSON(URL)
    case ioFailure(String)
    case partialFailure(completed: CopySummary, failedItem: CopyItem, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .sourceEqualsTarget:
            return "Source and target profile are the same."
        case .unreadableJSON(let url):
            return "\(url.lastPathComponent) couldn't be parsed as JSON — fix or remove it, then retry."
        case .ioFailure(let message):
            return message
        case .partialFailure(let completed, let failedItem, let underlying):
            return "Copy stopped at \"\(failedItem.displayName)\": \(underlying.localizedDescription). "
                + "\(completed.copied.count) item(s) were copied before the failure; "
                + "anything replaced is in the Trash. Re-running the copy is safe."
        }
    }
}

// MARK: - Service

/// Two-phase profile-to-profile configuration copy: `plan` is a read-only dry
/// run that classifies every allow-listed item as addition / identical /
/// conflict (or replacement in overwrite mode); `execute` applies the plan
/// with per-conflict resolutions.
///
/// `@unchecked Sendable` for the same reason as `CredentialsInspector`: the
/// only state is an immutable `FileManager` reference and a `@Sendable` trash
/// closure; all methods are pure I/O.
public struct ConfigCopyService: @unchecked Sendable {
    public let fm: FileManager
    /// Trash seam — production moves to the macOS Trash (recoverable); tests
    /// capture the URLs instead.
    public let trash: @Sendable (URL) throws -> Void

    public init(
        fm: FileManager = .default,
        trash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.fm = fm
        self.trash = trash
    }

    // Allow-listed paths per category (relative to the surface root).
    static let claudeJSONFile = ".claude.json"
    static let mcpServersKey = "mcpServers"
    static let pluginPaths = [
        "plugins/installed_plugins.json", "plugins/known_marketplaces.json",
        "plugins/blocklist.json", "plugins/data", "plugins/marketplaces",
    ]
    static let skillsParents = ["skills", "commands", "agents"]
    static let claudeMDFile = "CLAUDE.md"
    static let cliSettingsFile = "settings.json"
    static let desktopConfigFile = "claude_desktop_config.json"
    static let desktopExtensionPaths = [
        "Claude Extensions", "Claude Extensions Settings",
        "extensions-installations.json", "extensions-blocklist.json",
    ]

    // MARK: Availability

    /// Which categories the sheet can offer for this source profile.
    public func availableCategories(sourceCLI: URL, sourceDesktop: URL) -> Set<CopyCategory> {
        var result: Set<CopyCategory> = []
        if let dict = try? readJSONDict(sourceCLI.appendingPathComponent(Self.claudeJSONFile)),
            let servers = dict[Self.mcpServersKey] as? [String: Any], !servers.isEmpty
        {
            result.insert(.cliMCPServers)
        }
        if Self.pluginPaths.contains(where: { itemExists(sourceCLI.appendingPathComponent($0)) }) {
            result.insert(.cliPlugins)
        }
        let skillsEntries =
            Self.skillsParents.map { sourceCLI.appendingPathComponent($0) }
            + [sourceCLI.appendingPathComponent(Self.claudeMDFile)]
        if skillsEntries.contains(where: { itemExists($0) }) {
            result.insert(.cliSkillsAndCommands)
        }
        if itemExists(sourceCLI.appendingPathComponent(Self.cliSettingsFile)) {
            result.insert(.cliSettings)
        }
        if itemExists(sourceDesktop.appendingPathComponent(Self.desktopConfigFile)) {
            result.insert(.desktopMCPAndConfig)
        }
        if Self.desktopExtensionPaths.contains(where: { itemExists(sourceDesktop.appendingPathComponent($0)) }) {
            result.insert(.desktopExtensions)
        }
        return result
    }

    // MARK: Plan (phase 1 — pure reads)

    public func plan(
        sourceCLI: URL, sourceDesktop: URL,
        targetCLI: URL, targetDesktop: URL,
        categories: Set<CopyCategory>, mode: CopyMode
    ) throws -> CopyPlan {
        guard sourceCLI.standardizedFileURL != targetCLI.standardizedFileURL else {
            throw ConfigCopyError.sourceEqualsTarget
        }

        var plans: [CopyPlan.CategoryPlan] = []
        for category in CopyCategory.allCases where categories.contains(category) {
            let sourceRoot = category.isDesktop ? sourceDesktop : sourceCLI
            let targetRoot = category.isDesktop ? targetDesktop : targetCLI
            plans.append(
                try planCategory(category, sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode))
        }
        return CopyPlan(
            sourceCLI: sourceCLI, sourceDesktop: sourceDesktop,
            targetCLI: targetCLI, targetDesktop: targetDesktop,
            mode: mode, categories: plans)
    }

    private func planCategory(
        _ category: CopyCategory, sourceRoot: URL, targetRoot: URL, mode: CopyMode
    ) throws -> CopyPlan.CategoryPlan {
        switch category {
        case .cliMCPServers:
            return try planJSONEntries(
                category: category, file: Self.claudeJSONFile, key: Self.mcpServersKey,
                sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode,
                includeRemainder: false)
        case .desktopMCPAndConfig:
            return try planJSONEntries(
                category: category, file: Self.desktopConfigFile, key: Self.mcpServersKey,
                sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode,
                includeRemainder: true)
        case .cliPlugins:
            return planComposite(
                category: category, displayName: "Plugins",
                relativePaths: Self.pluginPaths,
                sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode)
        case .desktopExtensions:
            return planComposite(
                category: category, displayName: "Desktop extensions",
                relativePaths: Self.desktopExtensionPaths,
                sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode)
        case .cliSkillsAndCommands:
            return planPathEntries(category: category, sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode)
        case .cliSettings:
            return planSinglePath(
                category: category, relativePath: Self.cliSettingsFile,
                sourceRoot: sourceRoot, targetRoot: targetRoot, mode: mode)
        }
    }

    /// Classify the top-level entries of `key` in a JSON file, optionally plus
    /// a remainder item covering the file's other top-level keys.
    private func planJSONEntries(
        category: CopyCategory, file: String, key: String,
        sourceRoot: URL, targetRoot: URL, mode: CopyMode,
        includeRemainder: Bool
    ) throws -> CopyPlan.CategoryPlan {
        let sourceDict = try readJSONDictOrThrow(sourceRoot.appendingPathComponent(file)) ?? [:]
        let targetDict = try readJSONDictOrThrow(targetRoot.appendingPathComponent(file)) ?? [:]
        let sourceServers = sourceDict[key] as? [String: Any] ?? [:]
        let targetServers = targetDict[key] as? [String: Any] ?? [:]

        var additions: [CopyItem] = []
        var conflicts: [CopyConflict] = []
        var identical: [CopyItem] = []
        var replacements: [CopyItem] = []

        func entryItem(_ entryKey: String) -> CopyItem {
            CopyItem(
                category: category,
                kind: .jsonEntry(file: file, topLevelKey: key, entryKey: entryKey),
                displayName: entryKey)
        }

        for entryKey in sourceServers.keys.sorted() {
            let item = entryItem(entryKey)
            guard let targetValue = targetServers[entryKey] else {
                additions.append(item)
                continue
            }
            if canonicalJSON(sourceServers[entryKey]) == canonicalJSON(targetValue) {
                identical.append(item)
            } else if mode == .merge {
                conflicts.append(
                    CopyConflict(
                        item: item,
                        sourceDetail: jsonEntryDetail(sourceServers[entryKey]),
                        targetDetail: jsonEntryDetail(targetValue)))
            } else {
                additions.append(item)
                replacements.append(item)
            }
        }
        if mode == .overwrite {
            // Target-only entries disappear when the dict is replaced wholesale.
            for entryKey in targetServers.keys.sorted() where sourceServers[entryKey] == nil {
                replacements.append(entryItem(entryKey))
            }
        }

        if includeRemainder {
            let sourceRest = sourceDict.filter { $0.key != key }
            let targetRest = targetDict.filter { $0.key != key }
            if !sourceRest.isEmpty {
                let item = CopyItem(
                    category: category,
                    kind: .jsonRemainder(file: file, excludingKey: key),
                    displayName: "Desktop settings")
                if canonicalJSON(sourceRest) == canonicalJSON(targetRest) {
                    identical.append(item)
                } else if targetRest.isEmpty {
                    additions.append(item)
                } else if mode == .merge {
                    conflicts.append(
                        CopyConflict(
                            item: item,
                            sourceDetail: "keys: \(sourceRest.keys.sorted().joined(separator: ", "))",
                            targetDetail: "keys: \(targetRest.keys.sorted().joined(separator: ", "))"))
                } else {
                    additions.append(item)
                    replacements.append(item)
                }
            }
        }

        return CopyPlan.CategoryPlan(
            category: category, additions: additions, conflicts: conflicts,
            identical: identical, replacements: replacements)
    }

    /// One wholesale unit spanning several paths (plugins, Desktop extensions).
    private func planComposite(
        category: CopyCategory, displayName: String, relativePaths: [String],
        sourceRoot: URL, targetRoot: URL, mode: CopyMode
    ) -> CopyPlan.CategoryPlan {
        let item = CopyItem(
            category: category, kind: .composite(relativePaths: relativePaths),
            displayName: displayName)
        let sourceExists = relativePaths.contains { itemExists(sourceRoot.appendingPathComponent($0)) }
        let targetExists = relativePaths.contains { itemExists(targetRoot.appendingPathComponent($0)) }

        guard sourceExists else {
            return CopyPlan.CategoryPlan(
                category: category, additions: [], conflicts: [], identical: [], replacements: [])
        }
        if !targetExists {
            return CopyPlan.CategoryPlan(
                category: category, additions: [item], conflicts: [], identical: [], replacements: [])
        }
        let sourceHash = compositeHash(root: sourceRoot, relativePaths: relativePaths)
        let targetHash = compositeHash(root: targetRoot, relativePaths: relativePaths)
        if sourceHash == targetHash {
            return CopyPlan.CategoryPlan(
                category: category, additions: [], conflicts: [], identical: [item], replacements: [])
        }
        if mode == .merge {
            let conflict = CopyConflict(
                item: item,
                sourceDetail: compositeDetail(root: sourceRoot, relativePaths: relativePaths),
                targetDetail: compositeDetail(root: targetRoot, relativePaths: relativePaths))
            return CopyPlan.CategoryPlan(
                category: category, additions: [], conflicts: [conflict], identical: [], replacements: [])
        }
        return CopyPlan.CategoryPlan(
            category: category, additions: [item], conflicts: [], identical: [], replacements: [item])
    }

    /// Per-entry classification of skills/, commands/, agents/ and CLAUDE.md.
    private func planPathEntries(
        category: CopyCategory, sourceRoot: URL, targetRoot: URL, mode: CopyMode
    ) -> CopyPlan.CategoryPlan {
        var sourceEntries: [String] = []
        for parent in Self.skillsParents {
            let dir = sourceRoot.appendingPathComponent(parent)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                sourceEntries.append("\(parent)/\(name)")
            }
        }
        if itemExists(sourceRoot.appendingPathComponent(Self.claudeMDFile)) {
            sourceEntries.append(Self.claudeMDFile)
        }

        var additions: [CopyItem] = []
        var conflicts: [CopyConflict] = []
        var identical: [CopyItem] = []
        var replacements: [CopyItem] = []

        for relative in sourceEntries {
            let item = CopyItem(category: category, kind: .path(relativePath: relative), displayName: relative)
            let sourceURL = sourceRoot.appendingPathComponent(relative)
            let targetURL = targetRoot.appendingPathComponent(relative)
            if !itemExists(targetURL) {
                additions.append(item)
            } else if pathHash(sourceURL) == pathHash(targetURL) {
                identical.append(item)
            } else if mode == .merge {
                conflicts.append(
                    CopyConflict(
                        item: item,
                        sourceDetail: pathDetail(sourceURL),
                        targetDetail: pathDetail(targetURL)))
            } else {
                additions.append(item)
                replacements.append(item)
            }
        }

        if mode == .overwrite {
            // Target-only entries get trashed so the category mirrors the source.
            let sourceSet = Set(sourceEntries)
            for parent in Self.skillsParents {
                let dir = targetRoot.appendingPathComponent(parent)
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names.sorted() where !name.hasPrefix(".") {
                    let relative = "\(parent)/\(name)"
                    if !sourceSet.contains(relative) {
                        replacements.append(
                            CopyItem(category: category, kind: .path(relativePath: relative), displayName: relative))
                    }
                }
            }
        }

        return CopyPlan.CategoryPlan(
            category: category, additions: additions, conflicts: conflicts,
            identical: identical, replacements: replacements)
    }

    private func planSinglePath(
        category: CopyCategory, relativePath: String,
        sourceRoot: URL, targetRoot: URL, mode: CopyMode
    ) -> CopyPlan.CategoryPlan {
        let item = CopyItem(category: category, kind: .path(relativePath: relativePath), displayName: relativePath)
        let sourceURL = sourceRoot.appendingPathComponent(relativePath)
        let targetURL = targetRoot.appendingPathComponent(relativePath)
        guard itemExists(sourceURL) else {
            return CopyPlan.CategoryPlan(
                category: category, additions: [], conflicts: [], identical: [], replacements: [])
        }
        if !itemExists(targetURL) {
            return CopyPlan.CategoryPlan(
                category: category, additions: [item], conflicts: [], identical: [], replacements: [])
        }
        if pathHash(sourceURL) == pathHash(targetURL) {
            return CopyPlan.CategoryPlan(
                category: category, additions: [], conflicts: [], identical: [item], replacements: [])
        }
        if mode == .merge {
            let conflict = CopyConflict(
                item: item, sourceDetail: pathDetail(sourceURL), targetDetail: pathDetail(targetURL))
            return CopyPlan.CategoryPlan(
                category: category, additions: [], conflicts: [conflict], identical: [], replacements: [])
        }
        return CopyPlan.CategoryPlan(
            category: category, additions: [item], conflicts: [], identical: [], replacements: [item])
    }

    // MARK: Execute (phase 2)

    /// Apply the plan. Unresolved conflicts default to `.keepTarget`. The first
    /// I/O failure aborts and is wrapped as `.partialFailure` carrying what
    /// completed — everything destructive went to the Trash, and re-running the
    /// same copy is safe (already-copied items reclassify as identical).
    public func execute(
        _ plan: CopyPlan,
        resolutions: [CopyItem.ID: ConflictResolution] = [:]
    ) throws -> CopySummary {
        var summary = CopySummary()

        for categoryPlan in plan.categories {
            let sourceRoot = categoryPlan.category.isDesktop ? plan.sourceDesktop : plan.sourceCLI
            let targetRoot = categoryPlan.category.isDesktop ? plan.targetDesktop : plan.targetCLI

            summary.skippedIdentical.append(contentsOf: categoryPlan.identical)

            // Decide the winning side per conflict.
            var chosen: [CopyItem] = categoryPlan.additions
            for conflict in categoryPlan.conflicts {
                if resolutions[conflict.id] == .useSource {
                    chosen.append(conflict.item)
                } else {
                    summary.keptTarget.append(conflict.item)
                }
            }

            // Overwrite: trash replaced target items first (path/composite
            // kinds only — JSON entries are replaced in the dict rewrite and
            // never require trashing the file, which would destroy unrelated
            // keys like .claude.json's identity fields).
            if plan.mode == .overwrite {
                for item in categoryPlan.replacements {
                    do {
                        switch item.kind {
                        case .path(let relative):
                            let url = targetRoot.appendingPathComponent(relative)
                            if itemExists(url) {
                                try trash(url)
                                summary.trashed.append(item)
                            }
                        case .composite(let relatives):
                            var trashedAny = false
                            for relative in relatives {
                                let url = targetRoot.appendingPathComponent(relative)
                                if itemExists(url) {
                                    try trash(url)
                                    trashedAny = true
                                }
                            }
                            if trashedAny { summary.trashed.append(item) }
                        case .jsonEntry, .jsonRemainder:
                            break  // handled in the JSON rewrite below
                        }
                    } catch {
                        throw ConfigCopyError.partialFailure(
                            completed: summary, failedItem: item, underlying: error)
                    }
                }
            }

            // JSON rewrites: group all chosen entries per file, one
            // read-modify-write each.
            do {
                try executeJSON(
                    categoryPlan: categoryPlan, chosen: chosen, mode: plan.mode,
                    sourceRoot: sourceRoot, targetRoot: targetRoot, summary: &summary)
            } catch let error as ConfigCopyError {
                throw error
            } catch {
                let anyJSONItem =
                    chosen.first {
                        if case .jsonEntry = $0.kind { return true }
                        if case .jsonRemainder = $0.kind { return true }
                        return false
                    }
                    ?? CopyItem(
                        category: categoryPlan.category,
                        kind: .jsonRemainder(file: "?", excludingKey: ""),
                        displayName: categoryPlan.category.displayName)
                throw ConfigCopyError.partialFailure(
                    completed: summary, failedItem: anyJSONItem, underlying: error)
            }

            // Path/composite copies.
            for item in chosen {
                do {
                    switch item.kind {
                    case .jsonEntry, .jsonRemainder:
                        continue  // already applied above
                    case .path(let relative):
                        let sourceURL = sourceRoot.appendingPathComponent(relative)
                        guard itemExists(sourceURL) else { continue }  // vanished since plan
                        let trashedExisting = try copyReplacing(
                            source: sourceURL,
                            target: targetRoot.appendingPathComponent(relative))
                        if trashedExisting, plan.mode == .merge { summary.trashed.append(item) }
                        summary.copied.append(item)
                    case .composite(let relatives):
                        var trashedExisting = false
                        for relative in relatives {
                            let sourceURL = sourceRoot.appendingPathComponent(relative)
                            guard itemExists(sourceURL) else { continue }
                            if try copyReplacing(
                                source: sourceURL,
                                target: targetRoot.appendingPathComponent(relative))
                            {
                                trashedExisting = true
                            }
                        }
                        if trashedExisting, plan.mode == .merge { summary.trashed.append(item) }
                        summary.copied.append(item)
                    }
                } catch {
                    throw ConfigCopyError.partialFailure(
                        completed: summary, failedItem: item, underlying: error)
                }
            }
        }

        return summary
    }

    /// Apply all chosen JSON entries (and remainder) of a category in a single
    /// read-modify-write per file, preserving every unrelated top-level key —
    /// in particular `.claude.json`'s identity fields (oauthAccount, userID,
    /// projects), which must never be copied or destroyed.
    private func executeJSON(
        categoryPlan: CopyPlan.CategoryPlan, chosen: [CopyItem], mode: CopyMode,
        sourceRoot: URL, targetRoot: URL, summary: inout CopySummary
    ) throws {
        // file -> (topLevelKey, chosen entry keys, remainder chosen?)
        var entryKeysByFile: [String: (topLevelKey: String, keys: [String])] = [:]
        var remainderByFile: [String: String] = [:]  // file -> excludingKey
        var jsonItems: [CopyItem] = []

        for item in chosen {
            switch item.kind {
            case .jsonEntry(let file, let topLevelKey, let entryKey):
                entryKeysByFile[file, default: (topLevelKey, [])].keys.append(entryKey)
                jsonItems.append(item)
            case .jsonRemainder(let file, let excludingKey):
                remainderByFile[file] = excludingKey
                jsonItems.append(item)
            case .path, .composite:
                continue
            }
        }
        // Overwrite must rewrite the dict even when only removals (target-only
        // entries) are planned.
        let overwriteFiles: Set<String> =
            mode == .overwrite
            ? Set(
                categoryPlan.replacements.compactMap {
                    if case .jsonEntry(let file, _, _) = $0.kind { return file }
                    return nil
                })
            : []
        let files = Set(entryKeysByFile.keys).union(remainderByFile.keys).union(overwriteFiles)
        guard !files.isEmpty else { return }

        for file in files.sorted() {
            let sourceDict = try readJSONDictOrThrow(sourceRoot.appendingPathComponent(file)) ?? [:]
            let targetURL = targetRoot.appendingPathComponent(file)
            var targetDict = try readJSONDictOrThrow(targetURL) ?? [:]

            let topLevelKey = entryKeysByFile[file]?.topLevelKey ?? Self.mcpServersKey
            let sourceServers = sourceDict[topLevelKey] as? [String: Any] ?? [:]
            var targetServers = targetDict[topLevelKey] as? [String: Any] ?? [:]

            if mode == .overwrite {
                // The dict becomes exactly the source's.
                targetServers = sourceServers
            } else if let chosen = entryKeysByFile[file] {
                for key in chosen.keys {
                    if let value = sourceServers[key] { targetServers[key] = value }
                }
            }
            targetDict[topLevelKey] = targetServers

            if let excludingKey = remainderByFile[file] {
                // Key-by-key union with source winning; mcpServers untouched here.
                for (key, value) in sourceDict where key != excludingKey {
                    targetDict[key] = value
                }
            }

            let data = try JSONSerialization.data(
                withJSONObject: targetDict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: targetURL, options: .atomic)
        }
        summary.copied.append(contentsOf: jsonItems)
    }

    /// Copy `source` into place at `target` via a temp sibling + rename, moving
    /// any existing target to the Trash first. Returns whether an existing
    /// target was trashed.
    @discardableResult
    private func copyReplacing(source: URL, target: URL) throws -> Bool {
        let parent = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let temp = parent.appendingPathComponent(".\(target.lastPathComponent).copying-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: temp)

        var trashedExisting = false
        do {
            if itemExists(target) {
                try trash(target)
                trashedExisting = true
            }
            let result = temp.path.withCString { tempPtr in
                target.path.withCString { targetPtr in
                    rename(tempPtr, targetPtr)
                }
            }
            if result != 0 {
                let err = errno
                throw ConfigCopyError.ioFailure(
                    "Failed to move \(target.lastPathComponent) into place: \(String(cString: strerror(err)))")
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return trashedExisting
    }

    // MARK: - Comparison helpers

    /// Exists without following symlinks (same semantics as SymlinkService).
    func itemExists(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) { return true }
        return (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func readJSONDict(_ url: URL) throws -> [String: Any]? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigCopyError.unreadableJSON(url)
        }
        return dict
    }

    /// Like `readJSONDict` but converts read errors into `.unreadableJSON` too.
    private func readJSONDictOrThrow(_ url: URL) throws -> [String: Any]? {
        do {
            return try readJSONDict(url)
        } catch let error as ConfigCopyError {
            throw error
        } catch {
            throw ConfigCopyError.unreadableJSON(url)
        }
    }

    /// Canonical re-serialization for content comparison (sorted keys).
    private func canonicalJSON(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    /// Value-redacted description of a JSON entry — keys only, never values
    /// (MCP server entries routinely carry secrets in env vars).
    private func jsonEntryDetail(_ value: Any?) -> String {
        if let dict = value as? [String: Any] {
            return "keys: \(dict.keys.sorted().joined(separator: ", "))"
        }
        return "value differs"
    }

    /// Recursive SHA-256 over sorted relative paths + contents. Symlink
    /// destinations are hashed, not followed.
    private func pathHash(_ url: URL) -> String? {
        var hasher = SHA256()
        guard hashInto(&hasher, url: url, relative: "") else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func compositeHash(root: URL, relativePaths: [String]) -> String? {
        var hasher = SHA256()
        for relative in relativePaths.sorted() {
            let url = root.appendingPathComponent(relative)
            guard itemExists(url) else { continue }
            guard hashInto(&hasher, url: url, relative: relative) else { return nil }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hashInto(_ hasher: inout SHA256, url: URL, relative: String) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return false }
        hasher.update(data: Data(relative.utf8))
        switch type {
        case .typeSymbolicLink:
            let dest = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            hasher.update(data: Data("link:\(dest)".utf8))
        case .typeDirectory:
            hasher.update(data: Data("dir".utf8))
            let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") {
                if !hashInto(
                    &hasher, url: url.appendingPathComponent(name),
                    relative: relative.isEmpty ? name : "\(relative)/\(name)")
                {
                    return false
                }
            }
        default:
            guard let data = fm.contents(atPath: url.path) else { return false }
            hasher.update(data: data)
        }
        return true
    }

    /// Short metadata description for conflict rows.
    private func pathDetail(_ url: URL) -> String {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return "missing" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let modified = (attrs[.modificationDate] as? Date).map { formatter.string(from: $0) } ?? "?"
        if type == .typeDirectory {
            let count = (try? fm.subpathsOfDirectory(atPath: url.path).count) ?? 0
            return "\(count) file(s), modified \(modified)"
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return "\(size) bytes, modified \(modified)"
    }

    private func compositeDetail(root: URL, relativePaths: [String]) -> String {
        var files = 0
        for relative in relativePaths {
            let url = root.appendingPathComponent(relative)
            guard itemExists(url) else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                files += (try? fm.subpathsOfDirectory(atPath: url.path).count) ?? 0
            } else {
                files += 1
            }
        }
        return "\(files) file(s)"
    }
}
