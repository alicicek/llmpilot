import Foundation

// Native port of web/src/pro/Paywall.tsx's state machine PLUS the checkout
// wiring App.tsx owns around it (onCheckout: App.tsx:332-403) — this pure-
// model chunk is the entry gate of the whole money path, so it reaches one
// layer past Paywall.tsx itself rather than stopping at a UI-only slice
// nothing could actually buy through.
//
// The ask, in three steps (SPEC-127, ladder.ts/Paywall.tsx doc comments):
//   ⑥ RECEIPT  free-vs-Pro boundary, and where the free trial is ANNOUNCED
//   ⑦ REMIND   the timing choice, states no amount
//   ⑧ PRICE    every consent fact, and the only checkout button
// Pressing close on ⑧ IS the decline: the first ✕ surfaces the standing
// lower offer once, the second closes for real. A lapsed license never sees
// that ladder — it is not being asked for the first time. Inside the guided
// first run (SPEC-127 D9, `guided == true`) ⑥/⑦ carry no ✕ at all — ⑧ is the
// corridor's only door.

/// Paywall.tsx's internal `ask` state (Paywall.tsx:170).
enum AskStage: Equatable {
    case receipt
    case remind
    case price
}

/// Paywall.tsx's branch order (Paywall.tsx:198-493), reified so a model-only
/// test can assert "which screen" without a view. Order matters: this is
/// the exact if-chain sequence.
enum AskScreen: Equatable {
    /// license.active — the "Pro is on" facts screen.
    case active
    case remind
    case price
    /// license.status is lapsed/revoked — never sees the decline ladder.
    case paused
    /// No usable quote/copy yet — loading or failed, never an invented price.
    case noTerms
    case receipt
}

@MainActor
final class AskMachine: ObservableObject {
    @Published private(set) var stage: AskStage = .receipt
    /// nil until ⑦ is REACHED. Owner direction 2026-08-08 (deviation from
    /// the web's answer-it-yourself rule): reaching the reminder screen
    /// pre-selects the earliest offset (2 days before) so Continue works
    /// immediately — but the default is set ONLY when the question is on
    /// screen, visibly selected and changeable, and Continue is the buyer
    /// confirming it. Checkout still refuses a nil (a path that never
    /// showed the question still can't post an assumed value).
    @Published var remindDays: Int?
    @Published private(set) var committedAmount: String?
    @Published private(set) var checkoutError: String?
    @Published private(set) var handoffURL: String?
    @Published private(set) var busy = false
    @Published private(set) var quote: LadderQuote?

    /// Paywall.tsx reads `license.active` fresh from props on every render,
    /// so the SAME long-lived `Paywall` instance flips straight to the
    /// "Pro is on" screen once an in-flight checkout activates — no remount.
    /// This was `let` until Phase 4 chunk 4E (integration): AskMachine had
    /// no live equivalent of that prop flow, so the native checkout sheet's
    /// post-close reload (NativeCockpitWindow.swift's `PostCheckoutReload`)
    /// had nothing to push a freshly-activated license INTO. `private(set)`
    /// — only `applyReloadedLicense` below may change it, so `screen`'s
    /// `license.active` check stays the sole source of truth.
    @Published private(set) var license: LicenseInfo
    /// Absent inside the guided first run (SPEC-127 D9: the corridor's only
    /// door is ⑧) — a paywall reopened later from the banner passes it.
    /// Mirrors Paywall.tsx's `dots !== undefined`.
    let guided: Bool
    let locale: String
    /// The web passes these as LIVE props re-computed on every render
    /// (App.tsx:289,544,577 + Onboarding.tsx:204-205). @Published so the
    /// composition root's state observer can push fresh values in and the
    /// screens actually repaint (review 2026-08-08 P1-4: plain vars were
    /// never assigned anywhere in Sources — ⑨ never said "Watching N
    /// accounts", the paused screen never counted the week's catches).
    @Published var caughtThisWeek: Int?
    @Published var accountsWatched: Int?
    @Published var accountsSwitchable: Int?

    /// onDismiss is REQUIRED, not optional — the 1.2.6 paused-screen dead
    /// end (that variant shipped with no ✕ at all) is a P0-class regression
    /// this chunk pins by construction: there is no code path where a
    /// consumer of this model can omit an exit.
    let onDismiss: () -> Void
    /// Called when a checkout attempt is refused for drifted terms
    /// (`quote_stale`) so the caller re-fetches — App.tsx's `reloadQuote`
    /// (== `useQuote`'s `reload`, the same function `onRetryQuote` wires).
    var reloadQuote: () -> Void = {}
    /// Wall clock for `LadderLogic.chargeInstant` — a test fake pins it;
    /// the default really reads the clock (AddAccountSheet.swift's `now`
    /// pattern).
    var now: () -> Date = Date.init

