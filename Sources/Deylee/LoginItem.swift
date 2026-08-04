import Foundation
import ServiceManagement

/// Launch at login, via `SMAppService`.
///
/// The OS is the source of truth, not the preference: the user can remove the login
/// item in System Settings without Deylee ever hearing about it, so startup reconciles
/// the stored preference against what the system actually reports rather than
/// asserting the preference over it.
enum LoginItem {
    static var isEnabled: Bool {
        // `.requiresApproval` means the user has not allowed it yet, so nothing will
        // actually launch — reporting that as "on" would be a lie.
        SMAppService.mainApp.status == .enabled
    }

    /// Throws when the system refuses. A login-item write is one of the few
    /// operations allowed to fail loudly, so the settings toggle can snap back.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
