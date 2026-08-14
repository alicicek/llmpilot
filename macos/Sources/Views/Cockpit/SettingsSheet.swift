import SwiftUI

// Native port of web/src/shell/SettingsDialog.tsx — the daemon config sheet
// (autopilot/notifications/plan_cost_monthly over GET/PUT /v1/config) plus
// the local Show History preference and the statusline entry point.
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
    static let statusline = "Statusline" // :117
    static let statuslineHint = "Segments, presets, and a live preview of your terminal line." // :117
    static let customizeStatusline = "Customize statusline" // :125
    static let usageNotifications = "Usage notifications" // :128
    static let defaultThresholdsText = "75, 90" // :82
    static let planCostHint = "Monthly cost, used by the value readout in History." // :141

    /// nil threshold = adaptive time-to-wall (the default, owner
    /// 2026-08-13); a set value = the user chose fixed mode and the hint
    /// states their number, exactly as before.
    static func autoSwitchHint(_ threshold: Double?) -> String {
        guard let threshold else {
            return "Switches when an account is ≈8 min from its limit, judged from live burn."
        }
        return "Switches to the account with headroom near \(jsNumberString(threshold))%." // :107
    }

    static func notificationsHint(_ thresholdsText: String) -> String {
        "Notifies when a bucket crosses \(thresholdsText)%." // :128
    }

    static func planCostLabel(_ name: String) -> String {
        "Plan cost — \(name)" // :140
    }
}

/// Drives the native Settings sheet: config.json's autopilot/notifications/
/// plan_cost_monthly over GET/PUT /v1/config, plus derived read state for the
/// hints. Mirrors SettingsDialog.tsx's load-on-open + save-on-change
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

    init(api: CockpitDaemonAPI) {
        self.api = api
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
        return t.map { jsNumberString($0) }.joined(separator: ", ")
    }

    func planCost(for accountID: String) -> Double? {
        config?.planCostMonthly?[accountID]
    }

    // MARK: - mutations

    /// The one gate every mutator goes through: no successful load yet, no
    /// PUT — the fix's fail case (SettingsModelTests.testNoPUTBeforeLoad...).
    /// Mirrors SettingsDialog.tsx:71-79's `patch`, minus the `{}` fallback.
    /// Serialized so two rapid mutations (plan-cost commit on focus loss +
    /// a toggle in the same gesture) can never land out of order — the PUT
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

    /// SettingsDialog.tsx:152-160 — empty or unparseable text DELETES the
    /// key (never stores 0: a blank field means "no override", not "$0/mo").
    /// NATIVE DEVIATION: the web PUTs on every keystroke (`onChange`); this
    /// commits once, on focus loss/submit — same end state, far less daemon
    /// chatter.
    func commitPlanCost(_ text: String, accountID: String) {
        patch { cfg in
            var costs = cfg.planCostMonthly ?? [:]
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Double(trimmed), v.isFinite {
                costs[accountID] = v
            } else {
                costs.removeValue(forKey: accountID)
            }
            cfg.planCostMonthly = costs
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
    let accounts: [AccountState]
    let onClose: () -> Void
    let onOpenStatusline: () -> Void
    /// Phase 4 chunk B — Settings → License (web/src/pro/LicenseSection.tsx).
    /// `nil` licenseModel omits the card entirely (pre-integration default).
    var license: LicenseInfo? = nil
    var licenseModel: LicenseAccountModel? = nil
    var onTurnOn: () -> Void = {}

    /// Native twin of the web's `localStorage.llmpilot.showHistory`
    /// (SettingsDialog.tsx:6-10) — a LOCAL display preference, never PUT to
    /// the daemon. Default true matches `showHistoryPref()`'s `!== "off"`.
    @AppStorage("showHistory") private var showHistoryPref = true

    /// Uncommitted plan-cost text per account id, keyed while a field is
    /// being edited; committed (and cleared) on submit or focus loss.
    @State private var drafts: [String: String] = [:]
    @FocusState private var focusedAccountID: String?

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
                SettingsRow(label: SettingsCopy.statusline, hint: SettingsCopy.statuslineHint) {
                    Button(SettingsCopy.customizeStatusline) {
                        onClose()
                        onOpenStatusline()
                    }
                    .accessibilityIdentifier("settings-customize-statusline")
                    .accessibilityLabel(SettingsCopy.customizeStatusline)
                }
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
                ForEach(accounts) { account in
                    planCostRow(account)
                }
            }
        }
        // No root padding/frame: SheetChrome owns the inset ring (owner
        // 2026-08-13 — the doubled padding read 32pt against Close's 16pt).
        .task { await model.load() }
    }

    private func planCostRow(_ account: AccountState) -> some View {
        let name = account.label.isEmpty ? account.email : account.label
        return SettingsRow(label: SettingsCopy.planCostLabel(name), hint: SettingsCopy.planCostHint) {
            HStack(spacing: 4) {
                Text("$").font(.system(size: 12)).foregroundColor(CockpitTheme.sec)
                TextField(
                    "200",
                    text: Binding(
                        get: { drafts[account.id] ?? draftText(for: account) },
                        set: { drafts[account.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .focused($focusedAccountID, equals: account.id)
                .disabled(!model.loaded)
                .onSubmit { commitDraft(for: account.id) }
                .accessibilityIdentifier("settings-plan-cost-\(account.id)")
                .accessibilityLabel(SettingsCopy.planCostLabel(name))
                Text("/mo").font(.system(size: 12)).foregroundColor(CockpitTheme.sec)
            }
        }
        // Single-param onChange (macOS 13 target — the two-param
        // (old,new) overload needs macOS 14): fires with the NEWLY focused
        // id, so "this row lost focus" reads as "the new focus isn't me".
        // Harmless no-op for rows with no pending draft (the guard in
        // commitDraft below).
        .onChange(of: focusedAccountID) { newValue in
            if newValue != account.id {
                commitDraft(for: account.id)
            }
        }
    }

    private func draftText(for account: AccountState) -> String {
        guard let v = model.planCost(for: account.id) else { return "" }
        return jsNumberString(v)
    }

    private func commitDraft(for accountID: String) {
        guard let text = drafts[accountID] else { return }
        model.commitPlanCost(text, accountID: accountID)
        drafts[accountID] = nil
    }
}