    private let api: CockpitDaemonAPI & DaemonAPI
    private var seenQuote: LadderQuote?
    private var checkoutInFlight = false

    init(
        license: LicenseInfo,
        quote: LadderQuote?,
        guided: Bool,
        locale: String,
        api: CockpitDaemonAPI & DaemonAPI,
        onDismiss: @escaping () -> Void
    ) {
        self.license = license
        self.guided = guided
        self.locale = locale
        self.api = api
        self.onDismiss = onDismiss
        // Mirrors `useRef<Quote | null>(quote)`'s initial value — set
        // directly, NOT through `setQuote`, so mounting on an already-loaded
        // quote never fires the terms-changed bounce.
        self.quote = quote
        self.seenQuote = quote
    }

    var paused: Bool { license.status == "lapsed" || license.status == "revoked" }

    /// Paywall.tsx:250-254 — which reminder offsets THIS trial can even
    /// offer. A short enough trial leaves nothing to pick.
    var remindOffsets: [Int] {
        guard let quote else { return [] }
        return [2, 1].filter { $0 < quote.trialDays }
    }

    /// The one rung being purchased. Public: the screens chunk renders this
    /// directly (OfferCard's `copy` prop).
    var offerCopy: RungCopy? {
        // One price, always (owner 2026-08-11). The corridor used to be able
        // to swap in a cheaper `.discountTrial` rung once the buyer
        // "declined"; that ladder is gone, so the price a buyer is shown
        // first is the price they are shown.
        quote.flatMap { LadderLogic.rungCopy(.full, quote: $0, locale: locale) }
    }

    /// Paywall.tsx's full branch order (Paywall.tsx:198-493).
    var screen: AskScreen {
        if license.active { return .active }
        if stage == .remind, quote != nil { return .remind }
        if stage == .price, offerCopy != nil, quote != nil { return .price }
        if paused { return .paused }
        if offerCopy == nil || quote == nil { return .noTerms }
        return .receipt
    }

    /// Paywall.tsx:172-173,300-491 — receipt/remind hide the ✕ ONLY while
    /// guided; price (and the no-terms/paused screens) always show it once
    /// `onDismiss` exists, which is now unconditionally true.
    var closeButtonVisible: Bool {
        switch screen {
        case .active: return false
        case .receipt, .remind: return !guided
        case .price, .noTerms, .paused: return true
        }
    }

    /// Paywall.tsx:255-262 `askReminder`.
    func askReminder() {
        if !remindOffsets.isEmpty {
            // Owner 2026-08-08: default to the earliest reminder (offsets
            // are [2, 1] → 2 days before), selected on screen where the
            // buyer can see and change it before confirming with Continue.
            if remindDays == nil { remindDays = remindOffsets.first }
            stage = .remind
        } else {
            remindDays = 1
            stage = .price
        }
    }

    /// A close control CLOSES — always, from any screen (owner 2026-08-09).
    /// This used to run a decline ladder: the first ✕ silently swapped in a
    /// lower offer and only the second one closed, which is a dark pattern —
    /// the way out of a paywall must not be a sales step. The ladder was
    /// then made an explicit "See a lower price" button, and removed
    /// outright on 2026-08-11: the corridor quotes ONE price.
    func close() {
        onDismiss()
    }

    /// Paywall.tsx:288-291 `onContinue` on the Remind screen.
    func remindContinue() {
        stage = .price
    }

    /// Paywall.tsx:180-196 `termsSig` bounce — call whenever the CALLER's
    /// quote input changes (a fresh fetch, a reload, a TTL re-quote). A
    /// quote whose TERMS changed restarts the ask at ⑥: the buyer must walk
    /// the new terms rather than sit on a commit screen quoting the old
    /// ones. Compared by CONTENT (`termsSig`), not identity — a routine
    /// re-quote with unchanged numbers must not bounce the buyer off the
    /// commit screen. GUARDED by a live `handoffURL`: never while a payment
    /// window is open, or the reload would orphan that Session's activation
    /// poll.
    func setQuote(_ newQuote: LadderQuote?) {
        if let newQuote, let seen = seenQuote, handoffURL == nil,
            LadderLogic.termsSig(newQuote) != LadderLogic.termsSig(seen)
        {
            stage = .receipt
        }
        if let newQuote { seenQuote = newQuote }
        quote = newQuote
    }

