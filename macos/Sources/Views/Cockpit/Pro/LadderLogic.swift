import Foundation

// Native ports of the ladder's PURE logic. Ground truth is the SHIPPED web
// source, not spec prose — plans/SPEC-127's 2026-08-06 amendment (pair-fold,
// back-arrows, 62→100@50ms) is unimplemented in web/src, so it is NOT ported
// here either:
//
//   web/src/pro/ladder.ts    → Rung, QuoteEcho, LadderQuote, rungCopy,
//                               formatAmount, localAmount, chargeInstant,
//                               remindDate, statementNote
//   web/src/pro/errors.ts    → licenseErrorCopy
//   web/src/pro/Paywall.tsx  → termsSig
//   web/src/shell/FirstRun.tsx → groupByEmail, sessionPercent
//
// No screen ships in this chunk — OnboardingModel.swift and AskMachine.swift
// are the state machines that call into these pure functions.

// MARK: - Rung / QuoteEcho (api.ts `Rung`/`QuoteEcho`; license.go validRungs)

enum Rung: String, Equatable, CaseIterable {
    case full
    case discountTrial = "discount_trial"
    case nocardTrial = "nocard_trial"
}

/// QuoteEcho ports api.ts's `QuoteEcho` — the exact consent statement the
/// buyer saw, echoed into checkout so the worker can refuse terms that
/// drifted (409 `quote_stale`, license.go handleLicenseCheckout:279-292).
/// A field that never resolved (no price for this currency) is OMITTED
/// from the wire body, mirroring JS's `JSON.stringify` dropping `undefined`
/// keys — hence the hand-written `encode(to:)` instead of the synthesized
/// one, which would otherwise send `null`.
struct QuoteEcho: Equatable, Encodable {
    var trialDays: Int?
    var currency: String?
    var amountMinor: Int?

    enum CodingKeys: String, CodingKey {
        case trialDays = "trial_days"
        case currency
        case amountMinor = "amount_minor"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(trialDays, forKey: .trialDays)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(amountMinor, forKey: .amountMinor)
    }
}

/// LadderQuote ports api.ts's `Quote` — the VALIDATED terms the ladder
/// actually renders. `LicenseQuote` (CockpitModels.swift) is the wire proxy
/// of a THIRD PARTY's body (the worker's `/v1/quote`, forwarded verbatim by
/// license.go:420-438) — every field optional there on purpose. This is the
/// non-optional shape fetchQuote()'s validation (api.ts:526-541) produces,
/// or nil when the terms cannot be honestly stated.
struct LadderQuote: Equatable {
    var trialDays: Int
    var chargeDate: Date
    var pricesFull: [String: Int]
    var pricesDiscount: [String: Int]

    /// Mirrors api.ts fetchQuote's guard: an integer trial length, a
    /// parseable charge date, and at least one price in EACH rung's price
    /// map — a paywall must never render "Invalid Date" or an invented
    /// price. Date parsing already happened at JSON-decode time
    /// (`LicenseQuote.chargeDate` is nil on an unparseable string), which is
    /// JS's `Number.isNaN(Date.parse(...))` check done a step earlier.
    static func validated(from quote: LicenseQuote) -> LadderQuote? {
        guard let trialDays = quote.trialDays,
              let chargeDate = quote.chargeDate,
              let prices = quote.prices,
              !prices.full.isEmpty,
              !prices.discount.isEmpty
        else { return nil }
        return LadderQuote(
            trialDays: trialDays, chargeDate: chargeDate,
            pricesFull: prices.full, pricesDiscount: prices.discount)
    }
}

struct LocalAmount: Equatable {
    var text: String
    var approx: Bool
    var echo: QuoteEcho
}

/// RungCopy ports api.ts's `RungCopy` — one offer's consent copy, built from
/// the quote. `echo` is the exact terms shown, echoed back into checkout.
struct RungCopy: Equatable {
    var rung: Rung
    var headline: String
    /// One-sentence support line under the headline.
    var lede: String
    var amount: String
    /// The full-rung amount shown struck through beside a decline-offer price.
    var strikeAmount: String?
    var approx: Bool
    /// The price-line suffix (trial length · charged once · lifetime).
    var beside: String
    var cta: String
    var echo: QuoteEcho
}

/// FirstRun.tsx's `Group` (shell/FirstRun.tsx:17-22).
struct EmailGroup: Equatable {
    var email: String
    var dirs: [DetectedDir]
    /// The folder an add registers — ~/.claude when the identity holds it.
    var primary: DetectedDir
}

enum LadderLogic {
    /// ladder.ts STATEMENT_NOTE.
    static let statementNote = "Appears on your statement as LINK.COM* LLMPILOT.DEV."

