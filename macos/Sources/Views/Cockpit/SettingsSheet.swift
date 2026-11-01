import SwiftUI

// Native port of web/src/shell/SettingsDialog.tsx — the daemon config sheet
// (autopilot/notifications over GET/PUT /v1/config) plus the local Show
// History preference and the status line row. Plan cost is not asked for:
// the daemon reads each account's plan from its sign-in.
//
// Phase 4 chunk B wires web/src/pro/LicenseSection.tsx's card
// (LicenseCardView.swift) at the TOP of the sheet, exactly as the web
// renders it — `license`/`licenseModel`/`onTurnOn` are supplied by the
// integrator (a later chunk); this sheet neither fetches nor owns license
// state, and renders nothing when `licenseModel` is absent (existing call
// sites that don't pass it keep compiling unchanged).

/// Copy pinned verbatim against SettingsDialog.tsx — a future edit to either
/// side is a one-line diff, not silent drift.
enum SettingsCopy {
    static let title = "Settings" // ShellDialog title="Settings" (SettingsDialog.tsx:86)
    static let unreachable = "Settings unreachable — daemon not running or too old." // :68
    static let saveFailed = "Save failed — the daemon didn't take the change." // :75
    static let showHistory = "Show History" // :102
    static let showHistoryHint = "The charts section under the board." // :102
    static let autoSwitch = "Auto-switch" // :106
    /// One row for the line under Claude Code's prompt: install it when it
    /// isn't there, customize it when it is (it was two rows — "Statusline"
    /// and "Terminal statusline" — that read as the same thing twice).
    static let statusline = "Status line"
    static func statuslineHint(installed: Bool) -> String {
        installed
            ? "Your limits show at the bottom of Claude Code."
            : "Show your limits at the bottom of Claude Code."
    }
    static let customizeStatusline = "Customize…"
    static let usageNotifications = "Usage notifications" // :128
    static let defaultThresholdsText = "75% and 90%" // :82

    /// nil threshold = adaptive time-to-wall (the default, owner
    /// 2026-08-13); a set value = the user chose fixed mode and the hint
    /// states their number, exactly as before.
    static func autoSwitchHint(_ threshold: Double?) -> String {
        guard let threshold else {
            return "Switches when an account is ≈8 min from its limit, judged from live burn."
        }
        return "Switches to the account with headroom near \(jsNumberString(threshold))%." // :107
    }

    /// U7 (audit 2026-10-02): the row's state while the autopilot is not
    /// running — unlicensed, lapsed, or a build without the engine. The
    /// toggle is gone, not merely disabled: a switch drawn ON would claim a
    /// feature that is not switching anything.
    static let autoSwitchNeedsAutopilot = "Needs the autopilot — nothing switches until it is on."
    static let autoSwitchNotInBuild = "Needs the autopilot — not included in this build."
    static let autoSwitchOffer = "Turn on the autopilot"

    static func notificationsHint(_ thresholdsText: String) -> String {
        "Notifies when a limit passes \(thresholdsText)."
    }

    /// "75% and 90%" / "50%, 75% and 90%".
    static func thresholdsList(_ values: [Double]) -> String {
        let parts = values.map { "\(jsNumberString($0))%" }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}

/// Drives the native Settings sheet: config.json's autopilot/notifications
/// over GET/PUT /v1/config, plus derived read state for the hints. Mirrors SettingsDialog.tsx's load-on-open + save-on-change
/// discipline — no Save/Cancel buttons; every control mutation PUTs the FULL
/// local config copy immediately, because handleConfigPut is a full replace
/// server-side (internal/daemon/server.go:833-849 decodes straight into
/// store.Config, no merge).
///
/// CRITICAL FIX over the web: SettingsDialog.tsx's `patch()` falls back to
/// `{}` when `cfg` hasn't loaded yet (SettingsDialog.tsx:71-79) — `setCfg(fn(
/// prev ?? {}))` — so a control toggled before the GET resolves PUTs a config
/// object missing every field, silently wiping plan costs, thresholds, and
/// cooldowns already on disk. This model refuses to PUT until `load()` has
/// completed successfully at least once; `loaded` names that invariant so
/// tests and the view can gate on it directly instead of re-deriving it from
/// `config != nil`.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var config: CockpitConfig?
    @Published var err: String?
    @Published private(set) var loaded = false

    private let api: CockpitDaemonAPI

    /// U5: the status line row's install button — the daemon
    /// writes settings.json, so a DMG-only install needs no terminal. The
    /// integrator passes the doctor's reload so the "not showing your
    /// runway" note leaves the cockpit as soon as the write lands.
    private(set) lazy var statuslineInstall = StatuslineInstallModel(api: api, onInstalled: onStatuslineInstalled)
    private let onStatuslineInstalled: () -> Void

    init(api: CockpitDaemonAPI, onStatuslineInstalled: @escaping () -> Void = {}) {
        self.api = api
        self.onStatuslineInstalled = onStatuslineInstalled
    }

