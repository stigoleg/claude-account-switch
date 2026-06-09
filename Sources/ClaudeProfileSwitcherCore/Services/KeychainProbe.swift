import Foundation

/// Cached, off-main existence check for `Claude Code-credentials*` keychain
/// entries via `/usr/bin/security find-generic-password`.
///
/// The probe runs in a subprocess so it never blocks the main actor. Results
/// are cached for a few seconds — a typical UI refresh fans out to every
/// profile, and the keychain entry is global, so back-to-back probes for the
/// same service should reuse the cached answer.
public actor KeychainProbe {
    public static let shared = KeychainProbe()

    /// How long to trust a cached probe answer. Keychain edits are rare and the
    /// user-visible cost of a stale "unknown" badge is much smaller than the
    /// cost of stalling a UI refresh by 50 ms per profile.
    public static let cacheTTL: TimeInterval = 5

    /// Wall-clock cap on the security subprocess. The tool replies in single-
    /// digit milliseconds on healthy systems; anything past 1.5 s is a system
    /// hang and we fail closed (treat as "no entry").
    public static let timeout: TimeInterval = 1.5

    private struct CacheEntry {
        let value: Bool
        let expires: Date
    }
    private var cache: [String: CacheEntry] = [:]

    public init() {}

    public func hasGenericPassword(service: String, now: Date = .now) async -> Bool {
        if let hit = cache[service], hit.expires > now {
            return hit.value
        }
        let result = await Self.runSecurity(service: service)
        cache[service] = CacheEntry(value: result, expires: now.addingTimeInterval(Self.cacheTTL))
        return result
    }

    public func invalidate() {
        cache.removeAll()
    }

    private static func runSecurity(service: String) async -> Bool {
        // Off the main actor by virtue of being inside this `actor`.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/usr/bin/security"
                task.arguments = ["find-generic-password", "-s", service]
                task.standardOutput = Pipe()
                task.standardError = Pipe()

                var timedOut = false
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
                timer.schedule(deadline: .now() + Self.timeout)
                timer.setEventHandler {
                    if task.isRunning {
                        timedOut = true
                        task.terminate()
                    }
                }
                timer.resume()

                do {
                    try task.run()
                } catch {
                    timer.cancel()
                    continuation.resume(returning: false)
                    return
                }
                task.waitUntilExit()
                timer.cancel()

                if timedOut {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: task.terminationStatus == 0)
            }
        }
    }
}