    // MARK: - money copy (ladder.ts)

    /// ladder.ts `formatAmount`: renders minor units for the buyer's locale
    /// with the same `Intl.NumberFormat` rule the worker's checkout page
    /// uses, so the paywall and the payment page always agree on the string.
    static func formatAmount(locale: String, currency: String, amountMinor: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.locale = Locale(identifier: locale)
        nf.currencyCode = currency.uppercased()
        let digits = nf.maximumFractionDigits
        let amount = Double(amountMinor) / pow(10.0, Double(digits))
        return nf.string(from: NSNumber(value: amount)) ?? String(format: "%.\(digits)f", amount)
    }

    /// ladder.ts `localAmount`: picks the quoted currency GB/US buyers are
    /// charged exactly. Other locales pay Stripe's converted amount at the
    /// payment page, so the figure is marked approximate rather than
    /// promising a number it can't guarantee (F7).
    ///
    /// DEVIATION (documented, low-risk): the JS fallback walks
    /// `Object.keys(amounts)` in INSERTION order when neither the locale's
    /// exact currency nor "gbp" resolves. `LicenseQuote.Prices` already
    /// decodes into a plain Swift `Dictionary` (CockpitModels.swift) —
    /// insertion order is lost before this function ever sees it — so this
    /// walks the keys SORTED instead, which is at least deterministic
    /// across runs. Every shipped quote carries "gbp" (matched before this
    /// fallback is ever reached), so this only changes behavior for a
    /// hypothetical THIRD, unlisted currency that no test exercises.
    static func localAmount(_ amounts: [String: Int], locale: String) -> LocalAmount? {
        // ladder.ts matches `navigator.language` — BCP-47, hyphenated
        // ("en-GB"). The native call sites pass `Locale.current.identifier`,
        // which is ICU-form: UNDERSCORED ("en_GB"), possibly carrying an
        // @-keyword tail ("en_US@rg=gbzzzz"). Normalize to the BCP-47 shape
        // the matching below (and the web vectors) speak, or every native
        // buyer falls through to the approx-gbp fallback (review 2026-08-08
        // P0-2: GB buyers saw "≈" on an exact charge; US buyers were quoted
        // gbp entirely).
        let loc = (locale.lowercased()
            .split(separator: "@", maxSplits: 1).first.map(String.init) ?? "")
            .replacingOccurrences(of: "_", with: "-")
        let exact: String? =
            (loc == "en-us" || loc.hasSuffix("-us")) ? "usd"
            : (loc == "en-gb" || loc.hasSuffix("-gb")) ? "gbp" : nil
        var candidates: [String] = exact.map { [$0] } ?? []
        candidates.append("gbp")
        candidates.append(contentsOf: amounts.keys.sorted())
        for currency in candidates {
            guard let minor = amounts[currency] else { continue }
            return LocalAmount(
                text: formatAmount(locale: locale, currency: currency, amountMinor: minor),
                approx: currency != exact,
                echo: QuoteEcho(trialDays: nil, currency: currency, amountMinor: minor))
        }
        return nil
    }

    /// ladder.ts `chargeInstant`: derived from the RENDER-TIME clock plus
    /// `trial_days`, never the quote's `charge_date` — a quote fetched at
    /// app open can be hours old by the time the paywall shows, and Stripe
    /// anchors the trial at checkout COMPLETION, so "now + trial_days" is
    /// the freshest honest date. `now` is REQUIRED (no default): every call
    /// site injects the clock explicitly rather than this pure function
    /// reaching for the wall clock on its own.
    static func chargeInstant(quote: LadderQuote, now: Date) -> Date {
        now.addingTimeInterval(Double(quote.trialDays) * 24 * 60 * 60)
    }

    /// ladder.ts `remindDate`: the reminder's calendar date, from the
    /// quoted charge instant and the buyer's chosen offset.
    static func remindDate(chargeInstant: Date, daysBefore: Int, locale: String) -> String {
        let t = chargeInstant.addingTimeInterval(-Double(daysBefore) * 24 * 60 * 60)
        let df = DateFormatter()
        df.locale = Locale(identifier: locale)
        df.setLocalizedDateFormatFromTemplate("d MMMM")
        return df.string(from: t)
    }