    /// SettingsDialog.tsx:61-69's `useEffect` on open.
    func load() async {
        // Re-arm the guard on every load: a failed RELOAD must disarm
        // patch() too, or a stale config from a previous open would be
        // full-replace-PUT over newer on-disk state — exactly the wipe
        // class the guard exists for.
        loaded = false
        do {
            config = try await api.cockpitConfig()
            loaded = true
            err = nil
        } catch {
            err = SettingsCopy.unreachable
        }
    }

    // MARK: - derived read state (SettingsDialog.tsx:81-83)

    var autoOn: Bool { !(config?.autopilot?.disabled ?? false) }
    var notifOn: Bool { !(config?.notifications?.disabled ?? false) }
    /// nil = no explicit threshold in config → the autopilot runs
    /// adaptive time-to-wall; the hint copy branches on exactly this.
    var thresholdPercent: Double? { config?.autopilot?.thresholdPercent }

    var thresholdsText: String {
        guard let t = config?.notifications?.thresholds, !t.isEmpty else {
            return SettingsCopy.defaultThresholdsText
        }
        return SettingsCopy.thresholdsList(t)
    }

    // MARK: - mutations

    /// The one gate every mutator goes through: no successful load yet, no
    /// PUT — the fix's fail case (SettingsModelTests.testNoPUTBeforeLoad...).
    /// Mirrors SettingsDialog.tsx:71-79's `patch`, minus the `{}` fallback.
    /// Serialized so two rapid mutations (two toggles in quick succession)
    /// can never land out of order — the PUT
    /// is a FULL replace with no version check, so an older body arriving
    /// last would silently win server-side.
    private var pendingPut: Task<Void, Never>?

    private func patch(_ mutate: (inout CockpitConfig) -> Void) {
        guard loaded, var next = config else { return }
        mutate(&next)
        config = next
        let previous = pendingPut
        pendingPut = Task { [next] in
            await previous?.value
            do {
                _ = try await api.putConfig(next)
                // Matches SettingsDialog.tsx: a save failure sets `err` but a
                // later success does not clear it — the web has no
                // success-clears-error path either, so this doesn't add one.
            } catch {
                err = SettingsCopy.saveFailed
            }
        }
    }

    /// SettingsDialog.tsx:109-115 — the switch reads "on"; the wire field is
    /// `disabled`, so the mapping INVERTS.
    func setAutoSwitch(_ on: Bool) {
        patch { cfg in
            var a = cfg.autopilot ?? CockpitAutopilotConfig(disabled: nil, thresholdPercent: nil, cooldownMinutes: nil)
            a.disabled = !on
            cfg.autopilot = a
        }
    }

    /// SettingsDialog.tsx:129-135 — same inversion as above.
    func setUsageNotifications(_ on: Bool) {
        patch { cfg in
            var n = cfg.notifications ?? CockpitNotificationsConfig(disabled: nil, thresholds: nil)
            n.disabled = !on
            cfg.notifications = n
        }
    }
}

// MARK: - view

/// One labeled row: title + optional hint on the left, a trailing control —
/// the native twin of SettingsDialog.tsx's `Row` helper (lines 12-22).
private struct SettingsRow<Content: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .semibold))
                if let hint {
                    Text(hint).font(.system(size: 10.5)).foregroundColor(CockpitTheme.ter)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().overlay(CockpitTheme.hairSoft)
        }
    }
}

/// The native Settings sheet content. The caller owns presentation (a
/// `.sheet`, a window — whatever the integrator's chrome is); this view just
/// loads on appear and closes itself via `onClose` when the Statusline row
/// hands off to the statusline editor.
struct SettingsSheet: View {
    @ObservedObject var model: SettingsModel
    let onClose: () -> Void
    let onOpenStatusline: () -> Void
    /// Whether llmpilot's line is the one in Claude Code, from the doctor's
    /// statusline check: true installed, false not (absent, or another
    /// tool's), nil not known yet — read as not installed, where the
    /// install button is harmless ("Already installed").
    var statuslineInstalled: Bool? = nil
    /// Phase 4 chunk B — Settings → License (web/src/pro/LicenseSection.tsx).
    /// `nil` licenseModel omits the card entirely (pre-integration default).
    var license: LicenseInfo? = nil
    var licenseModel: LicenseAccountModel? = nil
    var onTurnOn: () -> Void = {}

    /// U7: whether the Auto-switch row may show a live toggle at all. The
    /// daemon's own verdict (`/v1/license` active = its entitlement gate
    /// for "autopilot") is the only source — config.autopilot.disabled says
    /// what the user WANTS, not what is running. nil license (unreachable,
    /// or a build without the engine) reads as not running.
    static func autopilotRunning(license: LicenseInfo?) -> Bool {
        license?.active == true
    }

    /// Whether the row may OFFER to turn the autopilot on. Only a daemon
    /// with the licence surface (`available`) can sell it — a source build
    /// answers 501 to the quote and the checkout, so the offer there was a
    /// button into two errors (review 2026-10-03 P1); nil (unreachable or
    /// still loading) offers nothing either.
    static func autopilotOfferable(license: LicenseInfo?) -> Bool {
        guard let license else { return false }
        return license.available && !license.active && !license.paidButOff
    }

