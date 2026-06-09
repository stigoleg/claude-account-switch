import AppKit
import Foundation
import UserNotifications
import os

/// Watches `~/.config/claude-profile-switcher/desktop-hint` for updates from
/// the shell function. When the named profile differs from the currently
/// active Desktop profile, it asks the user (via a macOS notification)
/// whether to switch.
///
/// Auto-switching Desktop on a `cd` would be too aggressive — the user may be
/// mid-conversation with another account. We always confirm before swapping.
@MainActor
public final class DesktopHintWatcher {
    private let store: ProfileStore
    private let fm = FileManager.default
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isRunning = false
    private var lastSeenHint: String?

    /// Called when the hint indicates the user wants a profile that isn't
    /// active. The view model wires this through `requestSwitch` so the
    /// existing "Claude Desktop is running" confirmation still fires.
    public var onProfileRequested: ((Profile) -> Void)?

    public init(store: ProfileStore) {
        self.store = store
    }

    public var hintFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/claude-profile-switcher/desktop-hint")
    }

    public func start() {
        guard !isRunning else { return }
        ensureNotificationAuthorization()

        let parent = hintFileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: hintFileURL.path) {
            fm.createFile(atPath: hintFileURL.path, contents: nil)
        }

        let fd = open(hintFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fileDescriptor = fd

        // Use a background queue and hop to the main actor explicitly inside
        // the handler so the actor boundary is part of the contract — not a
        // side effect of which DispatchQueue we happen to schedule on.
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleHintChanged()
            }
        }
        src.setCancelHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.fileDescriptor >= 0 {
                    close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }
            }
        }
        src.resume()
        self.source = src
        self.isRunning = true

        // Set up the notification delegate (lazy, idempotent).
        NotificationDelegate.shared.setHandler { [weak self] profileID in
            guard let self else { return }
            if let profile = self.store.profiles.first(where: { $0.id == profileID }) {
                self.onProfileRequested?(profile)
            }
        }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    public func stop() {
        source?.cancel()
        source = nil
        // The cancel handler also closes the fd; this is belt-and-braces in
        // case stop() is called before the source has been resumed.
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        isRunning = false
    }

    private func handleHintChanged() {
        guard let contents = try? String(contentsOf: hintFileURL, encoding: .utf8) else { return }
        // Format: <profile-name>\n<unix-timestamp>\n
        let firstLine =
            contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return }
        guard contents != lastSeenHint else { return }
        lastSeenHint = contents

        // Look up the profile by name (case-insensitive).
        guard let profile = store.profiles.first(where: { $0.name.lowercased() == firstLine.lowercased() }) else {
            return
        }
        // Already on this profile? Nothing to do.
        if store.activeProfileID == profile.id { return }

        notify(profile: profile)
    }

    private func notify(profile: Profile) {
        let content = UNMutableNotificationContent()
        content.title = "Switch Claude Desktop to “\(profile.name)”?"
        content.body = "You're in a project bound to this profile. Click to switch."
        content.categoryIdentifier = "claude-profile-switch"
        content.userInfo = ["profileID": profile.id.uuidString]
        content.sound = .default

        let switchAction = UNNotificationAction(
            identifier: "switch",
            title: "Switch",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "dismiss",
            title: "Not now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "claude-profile-switch",
            actions: [switchAction, dismissAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])

        let request = UNNotificationRequest(
            identifier: "hint-\(profile.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func ensureNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

/// Bridge between UNUserNotificationCenter (which uses NSObject delegates and
/// may call back from any thread) and our `@MainActor` handler closure.
///
/// State lives behind an `OSAllocatedUnfairLock` so the class is genuinely
/// `Sendable` without `@unchecked`. The handler hop to MainActor is done with
/// `Task { @MainActor in }` inside the delegate callback.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    private let state = OSAllocatedUnfairLock<(@MainActor @Sendable (UUID) -> Void)?>(initialState: nil)

    func setHandler(_ h: (@MainActor @Sendable (UUID) -> Void)?) {
        state.withLock { current in current = h }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard
            response.actionIdentifier == "switch" || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        guard let idString = response.notification.request.content.userInfo["profileID"] as? String,
            let id = UUID(uuidString: idString)
        else { return }
        let handler = state.withLock { $0 }
        guard let handler else { return }
        Task { @MainActor in
            handler(id)
        }
    }
}
