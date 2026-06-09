import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the menu-bar "Launch at Login" toggle.
///
/// Uses the modern API (macOS 13+) — no Login Items helper bundle required.
public struct LaunchAtLoginService {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True if the user disabled the app in System Settings → Login Items.
    public var requiresUserApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            if SMAppService.mainApp.status != .enabled { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