    /// The doctor's statusline check, read for the status line row: "ok"
    /// only when llmpilot's line is the one installed (doctor.go
    /// checkInstall); a finding means absent or another tool's; nil — no
    /// report yet, or not checked — is unknown.
    static func statuslineInstalled(_ report: DoctorReport?) -> Bool? {
        switch report?.checks.first(where: { $0.id == "statusline" })?.state {
        case "ok": return true
        case "finding": return false
        default: return nil
        }
    }

    /// Native twin of the web's `localStorage.llmpilot.showHistory`
    /// (SettingsDialog.tsx:6-10) — a LOCAL display preference, never PUT to
    /// the daemon. Default true matches `showHistoryPref()`'s `!== "off"`.
    @AppStorage("showHistory") private var showHistoryPref = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SettingsCopy.title).font(.system(size: 15, weight: .semibold))
            if let licenseModel {
                LicenseCardView(license: license, model: licenseModel, onTurnOn: onTurnOn)
                Divider().overlay(CockpitTheme.hairSoft)
            }
            if let err = model.err {
                CockpitWarnBox {
                    Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }
            VStack(spacing: 0) {
                SettingsRow(label: SettingsCopy.showHistory, hint: SettingsCopy.showHistoryHint) {
                    Toggle("", isOn: $showHistoryPref)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        // An empty Toggle("") title carries NO AX name —
                        // give each row's control the same name its
                        // visible caption reads.
                        .accessibilityIdentifier("settings-show-history")
                        .accessibilityLabel(SettingsCopy.showHistory)
                }
                if Self.autopilotRunning(license: license) {
                    SettingsRow(
                        label: SettingsCopy.autoSwitch,
                        hint: SettingsCopy.autoSwitchHint(model.thresholdPercent)
                    ) {
                        Toggle("", isOn: Binding(get: { model.autoOn }, set: model.setAutoSwitch))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(!model.loaded)
                            .accessibilityIdentifier("settings-auto-switch")
                            .accessibilityLabel(SettingsCopy.autoSwitch)
                    }
                } else if Self.autopilotOfferable(license: license) {
                    SettingsRow(label: SettingsCopy.autoSwitch, hint: SettingsCopy.autoSwitchNeedsAutopilot) {
                        Button(SettingsCopy.autoSwitchOffer, action: onTurnOn)
                            .accessibilityIdentifier("settings-auto-switch-offer")
                            .accessibilityLabel(SettingsCopy.autoSwitchOffer)
                    }
                } else {
                    SettingsRow(
                        label: SettingsCopy.autoSwitch,
                        hint: license?.available == false ? SettingsCopy.autoSwitchNotInBuild : SettingsCopy.autoSwitchNeedsAutopilot
                    ) {
                        EmptyView()
                    }
                }
                StatuslineSettingsRow(
                    install: model.statuslineInstall,
                    installed: statuslineInstalled == true,
                    onCustomize: {
                        onClose()
                        onOpenStatusline()
                    })
                SettingsRow(
                    label: SettingsCopy.usageNotifications,
                    hint: SettingsCopy.notificationsHint(model.thresholdsText)
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.notifOn },
                            set: { on in
                                model.setUsageNotifications(on)
                                // The second user-visible moment that may
                                // spend the one notification-permission ask
                                // (see dismissOnboarding) — someone turning
                                // usage notifications ON plainly wants
                                // banners. No-op unless undetermined.
                                if on { Task { await NoticeNotifier.shared.requestPermission() } }
                            })
                    )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.loaded)
                        .accessibilityIdentifier("settings-usage-notifications")
                        .accessibilityLabel(SettingsCopy.usageNotifications)
                }
            }
        }
        // No root padding/frame: SheetChrome owns the inset ring (owner
        // 2026-08-13 — the doubled padding read 32pt against Close's 16pt).
        .task { await model.load() }
    }
}

/// The status line row: Install while llmpilot's line isn't in Claude Code
/// (the doctor says so, and nothing installed it since), Customize once it
/// is. Observes the install model itself so a fresh install swaps the
/// button in place.
private struct StatuslineSettingsRow: View {
    @ObservedObject var install: StatuslineInstallModel
    let installed: Bool
    let onCustomize: () -> Void

    private var isInstalled: Bool {
        if installed { return true }
        if case .done = install.phase { return true }
        return false
    }

    var body: some View {
        SettingsRow(label: SettingsCopy.statusline, hint: SettingsCopy.statuslineHint(installed: isInstalled)) {
            if isInstalled {
                Button(SettingsCopy.customizeStatusline, action: onCustomize)
                    .accessibilityIdentifier("settings-customize-statusline")
                    .accessibilityLabel("Customize the status line")
            } else {
                StatuslineInstallControl(model: install)
                    .frame(maxWidth: 230, alignment: .trailing)
            }
        }
    }
}