    /// Phase 4 chunk 4E (integration) — the native equivalent of Paywall.tsx
    /// reacting live to an activated `license` prop: the checkout sheet has
    /// no page reload for an SSE reconnect to ride, so the composition root
    /// actively reloads GET /v1/license once the sheet closes and pushes the
    /// result here. A no-op unless the reload landed an ACTIVE license —
    /// pushing a still-inactive refresh would be pointless churn, and
    /// `screen`'s other branches (paused, remind, price) must keep reading
    /// whatever `stage` state the buyer was already in.
    func applyReloadedLicense(_ newLicense: LicenseInfo) {
        guard newLicense.active else { return }
        license = newLicense
    }

    /// Called by the composition root the moment the checkout SHEET closes.
    /// The web deliberately KEEPS `handoffURL` after `location.assign` (App.
    /// tsx:370-374): there the payment surface is a separate tab that may
    /// well still be open, so the "Checkout is open in the payment window"
    /// line stays true. Natively the sheet IS the payment surface — once it
    /// closes that line is a lie, and a stale non-nil value also means a
    /// second checkout returning the IDENTICAL url never fires the view's
    /// `.onChange` re-present (review 2026-08-08 P1-5). Clearing here keeps
    /// the copy honest and makes every later handoff a real nil→url change.
    /// The re-click-orphans-the-poll hazard the web note warns about is the
    /// sanctioned "start again here" path on both sides; the paid case is
    /// covered by the live license push (`applyReloadedLicense`) flipping
    /// this machine to `.active`, which unrenders the button.
    func checkoutSheetClosed() {
        handoffURL = nil
    }

    /// Paywall.tsx:339-353 + App.tsx:332-403 `onCheckout` — the price
    /// screen's checkout button PLUS the wire call and its error mapping.
    /// Checkout must never post an assumed reminder default: refusing
    /// SILENTLY would leave a live-looking button that does nothing, so an
    /// unanswered reminder redirects to the question instead. Single-flight:
    /// a double-click must not create two billable Checkout Sessions.
    ///
    /// NOT reachable before the price screen: the web source has no
    /// explicit guard for this (the button simply doesn't render anywhere
    /// else), but this model has no view to hide it behind — the guard
    /// below is that same "no price before receipt" invariant made
    /// explicit and unconditional.
    func pressCheckout() async {
        guard screen == .price, let copy = offerCopy else { return }
        guard let remindDays else {
            askReminder()
            return
        }
        guard !checkoutInFlight else { return }
        checkoutInFlight = true
        busy = true
        checkoutError = nil
        do {
            let result = try await api.licenseCheckout(
                rung: copy.rung.rawValue, echo: copy.echo, remindDaysBefore: remindDays)
            committedAmount = copy.amount
            handoffURL = result.url
        } catch {
            if let apiErr = error as? ApiError, apiErr.code == "quote_stale" {
                // The worker refused terms that drifted from what was
                // shown. Never auto-retry a purchase: refresh the quote,
                // and require a fresh human click on the new terms.
                reloadQuote()
                checkoutError = "The price or trial terms changed — review the new terms and confirm."
            } else {
                // Known codes get their remedy copy; otherwise the
                // transport's own message; otherwise a generic fallback —
                // same ladder as App.tsx:398-401.
                let mapped = (error as? ApiError).flatMap { LadderLogic.licenseErrorCopy($0.code) }
                checkoutError =
                    mapped ?? (error as? LocalizedError)?.errorDescription ?? "That didn't take — try again."
            }
        }
        checkoutInFlight = false
        busy = false
    }
}

// MARK: - Settings → License (web/src/pro/LicenseSection.tsx)