    /// ladder.ts `rungCopy`. nil means the quote cannot state THIS offer's
    /// price — the caller renders the retry state, never a paywall that
    /// hides the amount. `.nocardTrial` is unlisted: the worker still sells
    /// it (support/CLI), the paywall never renders it (ladder.ts:130-133).
    static func rungCopy(_ rung: Rung, quote: LadderQuote, locale: String) -> RungCopy? {
        let days = quote.trialDays
        switch rung {
        case .full:
            guard let a = localAmount(quote.pricesFull, locale: locale) else { return nil }
            return RungCopy(
                rung: .full,
                // Trailing period matches every other corridor headline
                // (audit 2026-08-11: ⑧ was the only one without it).
                headline: "Try the autopilot free for \(days) days.",
                lede: "It switches before the wall, revives stale accounts, and fires your scheduled windows — you never lose your place mid-thought.",
                amount: a.text, strikeAmount: nil, approx: a.approx,
                beside: "after \(article(days)) \(days)-day free trial · charged once · yours for life",
                cta: "Start the \(days)-day free trial",
                echo: QuoteEcho(trialDays: days, currency: a.echo.currency, amountMinor: a.echo.amountMinor))
        case .discountTrial:
            guard let a = localAmount(quote.pricesDiscount, locale: locale) else { return nil }
            let full = localAmount(quote.pricesFull, locale: locale)
            // The struck reference price only renders when it is genuinely
            // higher — under an active launch window both rungs quote the
            // same amount, and striking a price equal to the offer would be
            // a fake markdown (the class VOICE bans). Same-currency only,
            // the `hasLowerOffer` rule (S6 review F6): minor units from two
            // currencies don't compare, and a cross-currency strike would
            // be a nonsense markdown.
            let strike: String?
            if let full, full.echo.currency == a.echo.currency,
                let fullMinor = full.echo.amountMinor, let aMinor = a.echo.amountMinor,
                fullMinor > aMinor
            {
                strike = full.text
            } else {
                strike = nil
            }
            return RungCopy(
                rung: .discountTrial,
                // N6 (audit 2026-08-17): the full stop. Every other
                // corridor headline ends with one — "You know this
                // moment.", "We found 1 account.", "Try the autopilot free
                // for N days." — and this was the single exception, on the
                // second money screen.
                headline: "Same trial, lower price.",
                // the win-back rung states the new price and that
                // it is the last offer — and stays anti-urgency ("no
                // deadline on it"), per the wave brief.
                lede: "\(a.text) is the lower price, and the last offer — no deadline on it. Same \(days)-day free trial, same lifetime license.",
                amount: a.text, strikeAmount: strike, approx: a.approx,
                beside: "after \(article(days)) \(days)-day free trial · charged once · yours for life",
                cta: "Start the trial at \(a.text)",
                echo: QuoteEcho(trialDays: days, currency: a.echo.currency, amountMinor: a.echo.amountMinor))
        case .nocardTrial:
            return nil
        }
    }

    /// "a" or "an" for the trial length. `effectiveTrialDays` accepts ANY
    /// integer >= 3 from the worker's env, so the article cannot be baked
    /// into the string: 8, 11 and 18 all read "a 8-day free trial" on the
    /// screen that asks for money. Caught 2026-08-18 — and nearly written
    /// off, because the trial actually on sale is 4, where the hardcoded
    /// "a" happens to be right. Config-reachable, so it is fixed rather
    /// than hidden.
    ///
    /// English takes the article from the SOUND, not the letter: 8 and 18
    /// are "an" (eighteen, eight), 11 is "an" (eleven), everything else
    /// this can serve is "a".
    static func article(_ days: Int) -> String {
        let leading = String(describing: days).first
        if days == 11 || days == 18 { return "an" }
        return leading == "8" ? "an" : "a"
    }

    /// Paywall.tsx:246-249 `hasLowerOffer`, resolved for the buyer's OWN
    /// locale (the same `localAmount` walk both rungs render through): the
    /// win-back offer only exists while it is genuinely LOWER — under an
    /// active launch window full already sells at the discount amount, and
    /// "Same trial, lower price" over an equal price would be a lying
    /// screen. The rung gates both arming the rung on a ✕ and rendering it
    /// on this one predicate.
    static func hasLowerOffer(quote: LadderQuote, locale: String) -> Bool {
        guard let discount = localAmount(quote.pricesDiscount, locale: locale),
            let full = localAmount(quote.pricesFull, locale: locale),
            let discountMinor = discount.echo.amountMinor,
            let fullMinor = full.echo.amountMinor
        else { return false }
        // Minor units only compare within ONE currency — a quote whose two
        // price maps resolve to different currencies for this locale can't
        // honestly claim "lower", so it has no offer (stricter than the web
        // twin's blind minor-unit compare; every shipped quote carries the
        // same currencies in both maps, so this only changes a malformed
        // hypothetical).
        return discount.echo.currency == full.echo.currency && discountMinor < fullMinor
    }

