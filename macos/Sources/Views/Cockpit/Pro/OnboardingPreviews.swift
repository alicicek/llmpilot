import SwiftUI

// ITERATE THE ONBOARDING FLOW HERE — no daemon, no login, no build-and-run.
//
// Open this file in Xcode and show the canvas (Editor ▸ Canvas, or
// ⌥⌘⏎). Each #Preview below renders ONE onboarding screen at real window
// size with mock data, so you see the exact layout — content centered,
// the full-width Continue pinned at the bottom — and edits refresh in the
// canvas in seconds. This is the fast loop for UI work; launch the whole
// app only to check integration (mount conditions, the live quote, etc.).
//
// To change a screen's layout, edit its view (EducationChrome.swift's
// EducationFrame for wall/blind/windows, OnboardingFlowView.swift for the
// switch/accounts steps, PaywallViews.swift for receipt/reminder) and watch
// the matching preview update.

#if DEBUG

/// Shared mock quote — a 4-day trial, £9.99 (discount £5.99), matching what
/// the real worker returns so the previews read like production.
private let previewQuote = LadderQuote(
    trialDays: 4,
    chargeDate: Date(timeIntervalSince1970: 1_785_000_000),
    pricesFull: ["gbp": 999, "usd": 1299],
    pricesDiscount: ["gbp": 599, "usd": 799])

/// A fresh machine: zero accounts. The switch demo falls back to its masked
/// demo fleet on this, exactly as a new user sees it.
private let previewEmptyState = DaemonState(
    accounts: [], activeID: nil, schedules: [], asOf: Date())

/// Wrap a screen in a real-window-sized canvas so the onboarding layout
/// (centered content, bottom-pinned CTA) shows the way it will in the app.
/// `width`/`height` default to the corridor's normal opening size (design
/// 2026-08-10: 860×560) — a caller overrides them for the
/// minimum-window-size check.
private struct OnboardingPreviewFrame<Content: View>: View {
    var width: CGFloat = 860
    var height: CGFloat = 560
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(width: width, height: height)
            .background(CockpitTheme.win)
    }
}