/// Ported as its own plain @MainActor model, colocated in this file: this
/// chunk's brief names exactly three model files (LadderLogic/
/// OnboardingModel/AskMachine), and the money path's remaining mutations
/// (one-click cancel, recover-by-email, claim-by-code) need a model-level
/// home for their own defect-class tests. `AskMachine` already reaches past
/// Paywall.tsx into App.tsx's checkout wiring by design (see the file
/// header), so the rest of the money path's writes sit naturally beside it.
/// The Settings → License SCREEN itself (LicenseSection.tsx's UI, its
/// confirm/cancel toggle, the reveal/copy affordance) is out of scope for
/// this pure-model chunk.
@MainActor
final class LicenseAccountModel: ObservableObject {
    @Published private(set) var busy = false
    /// LicenseSection.tsx's `note` — the ONE line of status/refusal copy
    /// shown after a cancel/recover/claim attempt.
    @Published private(set) var note: String?
    /// LicenseSection.tsx's `revealed` (LicenseSection.tsx:51,117-124) — the
    /// FULL license id once `reveal()` has fetched it. `nil` renders the
    /// masked id and the "Show" affordance; non-nil swaps it for "Copy".
    /// Phase 4 chunk 4E (integration, gap ①): LicenseAccountModel shipped
    /// from chunk 4A with no wire method for this — added here.
    @Published private(set) var revealedID: String?

    private let api: CockpitDaemonAPI & DaemonAPI
    /// LicenseSection.tsx's `onReload` — re-fetches GET /v1/license so
    /// status reflects the write. Called after a cancel and after a
    /// successful claim, never after recover (recover never changes THIS
    /// Mac's status; its uniform copy is the only feedback).
    var onReload: () -> Void = {}

    init(api: CockpitDaemonAPI & DaemonAPI) {
        self.api = api
    }

    /// LicenseSection.tsx `doCancel` (consumer-law checklist c): one click,
    /// no confirmation dance modeled here — the confirm/keep toggle is a
    /// view-only affordance (LicenseSection.tsx:46,138-161); this is the
    /// mutation the "Cancel the trial" button ultimately fires.
    /// Returns whether the write LANDED — the card clears its confirm/input
    /// state only on success, exactly like LicenseSection.tsx's clears
    /// living INSIDE the `try` block (:75,:92,:106; review 2026-08-08 P2-8:
    /// clearing unconditionally wiped the user's typed email on a network
    /// blip and disarmed the confirm box on a failed cancel).
    @discardableResult
    func cancel() async -> Bool {
        busy = true
        note = nil
        var landed = false
        do {
            _ = try await api.licenseCancel()
            landed = true
            onReload()
        } catch {
            note = (error as? LocalizedError)?.errorDescription ?? "Cancel could not complete — try again."
        }
        busy = false
        return landed
    }

    /// LicenseSection.tsx `reveal` (LicenseSection.tsx:117-124): fetches the
    /// FULL license id (GET /v1/license?reveal=1, Bearer-authed —
    /// `CockpitDaemonAPI.license(reveal:)`) and holds it for the card's Copy
    /// button. Any failure — network, decode, a 403 from a stale/absent
    /// install token — collapses to the SAME one-line remedy the web shows,
    /// never a raw error: the reveal affordance is a convenience, not a
    /// diagnostic surface.
    func reveal() async {
        do {
            let full = try await api.license(reveal: true)
            revealedID = full.licenseID ?? full.licenseIDMasked
        } catch {
            note = "Could not read the license id."
        }
    }

    /// LicenseSection.tsx `doRecover`: UNIFORM copy whether or not the
    /// address is on file — no enumeration.
    @discardableResult
    func recover(email: String) async -> Bool {
        busy = true
        note = nil
        var landed = false
        do {
            try await api.licenseRecover(email: email)
            landed = true
            note = "If that email has a purchase, a recovery link is on its way. Open it on this Mac."
        } catch {
            note = (error as? LocalizedError)?.errorDescription ?? "Could not send the email — try again."
        }
        busy = false
        return landed
    }

    /// LicenseSection.tsx `doClaim`.
    @discardableResult
    func claim(token: String) async -> Bool {
        busy = true
        note = nil
        var landed = false
        do {
            _ = try await api.licenseClaim(token: token)
            landed = true
            note = "Restored — Pro is back on."
            onReload()
        } catch {
            let mapped = (error as? ApiError).flatMap { LadderLogic.licenseErrorCopy($0.code) }
            note = mapped ?? (error as? LocalizedError)?.errorDescription ?? "This code is invalid or expired."
        }
        busy = false
        return landed
    }

    /// LicenseSection.tsx's `revealed`/`note` are component-local `useState`
    /// (:51) — destroyed with the dialog, so every Settings open starts
    /// masked with a fresh "Show" button. This model outlives the sheet (a
    /// window-scoped @StateObject), so the composition root calls this on
    /// sheet dismiss to restore that lifecycle (review 2026-08-08 P1-6: one
    /// click otherwise revealed the full id for every later open all
    /// session, and stale note copy carried across opens).
    func resetTransientUI() {
        revealedID = nil
        note = nil
    }
}