    /// Paywall.tsx's `termsSig` (Paywall.tsx:188): identifies terms by
    /// CONTENT, not object identity — a routine 15-minute re-quote must not
    /// bounce the ask back to the receipt if the numbers are unchanged.
    ///
    /// Not byte-identical to JS's `` `${q.trial_days}|${JSON.stringify(q.prices)}` ``
    /// — by the time this runs, `quote.pricesFull/pricesDiscount` are
    /// already plain Swift `Dictionary`s (CockpitModels.swift decodes
    /// `prices` that way), so the wire's key order is already gone. Sorted
    /// instead: the only property this signature needs is that equal
    /// content compares equal, which sorting preserves.
    static func termsSig(_ quote: LadderQuote) -> String {
        func sig(_ m: [String: Int]) -> String {
            m.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        }
        return "\(quote.trialDays)|full:{\(sig(quote.pricesFull))}|discount:{\(sig(quote.pricesDiscount))}"
    }

    // MARK: - refusal copy (errors.ts)

    /// errors.ts `licenseErrorCopy` — one place maps licensing refusal
    /// codes to copy. VOICE.md register: say what happened, then what to
    /// do next — never a bare code, never blame.
    ///
    /// `quote_stale` is deliberately ABSENT: it never renders through this
    /// map. App.tsx's checkout handler (App.tsx:385-392) branches on that
    /// code BEFORE reaching here and shows its own remedy line instead —
    /// ported onto `AskMachine.pressCheckout`'s quote-stale branch.
    static func licenseErrorCopy(_ code: String?) -> String? {
        switch code {
        case "seat_limit_reached":
            return "Seat limit reached — this license is already on its maximum number of Macs. Restore by email to move Pro to this one."
        case "trial_email_used":
            return "That email already used the free trial. Pick a paid plan to turn the autopilot on."
        case "install_not_activated":
            return "This Mac is not activated for that license. Restore by email to activate it here."
        case "auth_required":
            return "This page opened without its session token. Reopen the cockpit from the menu bar, or run `llmpilot open`."
        case "invalid_input":
            // The realistic cause on the checkout path: this build renders
            // terms the worker no longer sells (the consent echo refused to
            // bind).
            return "This version shows outdated terms. Update llmpilot from the menu bar, then try again."
        case "already_licensed":
            // The worker's one-live-purchase-per-install guard (1.3.4): the
            // local store lagged a purchase that already fulfilled — point
            // at the recovery that re-serves the existing grant, never at a
            // second checkout.
            return "This Mac's license already has Pro. If it isn't showing, open Settings → License → Restore by email."
        default:
            return nil
        }
    }

    // MARK: - FirstRun.tsx

    /// FirstRun.tsx `groupByEmail` (shell/FirstRun.tsx:24-36) — GROUND
    /// TRUTH: a literal, case-SENSITIVE `Map` keyed on `d.email`. Two
    /// folders with the exact same email string collapse into one row (one
    /// shared limit; `primary` is the dir ending "/.claude", else the first
    /// one seen). This does NOT case-fold — that dedupe is a DIFFERENT
    /// function one level up (Onboarding.tsx's `identities`, ported as
    /// `OnboardingModel.identities`: case-insensitive, first-seen spelling
    /// wins). A same-person-different-case pair reaches THIS function as
    /// two separate rows, exactly as shipped.
    static func groupByEmail(_ candidates: [DetectedDir]) -> [EmailGroup] {
        var order: [String] = []
        var byEmail: [String: [DetectedDir]] = [:]
        for d in candidates {
            if byEmail[d.email] == nil { order.append(d.email) }
            byEmail[d.email, default: []].append(d)
        }
        return order.map { email in
            let dirs = byEmail[email] ?? []
            let primary = dirs.first { $0.configDir.hasSuffix("/.claude") } ?? dirs[0]
            return EmailGroup(email: email, dirs: dirs, primary: primary)
        }
    }

    /// FirstRun.tsx `sessionPercent` (shell/FirstRun.tsx:44-50): the freshly
    /// added row's REAL gauge percentage — nil when the group's identity
    /// isn't in the fleet at all, 0 when it is but carries no session/
    /// five_hour bucket yet, else the rounded live percent.
    static func sessionPercent(accounts: [AccountState], group: EmailGroup) -> Int? {
        let acct =
            accounts.first { $0.configDir == group.primary.configDir }
            ?? accounts.first { $0.email == group.email }
        guard let acct else { return nil }
        if let bucket = acct.snapshot?.buckets.first(where: { $0.kind == "session" || $0.kind == "five_hour" }) {
            return Int(bucket.percent.rounded())
        }
        return 0
    }
}
