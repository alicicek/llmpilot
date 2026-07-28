import Foundation
import ServiceManagement

/// App-side mirror of SMAppService.Status.
enum LoginItemStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Injectable seam over SMAppService (agent + mainApp). Unit tests use a
/// fake ONLY: no sandbox layer covers the BTM database, so a real
/// register() inside a test would enroll a real login item on the dev Mac.
protocol LoginItems: Sendable {
    func agentStatus() -> LoginItemStatus
    func registerAgent() throws
    func mainAppStatus() -> LoginItemStatus
    func setMainApp(enabled: Bool) throws
    func openLoginItemsSettings()
}

/// The bundled agent plist (Contents/Library/LaunchAgents). Its label is the
/// SAME dev.llmpilot.daemon the CLI's legacy install uses — one launchd
/// service namespace is the structural two-daemon prevention.
private let agentPlistName = "dev.llmpilot.daemon.plist"

struct SMLoginItems: LoginItems {
    func agentStatus() -> LoginItemStatus {
        Self.map(SMAppService.agent(plistName: agentPlistName).status)
    }

    func registerAgent() throws {
        try SMAppService.agent(plistName: agentPlistName).register()
    }

    func mainAppStatus() -> LoginItemStatus { Self.map(SMAppService.mainApp.status) }

    func setMainApp(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func map(_ s: SMAppService.Status) -> LoginItemStatus {
        switch s {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
}

/// Sandboxed e2e runs must never touch the real BTM database. With
/// LLMPILOT_DISABLE_SMAPPSERVICE=1 the SMAppService path reports
/// unavailable, so ensure-running falls through to the legacy launchd
/// path against the sandbox home.
struct DisabledLoginItems: LoginItems {
    struct Unavailable: Error {}
    func agentStatus() -> LoginItemStatus { .notFound }
    func registerAgent() throws { throw Unavailable() }
    func mainAppStatus() -> LoginItemStatus { .notFound }
    func setMainApp(enabled: Bool) throws { throw Unavailable() }
    func openLoginItemsSettings() {}
}

enum LoginItemsFactory {
    static func make() -> LoginItems {
        if ProcessInfo.processInfo.environment["LLMPILOT_DISABLE_SMAPPSERVICE"] == "1" {
            return DisabledLoginItems()
        }
        return SMLoginItems()
    }
}