/// A DEBUG-only license, built the SAME way the model tests do
/// (ProAskMachineTests.swift's own `license(status:active:)` helper) —
/// `LicenseInfo` is `Decodable` with no memberwise initializer, so this
/// decodes the same minimal JSON shape rather than inventing a second
/// construction path previews alone would carry.
private func previewLicense(status: String, active: Bool = false) -> LicenseInfo {
    try! DaemonDates.decoder().decode(
        LicenseInfo.self,
        from: Data(#"{"available":true,"active":\#(active),"status":"\#(status)","nocard_trial_used":false}"#.utf8))
}

/// A DEBUG-only stub satisfying `AskMachine`'s `CockpitDaemonAPI & DaemonAPI`
/// requirement. `AskMachine`'s initializer takes a non-optional API
/// reference, but every preview below drives the machine's `stage`/`quote`
/// directly and never taps Checkout, Cancel, or any other network action —
/// so this only needs to fail loudly (never silently return fake data) if a
/// method is EVER actually invoked from a canvas, which it shouldn't be.
/// `Tests/StubCockpitAPI.swift` is the real, response-scriptable double used
/// by the model tests; it lives in the Tests target and is not visible from
/// the app target these previews compile into, so it cannot be reused here.
private struct PreviewStubAPI: CockpitDaemonAPI {
    struct NotWiredForPreviews: Error {}
    // Two shapes rather than one generic `fail<T>()`: Swift cannot infer
    // `T == Void` at a `try await fail()` call site whose enclosing function
    // itself returns `Void`, so the `async throws` (no return value)
    // methods below route through `failVoid()` instead.
    private func fail<T>() async throws -> T { throw NotWiredForPreviews() }
    private func failVoid() async throws { throw NotWiredForPreviews() }

    func baseURL() -> URL? { nil }
    func cockpitURL() -> URL? { nil }
    func state() async throws -> DaemonState { try await fail() }
    func switchAccount(to id: String) async throws { try await failVoid() }
    func detect() async throws -> [DetectedDir] { try await fail() }
    func adopt(configDir: String) async throws { try await failVoid() }
    func config() async throws -> DaemonConfig { try await fail() }
    func reportMarker(present: Bool) async throws { try await failVoid() }
    func startLogin() async throws -> LoginStart { try await fail() }
    func completeLogin(code: String, state: String) async throws { try await failVoid() }
    func events() -> AsyncThrowingStream<DaemonState, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func schedules() async throws -> [ScheduleRecord] { try await fail() }
    func createSchedule(
        accountID: String, hour: Int, minute: Int, model: String?, effort: String?
    ) async throws -> ScheduleRecord { try await fail() }
    func updateSchedule(id: String, hour: Int, minute: Int) async throws -> ScheduleRecord { try await fail() }
    func deleteSchedule(id: String) async throws { try await failVoid() }
    func history(accountID: String, kind: String, scope: String?) async throws -> [HistorySample] { try await fail() }
    func doctor() async throws -> DoctorReport { try await fail() }
    func analytics(days: Int) async throws -> AnalyticsResponse { try await fail() }
    func statuslinePreview(width: Int, tier: String, config: String?) async throws -> StatuslinePreviewResponse { try await fail() }
    func statuslineConfig() async throws -> StatuslineConfigResponse { try await fail() }
    func putStatuslineConfig(_ cfg: StatuslineConfig) async throws -> StatuslineConfigResponse { try await fail() }
    func statuslineSegments() async throws -> StatuslineSegmentsResponse { try await fail() }
    func license(reveal: Bool) async throws -> LicenseInfo { try await fail() }
    func licenseQuote() async throws -> LicenseQuote { try await fail() }
    func licenseCheckout(rung: String, echo: QuoteEcho, remindDaysBefore: Int?) async throws -> CheckoutHandoff { try await fail() }
    func licenseCancel() async throws -> LicenseCancelResult { try await fail() }
    func licenseRecover(email: String) async throws { try await failVoid() }
    func licenseClaim(token: String) async throws -> LicenseClaimResult { try await fail() }
    func stashAdopt(fingerprint: String, label: String?) async throws -> CockpitAccount { try await fail() }
    func stashDiscard(fingerprint: String) async throws { try await failVoid() }
    func adoptMove(configDir: String, label: String?) async throws -> AdoptMoveResult { try await fail() }
    func cockpitConfig() async throws -> CockpitConfig { try await fail() }
    func putConfig(_ cfg: CockpitConfig) async throws -> CockpitConfig { try await fail() }
    func startBrowserLogin() async throws -> BrowserLoginStart { try await fail() }
    func browserLoginStatus(attempt: String) async throws -> BrowserLoginStatus { try await fail() }
}

/// An `AskMachine` parked on ⑧ (the price screen) — reached by driving
/// `stage` through the same public methods the real UI calls
/// (`askReminder()` then `remindContinue()`), never by reaching into private
/// state, so this preview exercises the identical path a buyer walks.
@MainActor
private func previewPriceAsk() -> AskMachine {
    let ask = AskMachine(
        license: previewLicense(status: "none"), quote: previewQuote, guided: true,
        locale: "en-GB", api: PreviewStubAPI(), onDismiss: {})
    ask.askReminder()
    ask.remindContinue()
    return ask
}

/// An `AskMachine` already active — the ⑨ "Pro is on" screen.
@MainActor
private func previewActiveAsk() -> AskMachine {
    let ask = AskMachine(
        license: previewLicense(status: "trialing", active: true), quote: previewQuote, guided: true,
        locale: "en-GB", api: PreviewStubAPI(), onDismiss: {})
    ask.accountsWatched = 3
    ask.accountsSwitchable = 3
    return ask
}

/// An `AskMachine` on a lapsed license — the paused/trial-restart screen.
@MainActor
private func previewPausedAsk() -> AskMachine {
    let ask = AskMachine(
        license: previewLicense(status: "lapsed"), quote: previewQuote, guided: false,
        locale: "en-GB", api: PreviewStubAPI(), onDismiss: {})
    ask.caughtThisWeek = 4
    return ask
}

#Preview("① wall") {
    OnboardingPreviewFrame {
        WallScreen(step: 0, total: 8, email: "you@example.com", onContinue: {})
    }
}

#Preview("① wall — light") {
    OnboardingPreviewFrame {
        WallScreen(step: 0, total: 8, email: "you@example.com", onContinue: {})
    }
    .preferredColorScheme(.light)
}

