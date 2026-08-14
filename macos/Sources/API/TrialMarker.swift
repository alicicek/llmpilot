import Foundation
import Security

/// The no-card-trial marker: a NATIVE-owned generic-password Keychain item under
/// its OWN service — NEVER dev.llmpilot.entitlement (the daemon must never see or
/// write it; advisor verdict 2026-07-12). Written synchronizable so it rides
/// iCloud Keychain across the user's Macs. It is a BEST-EFFORT effort bar, not an
/// authoritative gate: it raises friction on a normal user repeating the no-card
/// rung across their own Macs, but a determined local user can reset it (the
/// daemon can only self-report it). The no-card rung is the accepted-risk bottom
/// of the ladder (W8-MONEY-PLAN-REVIEW #1). The value is a presence flag, never a
/// credential — no secret is ever stored or reported.
///
/// Moved out of the (now-deleted) CockpitWindowController's file in the chunk
/// 6A native cutover — reading/reporting this marker (FleetViewModel.
/// reportMarkerOnce) is independent of that window's own WKWebView bridge and
/// stays load-bearing after it's gone. The WRITE half (`mark()`) currently has
/// no production caller: the deleted WKWebView bridge was its only invoker,
/// and neither the native ask nor the shipped web paywall renders the no-card
/// rung (LadderLogic.swift / ladder.ts both return nil for it), so the rung —
/// and this marker's write path — is wired-but-unsold on every surface. The
/// read half keeps honoring markers written by past versions, and the daemon
/// keeps its 409 (license.go markerPresent) for the same reason.
protocol TrialMarkerStore: Sendable {
    func isPresent() -> Bool
    @discardableResult func mark() -> Bool
}

struct KeychainTrialMarker: TrialMarkerStore {
    static let service = "dev.llmpilot.trial-marker"
    static let account = "current"

    func isPresent() -> Bool {
        // SynchronizableAny matches both a synced and a local marker, so one
        // written before the sync entitlement landed still counts.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult func mark() -> Bool {
        if isPresent() { return true }
        // Prefer a synchronizable item (iCloud, cross-Mac). If the write is
        // refused for lack of a keychain-access-groups entitlement, fall back to
        // a local item so the same-Mac friction bar still holds (owner enables
        // sync at signing — a close-out errand, not a blocker).
        for synchronizable in [true, false] {
            let attrs: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: synchronizable,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: Data([1]),
            ]
            let status = SecItemAdd(attrs as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem { return true }
        }
        return false
    }
}