#Preview("② blind spot") {
    OnboardingPreviewFrame {
        BlindSpotScreen(
            step: 1, total: 8,
            emails: ["you@example.com", "second@example.dev"],
            tiers: ["you@example.com": "Max 20×", "second@example.dev": "Pro"],
            onContinue: {})
    }
}

#Preview("③ accounts — loading") {
    OnboardingPreviewFrame {
        OnboardingAccountsStepView(
            accounts: [], detected: nil,
            position: StepPosition(step: 2, total: 8),
            continueLabel: "Continue")
    }
}

#Preview("③ accounts — empty (fresh user)") {
    OnboardingPreviewFrame {
        OnboardingAccountsStepView(
            accounts: [], detected: [],
            position: StepPosition(step: 2, total: 8),
            continueLabel: "Continue")
    }
}

#Preview("④ switch demo") {
    OnboardingPreviewFrame {
        OnboardingSwitchStepView(
            step: 3, total: 8, state: previewEmptyState,
            continueLabel: "See your fresh windows", onContinue: {})
    }
}

#Preview("⑤ fresh windows") {
    OnboardingPreviewFrame {
        WindowsScreen(step: 4, total: 8, email: "you@example.com", onContinue: {})
    }
}

#Preview("⑥ receipt") {
    OnboardingPreviewFrame {
        PaywallReceiptScreen(
            quote: previewQuote, accountsSwitchable: 2,
            onContinue: {}, onClose: nil,
            dots: StepPosition(step: 5, total: 8))
    }
}

#Preview("⑦ reminder") {
    OnboardingPreviewFrame {
        PaywallRemindScreen(
            quote: previewQuote, remindDays: .constant(2), offsets: [2, 1],
            locale: "en-GB", now: Date(timeIntervalSince1970: 1_784_650_000),
            onContinue: {}, onClose: nil,
            dots: StepPosition(step: 6, total: 8))
    }
}

#Preview("⑧ price") {
    OnboardingPreviewFrame {
        PaywallPriceScreen(
            ask: previewPriceAsk(),
            copy: LadderLogic.rungCopy(.full, quote: previewQuote, locale: "en-GB")!,
            quote: previewQuote,
            dots: StepPosition(step: 7, total: 9),
            onRecover: {})
    }
}

#Preview("⑧ price — light") {
    OnboardingPreviewFrame {
        PaywallPriceScreen(
            ask: previewPriceAsk(),
            copy: LadderLogic.rungCopy(.full, quote: previewQuote, locale: "en-GB")!,
            quote: previewQuote,
            dots: StepPosition(step: 7, total: 9),
            onRecover: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Pro is on") {
    OnboardingPreviewFrame {
        PaywallActiveScreen(ask: previewActiveAsk(), dots: nil, locale: "en-GB")
    }
}

#Preview("Pro is on — watch-only promote") {
    // Owner 2026-08-12, layer 1: the buyer's auto-added accounts landed
    // watch-only — ⑨ states the split and offers the move right here.
    OnboardingPreviewFrame {
        PaywallActiveScreen(
            ask: previewActiveAsk(), dots: nil, locale: "en-GB",
            watchOnly: [
                WatchOnlyLane(configDir: "/Users/you/.claude-work", email: "you@acme-corp.dev"),
                WatchOnlyLane(configDir: "/Users/you/.claude-side", email: "side@example.dev"),
            ],
            move: ActivationMoveModel(api: PreviewStubAPI()))
    }
}

#Preview("paused (trial ended)") {
    OnboardingPreviewFrame {
        PaywallPausedScreen(
            ask: previewPausedAsk(), dots: nil, quoteFailed: false,
            onRetryQuote: {}, onRecover: {})
    }
}

#Preview("minimum window size (740×520)") {
    OnboardingPreviewFrame(width: 740, height: 520) {
        WallScreen(step: 0, total: 8, email: "you@example.com", onContinue: {})
    }
}

#Preview("minimum window size — receipt (740×520)") {
    OnboardingPreviewFrame(width: 740, height: 520) {
        PaywallReceiptScreen(
            quote: previewQuote, accountsSwitchable: 2,
            onContinue: {}, onClose: nil,
            dots: StepPosition(step: 5, total: 8))
    }
}

#endif
