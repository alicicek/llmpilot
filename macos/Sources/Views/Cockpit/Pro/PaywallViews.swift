import SwiftUI

// Native screens for AskMachine.swift (web/src/pro/Paywall.tsx +
// web/src/pro/Receipt.tsx + web/src/pro/Remind.tsx). Every screen is driven
// entirely by `AskMachine`'s published state — this file adds NO
// sequencing/validation of its own beyond the two narrow exceptions called
// out at their call sites (the Remind screen's single-offset auto-pick,
// which is Remind.tsx's OWN view-level effect in the web source too, not
// Paywall.tsx's; and simple string/date COMPOSITION identical to the JSX
// these screens port, e.g. the "Pro is on" facts list).
//
// Screen → AskScreen map (ground truth: Paywall.tsx's if-chain, :198-493):
//   .active  → PaywallActiveScreen   (Paywall.tsx:198-236, "Pro is on")
//   .remind  → PaywallRemindScreen   (pro/Remind.tsx)
//   .price   → PaywallPriceScreen    (Paywall.tsx:298-376)
//   .paused  → PaywallPausedScreen   (Paywall.tsx:378-442)
//   .noTerms → PaywallNoTermsScreen  (Paywall.tsx:444-481)
//   .receipt → PaywallReceiptScreen  (pro/Receipt.tsx)

// MARK: - shared bits

/// One dot-strip position — `StepDots.tsx` ported without labels (position
/// only, screens name themselves).
struct StepPosition: Equatable {
    var step: Int
    var total: Int
}

/// `Paywall.tsx`'s `dots` prop (`{ base, total } | undefined`) — `nil` means
/// "not a guided run" (`guided == false`), matching `dots !== undefined` in
/// the web source. `position(for:base:)` below adds the same per-screen
/// OFFSET the web JSX adds inline — except ⑨, which no longer counts (N8).
struct PaywallDots: Equatable {
    var base: Int
    var total: Int

    /// Whether the stage should still RESERVE the progress row's height on
    /// a screen that shows no dots. Only the guided arrival screen: N8
    /// dropped `.active`'s position, and `OnboardingStage` omits the row
    /// AND its gap when `position` is nil — so the headline jumped up by
    /// the row plus its gap on the one screen that confirms a payment —
    /// undoing the fixed-height row's whole reason for existing (see
    /// `OnboardingProgressRow`'s doc comment: "let the indicator drift to a
    /// different on-screen position screen to screen"). The NON-guided
    /// reopened paywall keeps collapsing: it never shows a strip on any
    /// screen, so there is no rhythm to hold.
    static func reservesProgressRow(for screen: AskScreen, base dots: PaywallDots?) -> Bool {
        dots != nil && screen == .active
    }

    /// The per-screen dot OFFSET Paywall.tsx's JSX adds inline (`dots.base
    /// + 1` for ⑦, `+2` for ⑧; every other screen uses `base` unmodified).
    /// Pulled out as a pure, directly-testable function — the container
    /// view (`PaywallView`) calls this instead of repeating the per-case
    /// arithmetic inline.
    ///
    /// N8 (audit 2026-08-17): `.active` gets NO position, where the web
    /// gave it `base + 3`. "Pro is on" is only reachable by buying, so
    /// counting it made the strip overstate the flow for every person who
    /// declines — they walk to `.price` and stop. `.price` is now the last
    /// dot, and the arrival screen shows no strip at all. See
    /// `OnboardingModel.total`, which drops to `phases.count + 3` to match.
    static func position(for screen: AskScreen, base dots: PaywallDots?) -> StepPosition? {
        guard let dots else { return nil }
        switch screen {
        case .active: return nil
        case .remind: return StepPosition(step: dots.base + 1, total: dots.total)
        case .price: return StepPosition(step: dots.base + 2, total: dots.total)
        case .paused, .noTerms, .receipt: return StepPosition(step: dots.base, total: dots.total)
        }
    }
}

/// The price screen's bottom-left control — "Choose the reminder day" or
/// nothing, given the current reminder state. Pulled out of
/// `PaywallPriceScreen` as a pure function so tests can pin the SELECTION
/// without rendering or pressing anything.
enum PriceBottomControl: Equatable {
    case chooseReminder
    case none

    /// The `.noThanks` case went with the decline ladder (owner 2026-08-11):
    /// it only ever appeared once a buyer had "declined" into a lower rung,
    /// and there is no lower rung any more. Leaving the paywall is the ✕.
    ///
    /// Fresh-user audit 2026-08-16 (F11): `.changeReminder` also went — once
    /// the reminder is answered, re-picking it from the price screen's
    /// footer is a redundant affordance (the choice is made once, on the
    /// reminder screen); the footer settles down to "Restore a purchase"
    /// alone. `.chooseReminder` stays: it's the FIRST choice, not a change.
    static func resolve(remindDays: Int?, remindOffsets: [Int]) -> PriceBottomControl {
        if !remindOffsets.isEmpty, remindDays == nil { return .chooseReminder }
        return .none
    }
}

/// Paywall.tsx:426-435 — the paused screen's primary CTA: full trial-length
/// copy once a quote/offer exist, else the generic fallback (also used to
/// decide whether the button is disabled: `.turnOn` only renders while
/// `offerCopy == nil`, matching `disabled={!fullCopy}`).
enum PausedCTA: Equatable {
    case tryFree(days: Int)
    case turnOn

    static func resolve(hasOfferCopy: Bool, quote: LadderQuote?) -> PausedCTA {
        if hasOfferCopy, let quote { return .tryFree(days: quote.trialDays) }
        return .turnOn
    }

    var label: String {
        switch self {
        case .tryFree(let days): return "Try it free for \(days) days"
        case .turnOn: return "Turn on the autopilot"
        }
    }
}

/// Paywall.tsx:206-212 — the "Pro is on" facts list. Never an invented
/// fact: a missing input (a reload dropped the committed amount) omits its
/// row, exactly as the web source does.
enum PaywallActiveFacts {
    static func build(
        accountsWatched: Int?, chargeDate: Date?, remindDays: Int?, committedAmount: String?, locale: String,
        watchOnly: Int = 0
    ) -> [String] {
        var out: [String] = []
        if let watched = accountsWatched, watched > 0 {
            // The watch-only split is stated AT activation (owner
            // 2026-08-12, layer 1): "Watching 2 accounts" alone read as
            // "the autopilot can use both", which is false while any of
            // them is pinned.
            let split = watchOnly > 0 ? " · \(watchOnly) watch-only" : ""
            out.append("Watching \(watched) \(watched == 1 ? "account" : "accounts")\(split)")
        }
        out.append("Switches you before the wall")
        if let chargeDate, let remindDays {
            out.append("Reminder email — \(LadderLogic.remindDate(chargeInstant: chargeDate, daysBefore: remindDays, locale: locale))")
        }
        if let chargeDate, let committedAmount {
            out.append("\(committedAmount) once — \(longDate(chargeDate, locale: locale))")
        }
        return out
    }
}

/// Receipt.tsx:39-48 — never an invented statistic: below two SWITCHABLE
/// accounts there is no headroom multiple to state.
enum ReceiptHeadline {
    static func build(accountsSwitchable: Int) -> (lead: String, key: String, tail: String) {
        if accountsSwitchable >= 2 {
            return (
                "\(accountsSwitchable) accounts. ",
                accountsSwitchable == 2 ? "Twice the headroom." : "\(accountsSwitchable)× the headroom.", ""
            )
        }
        return ("What the ", "autopilot", " adds.")
    }
}

/// `pro/CloseButton.tsx` ported 1:1: same label, same `data-testid`.
struct PaywallCloseButtonView: View {
    var onClick: () -> Void
    var label = "Close the paywall"
    var testID = "paywall-close"
    // Explicit disabled treatment, as the primary button style has: a
    // `.plain` button with its own colours gets no dimming for free, and
    // the price screen disables this ✕ while a checkout is in flight or
    // its sheet is live (AskMachine.closeEnabled).
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: onClick) {
            Text("✕")
                .font(.system(size: 13))
                .foregroundColor(CockpitTheme.sec)
                .frame(width: 28, height: 28)
                .background(CockpitTheme.panel)
                .overlay(Circle().stroke(CockpitTheme.hair, lineWidth: 1))
                .clipShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(testID)
    }
}

/// The corridor's progress indicator (design critique 2026-08-09): a
/// dedicated, FIXED-height row pinned at the TOP of the stage, above every
/// screen's own variable-height content — replacing the prior "dots ride
/// with the content block" placement, which let the indicator drift to a
/// different on-screen position screen to screen. Dots are 6×6pt, 7pt
/// apart, flush with the headline's own leading edge (both live in the
/// same leading-aligned stage — no extra inset needed here); a tabular-
/// numeral "N of M" label anchors the trailing edge. One combined
/// VoiceOver element, same as before the dots and the label together read
/// as a single "Step N of M", never two.
struct OnboardingProgressRow: View {
    let step: Int
    let total: Int
    /// Preserves each call site's PRE-EXISTING `accessibilityIdentifier`
    /// (the paywall screens carried "step-dots"; the education/onboarding
    /// screens carried none) — `nil` keeps that same no-identifier
    /// behavior rather than inventing a third one the e2e walk doesn't
    /// expect.
    var identifier: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<max(total, 0), id: \.self) { i in
                    Circle()
                        .fill(i == step ? CockpitTheme.accent : (i < step ? CockpitTheme.accB : CockpitTheme.rail))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer(minLength: 12)
            Text("\(step + 1) of \(total)")
                .font(CockpitTheme.Onboarding.progressLabel)
                .foregroundColor(CockpitTheme.ter)
        }
        .frame(height: FlowLayout.progressRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(total)")
        .modifier(AccessibilityIdentifierIfSet(identifier))
    }
}

/// Applies `.accessibilityIdentifier` only when a value is supplied —
/// `View.accessibilityIdentifier(_:)` takes a non-optional `String`, so an
/// empty-string default would ADD an identifier where none existed before.
private struct AccessibilityIdentifierIfSet: ViewModifier {
    let id: String?
    init(_ id: String?) { self.id = id }
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// The corridor's shared screen scaffold (design critique 2026-08-09):
/// TOP-ALIGNED content, ONE flexible spacer (`FlowLayout.contentToFooterMin`),
/// then a FIXED-height footer — replacing the old `[Spacer(24), content,
/// Spacer(24), CTA]` shape, which vertically centered short screens in the
/// middle of the window (the #1 owner complaint from the design critique).
/// Every corridor screen — education, accounts/switch, and every paywall
/// screen alike — renders through this ONE wrapper, so the primary action
/// sits at an identical on-screen position everywhere (repeat-clicking
/// needs no pointer search) and the progress row never moves.
///
/// Deliberately NO `maxHeight: .infinity` / `alignment: .center` wraps the
/// whole thing (that was the OLD bug's actual mechanism: an equal-Spacer
/// VStack shorter than the viewport got centered as a block). Here the
/// proposed height flows straight from the true ancestor (the corridor's
/// `GeometryReader`/`ScrollView` viewport, NativeCockpitWindow.swift) down
/// into this VStack unmodified, so its ONE `Spacer` is what absorbs any
/// slack — top content stays pinned to the top, the footer stays pinned to
/// the bottom.
struct OnboardingStage<Content: View, Footer: View>: View {
    var position: StepPosition?
    var dotsIdentifier: String? = nil
    /// Hold the row's height with no dots in it — see
    /// `PaywallDots.reservesProgressRow`. Default false: a screen with no
    /// strip anywhere in its flow simply starts higher.
    var reservesProgressRow = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let position {
                OnboardingProgressRow(step: position.step, total: position.total, identifier: dotsIdentifier)
                    .padding(.bottom, FlowLayout.progressToHeadline)
            } else if reservesProgressRow {
                Color.clear
                    .frame(height: FlowLayout.progressRowHeight)
                    .padding(.bottom, FlowLayout.progressToHeadline)
                    .accessibilityHidden(true)
            }
            content()
            Spacer(minLength: FlowLayout.contentToFooterMin)
            footer()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: FlowLayout.footerHeight, alignment: .bottom)
        }
        .onboardingCanvas()
    }
}

// MARK: - button styles (Paywall.tsx's `btnPrimary`/`btnGhost`, ladder.ts's
// danger cancel button)

/// The corridor's shared primary CTA (design critique 2026-08-09): fixed
/// 32pt height / 160pt minimum width / 16pt horizontal padding / 7pt
/// corner radius, INTRINSIC width — replacing the old edge-to-edge
/// mobile-port button. A custom `ButtonStyle` rather than
/// `.borderedProminent`: this exact geometry is pinned by spec, and this
/// target's deployment minimum (macOS 13) has no public way to force
/// `.borderedProminent`'s intrinsic size/corner radius to these numbers —
/// so disabled and focus/hover treatment are defined explicitly below
/// instead of inherited for free.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingPrimaryButtonLabel(configuration: configuration)
    }
}

private struct OnboardingPrimaryButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(CockpitTheme.Onboarding.controlLabel)
            .foregroundColor(.white)
            // A CTA never wraps. "Start the 4-day free trial" folded onto
            // two lines inside the button on the price screen (owner
            // 2026-08-10) because the label is flexible and the footer's
            // ghost controls competed for the same row. The primary keeps
            // its whole label on one line and wins the layout; the ghosts
            // truncate first (they carry `.lineLimit(1)` too).
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, FlowLayout.primaryButtonHPadding)
            .frame(minWidth: FlowLayout.primaryButtonMinWidth, minHeight: FlowLayout.primaryButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: FlowLayout.primaryButtonRadius, style: .continuous)
                    .fill(CockpitTheme.actionFill) // contrast-safe white-on-fill (see token)
            )
            .overlay(
                // Explicit focus ring — a custom ButtonStyle's own
                // background otherwise swallows the system one.
                RoundedRectangle(cornerRadius: FlowLayout.primaryButtonRadius, style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0.85 : 0), lineWidth: 2)
                    .padding(-2)
            )
            // Explicit disabled treatment (`isEnabled`) — a custom
            // ButtonStyle gets no dimming for free.
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : (hovering ? 0.92 : 1)) : 0.45)
            .focused($focused)
            .onHover { isHovering in hovering = isEnabled && isHovering }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct PWGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CockpitTheme.numeric(12))
            .foregroundColor(CockpitTheme.sec)
            // Secondary controls give way before the primary does — see
            // OnboardingPrimaryButtonStyle's no-wrap note.
            .lineLimit(1)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PWDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CockpitTheme.numeric(11.5, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(CockpitTheme.critDeep)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    func pwPrimary() -> some View { buttonStyle(OnboardingPrimaryButtonStyle()) }
    func pwGhost() -> some View { buttonStyle(PWGhostButtonStyle()) }
    func pwDanger() -> some View { buttonStyle(PWDangerButtonStyle()) }
}

private func longDate(_ date: Date, locale: String) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: locale)
    df.setLocalizedDateFormatFromTemplate("d MMMM")
    return df.string(from: date)
}

private func calloutBox(_ text: String, testID: String? = nil) -> some View {
    Text(text)
        .font(CockpitTheme.Onboarding.status)
        .foregroundColor(CockpitTheme.sec)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
        .accessibilityIdentifier(testID ?? "")
}

// MARK: - OfferCard / TrialTimeline (Paywall.tsx:76-160)

private struct TrialTimelineView: View {
    let quote: LadderQuote
    let amount: String
    let approx: Bool
    let remindDays: Int
    let locale: String
    let now: Date

    private struct Stop { let when: String; let why: String; let tone: Color }

    private var stops: [Stop] {
        let charge = LadderLogic.chargeInstant(quote: quote, now: now)
        let amt = "\(approx ? "≈ " : "")\(amount)"
        return [
            Stop(when: "Today", why: "The autopilot turns on. Every Pro feature, free.", tone: CockpitTheme.accent),
            Stop(
                when: LadderLogic.remindDate(chargeInstant: charge, daysBefore: remindDays, locale: locale),
                why: "We email you a reminder before anything is charged.", tone: CockpitTheme.warnRaw),
            Stop(
                when: longDate(charge, locale: locale),
                why: "\(amt), charged once. We cancel the renewal automatically. Yours for life.",
                tone: CockpitTheme.rail),
        ]
    }

    var body: some View {
        // F12 (2026-08-16 audit) — 10 -> 16: the three stops sat too close
        // to breathe against the price line above and the descriptor below.
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(s.tone).frame(width: 8, height: 8).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.when).font(CockpitTheme.numeric(11, weight: .bold))
                        Text(s.why).font(CockpitTheme.Onboarding.annotation).foregroundColor(CockpitTheme.sec)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

/// `OfferCard` (Paywall.tsx:127-160) — the one consent card: price line,
/// timeline, statement note. Shared by the price screen and the paused
/// (trial-restart) screen.
struct OfferCardView: View {
    let copy: RungCopy
    let quote: LadderQuote
    let remindDays: Int
    let locale: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            priceLine
            TrialTimelineView(quote: quote, amount: copy.amount, approx: copy.approx, remindDays: remindDays, locale: locale, now: now)
            // F12 (2026-08-16 audit: the card read crowded) —
            // more room between the timeline's last row and the statement
            // descriptor than the timeline's own row gap, so the
            // descriptor reads as a closing footnote, not one more row.
            Text(LadderLogic.statementNote)
                .font(.system(size: 10))
                .foregroundColor(CockpitTheme.ter)
                .padding(.top, 14)
        }
        // F12: 14 -> 20 — the card read crowded at the tight inset.
        // Re-measured at the 616×540 content-fit corridor: ⑦ is 327pt deep
        // against 452pt available, so the roomier padding still fits.
        .padding(20)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(CockpitTheme.hair, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var priceLine: some View {
        var text = Text("")
        if let strike = copy.strikeAmount {
            text =
                text
                + Text("\(copy.approx ? "≈ " : "")\(strike) ")
                .font(CockpitTheme.Onboarding.strikeAmount)
                .foregroundColor(CockpitTheme.ter)
                .strikethrough()
        }
        text =
            text
            + Text("\(copy.approx ? "≈ " : "")\(copy.amount) ")
            .font(CockpitTheme.Onboarding.commercialAmount)
            .foregroundColor(CockpitTheme.text)
        text =
            text
            + Text(copy.beside)
            .font(CockpitTheme.Onboarding.status.weight(.medium))
            .foregroundColor(CockpitTheme.sec)
        return text
    }
}

// MARK: - corridor geometry (design critique 2026-08-09 — every number
// below is pinned by that spec). Screens ⑥⑦⑧ and paused/no-terms/active
// used to be centered fixed-width sections of their own (Receipt/Remind/
// Price 620px, Paused/NoTerms 460px, Active 440px — e.g. Receipt.tsx:68
// `mx-auto w-[620px] max-w-[92vw]`), off the SAME stage/footer geometry as
// ①-⑤ now (`OnboardingStage`); inner elements keep their own narrower caps
// via `FlowLayout.copyColumnMaxWidth`/`receiptTableMaxWidth` below.

/// Corridor screen geometry: a fixed-width STAGE, top-aligned content with
/// one flexible spacer before a FIXED-height footer, and a vertical rhythm
/// off the shared 4/8/12/16/20/24/32/40 spacing scale — replacing the old
/// two-equal-`Spacer(24)` layout (floated short screens in the vertical
/// middle of the window — the #1 owner complaint) and the 940pt/full-width
/// CTA (a mobile-port pattern with no place on a resizable desktop window).
enum FlowLayout {
    // MARK: stage + margins
    /// The corridor's ONE column. Owner 2026-08-18: centred content in a
    /// window that fits it, the way a mobile app's onboarding does — so
    /// the stage stopped being a wide canvas
    /// that a narrow column floats in, and became the column itself. The
    /// window is then sized to it (`WindowMode.corridor.targetContentSize`
    /// = this + 2x `minHorizontalInset`), which is what removes the dead
    /// space rather than sliding the content into it: the progress dots,
    /// the "N of M" label, the headline, the card and the footer now all
    /// span exactly this width, so every edge lines up down the screen.
    ///
    /// Supersedes both the 2026-08-17 walk's leading-alignment (N5 — it
    /// killed the gutter jump by abandoning centring, which the owner
    /// overruled) and F16's 860pt corridor.
    static let stageMaxWidth: CGFloat = 560
    /// The window's horizontal inset never drops below this, even at the
    /// corridor's own minimum width — `onboardingCanvas()`'s modifier
    /// ORDER is what makes the inset win over the cap at small widths
    /// (padding applied outside the cap, so it shrinks the stage rather
    /// than starving the margin); see that function.
    static let minHorizontalInset: CGFloat = 28
    /// Body copy's own inner cap. Now EQUAL to the stage: the stage is the
    /// readable column, so an inner cap that differed would re-introduce
    /// the very misalignment the one-column change removes. Kept as its own
    /// constant because it means something different (line length) and may
    /// diverge again.
    static let copyColumnMaxWidth: CGFloat = 560
    /// The Free/Pro table. Was 640 — wider than the copy column, which is
    /// what made ⑤'s content sit on a different grid from ⑥/⑦'s.
    static let receiptTableMaxWidth: CGFloat = 560
    static let topInset: CGFloat = 28
    static let bottomInset: CGFloat = 24

    // MARK: vertical rhythm (spacing scale: 4, 8, 12, 16, 20, 24, 32, 40)
    /// Fits its tallest occupant (the 11pt "N of M" label, ~14pt of line
    /// box) and nothing more. FIXED is the load-bearing part — that is what
    /// stops the indicator drifting screen to screen — but the value was
    /// 20, which parked 6pt of empty row above the dots and made the
    /// corridor's top gap read 34pt against 28pt sides (owner 2026-08-18:
    /// the top gap must match the side margins). Measured off a render,
    /// not assumed.
    static let progressRowHeight: CGFloat = 15
    static let progressToHeadline: CGFloat = 20
    static let headlineToLede: CGFloat = 8
    static let ledeToVisual: CGFloat = 24
    static let cardInternalSpacing: CGFloat = 8
    static let visualToDisclosure: CGFloat = 10
    static let disclosureToClosing: CGFloat = 16
    static let contentToFooterMin: CGFloat = 24
    static let footerHeight: CGFloat = 40

    // MARK: CTA footer
    static let primaryButtonHeight: CGFloat = 32
    static let primaryButtonMinWidth: CGFloat = 160
    static let primaryButtonHPadding: CGFloat = 16
    static let primaryButtonRadius: CGFloat = 7
    static let footerControlSpacing: CGFloat = 12
}

extension View {
    /// The corridor stage: caps at `stageMaxWidth`, but never lets the
    /// horizontal inset drop below `minHorizontalInset` — even at the
    /// window's own minimum width — because the padding is the OUTERMOST
    /// modifier here (applied last), so it reduces the proposed width the
    /// inner `frame(maxWidth: stageMaxWidth)` sees rather than being added
    /// on top of an already-820pt box. `OnboardingStage` is the only
    /// caller — every corridor screen routes through it so they all share
    /// one geometry.
    func onboardingCanvas() -> some View {
        self
            .frame(maxWidth: FlowLayout.stageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, FlowLayout.minHorizontalInset)
            .padding(.top, FlowLayout.topInset)
            .padding(.bottom, FlowLayout.bottomInset)
    }
}

// MARK: - ⑥ the receipt (pro/Receipt.tsx)

struct PaywallReceiptScreen: View {
    let quote: LadderQuote
    let accountsSwitchable: Int
    let onContinue: () -> Void
    /// `nil` inside the guided flow (Receipt.tsx's `onClose` is absent
    /// there) — `AskMachine.closeButtonVisible` already encodes this.
    let onClose: (() -> Void)?
    let dots: StepPosition?

    private struct Row { let what: String; let free: Bool }
    private static let rows: [Row] = [
        Row(what: "Watch every limit, live", free: true),
        Row(what: "Switch accounts by hand", free: true),
        Row(what: "Statusline and analytics", free: true),
        Row(what: "Switches you before the wall", free: false),
        Row(what: "Books fresh windows on a schedule", free: false),
    ]

    private var headline: (lead: String, key: String, tail: String) {
        ReceiptHeadline.build(accountsSwitchable: accountsSwitchable)
    }

    var body: some View {
        OnboardingStage(position: dots, dotsIdentifier: "step-dots") {
            ZStack(alignment: .topTrailing) {
                // ONE GRID for the whole corridor. N5 (audit 2026-08-17):
                // the headline's left gutter jumped 28pt (screens ①–④) →
                // 110pt (⑤) → 150pt (⑥/⑦/win-back) because each ask screen
                // centered its own capped column inside the stage, so the
                // headline slid right as you clicked through. Every screen
                // now starts at the stage's leading edge; the column still
                // caps at its widest element, it just no longer floats.
                //
                // This REVERSED owner 2026-08-12 (centered card) while
                // the stage was still wider than the column; the 2026-08-18
                // content-fit reshape then dissolved the tension:
                // `stageMaxWidth` IS the column now and the window is
                // derived from it, so a leading-aligned stage and a centred
                // one occupy the same pixels. What is left for this
                // alignment to decide is only that ragged elements inside
                // the column share one left edge instead of wobbling
                // around its centre line.
                VStack(alignment: .leading, spacing: 0) {
                    // Emphasis is WEIGHT, not the reserved accent blue
                    // (design/DESIGN-SYSTEM.md — design critique 2026-08-09).
                    (Text(headline.lead).font(CockpitTheme.Onboarding.headline)
                        + Text(headline.key).font(CockpitTheme.Onboarding.headlineEmphasis)
                        + Text(headline.tail).font(CockpitTheme.Onboarding.headline))
                        .tracking(CockpitTheme.Onboarding.headlineTracking)
                        .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                        .foregroundColor(CockpitTheme.text)
                    Text("Here is exactly what changes when the autopilot is on.")
                        .font(CockpitTheme.Onboarding.lede)
                        .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.top, FlowLayout.headlineToLede)
                    receiptTable
                        .frame(maxWidth: FlowLayout.receiptTableMaxWidth, alignment: .leading)
                        .padding(.top, FlowLayout.ledeToVisual)
                    // Neutral surface, not the accent tint (audit
                    // 2026-08-11): blue is reserved for booked/charging +
                    // actions, and a commercial callout is neither — the
                    // same rule that stripped the Pro column's blue. Weight
                    // and the box itself carry the emphasis.
                    Text("Everything in the Pro column is free for \(quote.trialDays) days. No payment today.")
                        .font(CockpitTheme.Onboarding.body.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(CockpitTheme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CockpitTheme.hair, lineWidth: 1))
                        .accessibilityIdentifier("receipt-trial")
                        .padding(.top, FlowLayout.visualToDisclosure)
                    Text("Watching and switching by hand stay free, forever.")
                        .font(CockpitTheme.Onboarding.body)
                        .padding(.top, FlowLayout.disclosureToClosing)
                }
                .frame(maxWidth: FlowLayout.receiptTableMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                if let onClose {
                    PaywallCloseButtonView(onClick: onClose).padding(.trailing, 4)
                }
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                // VOICE.md: verb+object — the receipt's next step is picking
                // the reminder day (design critique 2026-08-09).
                Button("Choose reminder day", action: onContinue)
                    .pwPrimary()
                    .keyboardShortcut(.defaultAction) // Return advances (owner 2026-08-09)
                    .accessibilityIdentifier("receipt-continue")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt-screen")
    }

    /// Receipt.tsx:80-115 — Free/Pro header row (9.5px bold, wide tracking),
    /// 66px check columns, py-2.5 rows. Design critique 2026-08-09: the Pro
    /// column used to run a CONTINUOUS accent-blue tint header-through-rows
    /// — design/DESIGN-SYSTEM.md reserves that blue for booked/charging
    /// state and actions, not commercial decoration. The column is now
    /// distinguished by a hairline rule plus a restrained neutral surface
    /// (`hairSoft`) instead, with weight carrying the rest of the emphasis
    /// — same "color is meaning" rule the receipt's own checkmarks already
    /// honor (green = included, a real semantic color, left untouched).
    private var receiptTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                Text("Free")
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(0.9)
                    .foregroundColor(CockpitTheme.ter)
                    .frame(width: 66)
                    .padding(.vertical, 6)
                Text("Pro")
                    .font(.system(size: 9.5, weight: .heavy))
                    .kerning(0.9)
                    .foregroundColor(CockpitTheme.text)
                    .frame(width: 66)
                    .padding(.vertical, 6)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                            .fill(CockpitTheme.hairSoft))
                    .overlay(Rectangle().fill(CockpitTheme.hair).frame(width: 1), alignment: .leading)
            }
            ForEach(Self.rows, id: \.what) { r in
                Divider().overlay(CockpitTheme.hairSoft)
                HStack(spacing: 0) {
                    Text(r.what)
                        .font(CockpitTheme.Onboarding.tableRow)
                        .foregroundColor(CockpitTheme.text)
                        .padding(.leading, 8)
                    Spacer()
                    // Decorative glyphs — each row exposes ONE combined
                    // VoiceOver statement below instead (accessibility
                    // item 6, design critique 2026-08-09).
                    Text(r.free ? "✓" : "–")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(r.free ? CockpitTheme.okTx : CockpitTheme.ter)
                        .frame(width: 66)
                        .padding(.vertical, 10)
                        .accessibilityHidden(true)
                    Text("✓")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(CockpitTheme.okTx)
                        .frame(width: 66)
                        .padding(.vertical, 10)
                        .background(CockpitTheme.hairSoft)
                        .overlay(Rectangle().fill(CockpitTheme.hair).frame(width: 1), alignment: .leading)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(r.free ? "\(r.what): included in Free and Pro" : "\(r.what): Pro only")
            }
        }
        .accessibilityIdentifier("receipt-table")
    }
}

// MARK: - ⑦ the reminder (pro/Remind.tsx)

struct PaywallRemindScreen: View {
    let quote: LadderQuote
    @Binding var remindDays: Int?
    let offsets: [Int]
    let locale: String
    let now: Date
    let onContinue: () -> Void
    let onClose: (() -> Void)?
    let dots: StepPosition?

    private var chargeInstant: Date { LadderLogic.chargeInstant(quote: quote, now: now) }
    private var chargeLong: String { longDate(chargeInstant, locale: locale) }

    var body: some View {
        OnboardingStage(position: dots, dotsIdentifier: "step-dots") {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    // Emphasis is WEIGHT, not the reserved accent blue
                    // (design/DESIGN-SYSTEM.md — design critique 2026-08-09).
                    (Text("Your \(quote.trialDays) free days end ").font(CockpitTheme.Onboarding.headline)
                        + Text(chargeLong).font(CockpitTheme.Onboarding.headlineEmphasis)
                        + Text(".").font(CockpitTheme.Onboarding.headline))
                        .tracking(CockpitTheme.Onboarding.headlineTracking)
                        .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                        .foregroundColor(CockpitTheme.text)
                        .accessibilityIdentifier("remind-headline")
                    // VOICE.md: never overpromise — "so nothing is ever a
                    // surprise" is an absolute promise the copy can't back
                    // (design critique 2026-08-09).
                    Text("We'll email you before the charge date. Pick the day.")
                        .font(CockpitTheme.Onboarding.lede)
                        .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.top, FlowLayout.headlineToLede)

                    VStack(spacing: FlowLayout.cardInternalSpacing) {
                        ForEach(offsets, id: \.self) { d in
                            offsetRow(d)
                        }
                    }
                    .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                    .padding(.top, FlowLayout.ledeToVisual)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("When should we remind you?")
                    .accessibilityIdentifier("remind-offsets")

                    Text("Cancelling takes one click in Settings. No penalties, no fees.")
                        .font(CockpitTheme.Onboarding.status)
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.top, FlowLayout.disclosureToClosing)
                }
                // Centered in the stage — which is now the column itself,
                // so this only bites if a column is ever made narrower.
                .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                if let onClose {
                    PaywallCloseButtonView(onClick: onClose).padding(.trailing, 4)
                }
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                // VOICE.md: verb+object — the reminder's next step is the
                // price/terms screen (design critique 2026-08-09).
                Button("Review trial terms", action: onContinue)
                    .pwPrimary()
                    .keyboardShortcut(.defaultAction) // Return advances (owner 2026-08-09)
                    .disabled(remindDays == nil)
                    .accessibilityIdentifier("remind-continue")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remind-screen")
        // Remind.tsx:66-68's OWN mount effect — NOT AskMachine.askReminder(),
        // which only pre-answers the ZERO-offsets case. A single possible
        // answer needs no question either, so this screen pre-answers it
        // rather than lock Continue behind a mandatory tap on the only
        // button. Ground truth places this in the SCREEN component, not the
        // model, and this view mirrors that placement exactly.
        .task(id: offsets) {
            if remindDays == nil, offsets.count == 1 {
                remindDays = offsets[0]
            }
        }
    }

    private func offsetRow(_ d: Int) -> some View {
        let selected = remindDays == d
        return Button(action: { remindDays = d }) {
            HStack {
                // A real selection indicator (design critique 2026-08-09,
                // accessibility item 6) — the filled/outline glyph carries
                // the state by SHAPE, not only by the row's accent tint.
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? CockpitTheme.accent : CockpitTheme.hair)
                Text(d == 1 ? "1 day before" : "\(d) days before")
                    .font(CockpitTheme.Onboarding.controlLabel)
                Spacer()
                Text(LadderLogic.remindDate(chargeInstant: chargeInstant, daysBefore: d, locale: locale))
                    .font(CockpitTheme.numeric(12, weight: .medium))
                    .foregroundColor(selected ? CockpitTheme.accTx : CockpitTheme.sec)
            }
            .foregroundColor(CockpitTheme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(selected ? CockpitTheme.chipBg : CockpitTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? CockpitTheme.accBd : CockpitTheme.hair, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remind-offset-\(d)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - ⑧ the price (Paywall.tsx:298-376)

struct PaywallPriceScreen: View {
    let ask: AskMachine
    let copy: RungCopy
    let quote: LadderQuote
    let dots: StepPosition?
    let onRecover: () -> Void

    var body: some View {
        OnboardingStage(position: dots, dotsIdentifier: "step-dots") {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(copy.headline)
                        .font(CockpitTheme.Onboarding.headline)
                        .tracking(CockpitTheme.Onboarding.headlineTracking)
                        .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                        .foregroundColor(CockpitTheme.text)
                    Text(copy.lede)
                        .font(CockpitTheme.Onboarding.lede)
                        .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.top, FlowLayout.headlineToLede)
                    // The unanswered-reminder fallback shows the date ⑦
                    // will actually PRESELECT (offsets.first), not a
                    // different one the buyer never chose — ⑧ renders with
                    // a nil remindDays only on the win-back decline path
                    // (S6 review delta P2).
                    OfferCardView(
                        copy: copy, quote: quote,
                        remindDays: ask.remindDays ?? ask.remindOffsets.first ?? 1,
                        locale: ask.locale, now: ask.now()
                    )
                    .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                    .padding(.top, FlowLayout.ledeToVisual)

                    disclosures

                    Text("No payment due today.")
                        .font(CockpitTheme.Onboarding.status)
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.top, FlowLayout.disclosureToClosing)
                }
                // Centered in the stage — which is now the column itself,
                // so this only bites if a column is ever made narrower.
                .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                if ask.closeButtonVisible {
                    // Dimmed for exactly as long as it would do nothing —
                    // the press on the wire and the sheet's whole life
                    // (AskMachine.closeEnabled): a ✕ in the 0.5–3s press
                    // gap used to arm the lower offer behind the full-price
                    // sheet the press was building. close() refuses it too;
                    // this keeps the press from happening.
                    PaywallCloseButtonView(onClick: { ask.close() })
                        .disabled(!ask.closeEnabled)
                }
            }
        } footer: {
            // Every secondary control sits LEFT, the one primary sits alone
            // on the right (owner 2026-08-10): four controls sharing the
            // right edge made the buy button compete with a discount link
            // and a restore link at the moment of decision, and squeezed
            // the CTA until its label wrapped.
            HStack(spacing: FlowLayout.footerControlSpacing) {
                bottomLeftControl
                Button("Restore a purchase", action: onRecover)
                    .pwGhost()
                    .accessibilityIdentifier("recover-purchase")
                Spacer(minLength: FlowLayout.footerControlSpacing)
                Button(action: { Task { await ask.pressCheckout() } }) {
                    Text(ask.busy ? "Opening checkout…" : copy.cta)
                }
                .pwPrimary()
                // Return advances (owner 2026-08-09) — same as every other
                // corridor primary: this button only opens the payment
                // sheet, which has its own Cancel bar, and no money moves
                // without card entry there.
                .keyboardShortcut(.defaultAction)
                .disabled(ask.busy)
                .accessibilityIdentifier("checkout-start")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("price-screen")
    }

    /// The price screen's disclosure zone — a license error, an in-flight
    /// checkout handoff, or a checkout error, any (rare) combination of
    /// which can be live at once; each gets the same `visualToDisclosure`
    /// gap above it.
    @ViewBuilder
    private var disclosures: some View {
        if let err = LadderLogic.licenseErrorCopy(ask.license.errorCode) {
            calloutBox(err, testID: "license-error").padding(.top, FlowLayout.visualToDisclosure)
        }
        if let handoff = ask.handoffURL {
            Text("Checkout is open in the payment window — finish there, or start again here.")
                .font(CockpitTheme.Onboarding.status)
                .foregroundColor(CockpitTheme.sec)
                .padding(.top, FlowLayout.visualToDisclosure)
                .accessibilityIdentifier("checkout-handoff")
                .accessibilityValue(handoff)
        }
        if let checkoutErr = ask.checkoutError {
            calloutBox(checkoutErr, testID: "checkout-error").padding(.top, FlowLayout.visualToDisclosure)
        }
    }

    /// Which reminder control the price screen offers, if any. Selection
    /// itself is `PriceBottomControl.resolve` (pure, tested directly); this
    /// only maps the resolved case onto a control. Sits bottom-LEFT of the
    /// footer — the corridor's "back/navigation" slot.
    @ViewBuilder
    private var bottomLeftControl: some View {
        switch PriceBottomControl.resolve(remindDays: ask.remindDays, remindOffsets: ask.remindOffsets) {
        case .chooseReminder:
            Button("Choose the reminder day", action: { ask.askReminder() })
                .pwGhost()
                .accessibilityIdentifier("price-change-reminder")
        case .none:
            EmptyView()
        }
    }
}

// MARK: - paused (trial restart, Paywall.tsx:378-442)

struct PaywallPausedScreen: View {
    let ask: AskMachine
    let dots: StepPosition?
    let quoteFailed: Bool
    let onRetryQuote: (() -> Void)?
    let onRecover: () -> Void

    var body: some View {
        OnboardingStage(position: dots, dotsIdentifier: "step-dots") {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Your trial ended — the autopilot is paused")
                        .font(CockpitTheme.Onboarding.headline)
                        .tracking(CockpitTheme.Onboarding.headlineTracking)
                        .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                        .foregroundColor(CockpitTheme.text)
                        .accessibilityIdentifier("paused-heading")
                    Text(
                        "Your schedules are kept and nothing was deleted. Switching, statusline, and analytics keep working. Turn the autopilot back on to have it watch your windows again."
                    )
                    .font(CockpitTheme.Onboarding.lede)
                    .lineSpacing(CockpitTheme.Onboarding.ledeLineSpacing)
                    .foregroundColor(CockpitTheme.sec)
                    .padding(.top, FlowLayout.headlineToLede)

                    if let caught = ask.caughtThisWeek, caught > 0 {
                        Text("While it ran, the autopilot caught \(caught) \(caught == 1 ? "window" : "windows") this week.")
                            .font(CockpitTheme.Onboarding.body)
                            .padding(.top, FlowLayout.visualToDisclosure)
                    }
                    if let err = ask.checkoutError {
                        calloutBox(err, testID: "checkout-error").padding(.top, FlowLayout.visualToDisclosure)
                    }

                    offerOrLoading
                        .padding(.top, FlowLayout.ledeToVisual)
                }
                // Paused ALWAYS shows its ✕ (AskMachine.closeButtonVisible
                // returns true unconditionally for .paused) — the 1.2.6
                // regression this pins shipped with none at all. Dimmed on
                // the same terms as the price screen's while it would do
                // nothing (a checkout in flight or live on this ladder).
                PaywallCloseButtonView(onClick: { ask.close() })
                    .disabled(!ask.closeEnabled)
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                Button("Restore a purchase", action: onRecover)
                    .pwGhost()
                    .accessibilityIdentifier("recover-purchase")
                Button(action: { ask.askReminder() }) {
                    Text(PausedCTA.resolve(hasOfferCopy: ask.offerCopy != nil, quote: ask.quote).label)
                }
                .pwPrimary()
                .keyboardShortcut(.defaultAction) // Return advances (owner 2026-08-09)
                .disabled(ask.offerCopy == nil)
                .accessibilityIdentifier("paused-cta")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paused-screen")
    }

    @ViewBuilder
    private var offerOrLoading: some View {
        if let copy = ask.offerCopy, let quote = ask.quote {
            OfferCardView(copy: copy, quote: quote, remindDays: ask.remindDays ?? 1, locale: ask.locale, now: ask.now())
                .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
            Text("No payment due today.")
                .font(CockpitTheme.Onboarding.status)
                .foregroundColor(CockpitTheme.sec)
                .padding(.top, FlowLayout.disclosureToClosing)
        } else if quoteFailed {
            VStack(alignment: .leading, spacing: 6) {
                Text("The price could not be loaded — check your connection.")
                    .font(CockpitTheme.Onboarding.status)
                    .foregroundColor(CockpitTheme.sec)
                // VOICE.md: verb+object retry copy (design critique
                // 2026-08-09) — was "Try again".
                if let onRetryQuote {
                    Button("Reload price", action: onRetryQuote).pwGhost().accessibilityIdentifier("retry-quote")
                }
            }
        } else {
            Text("Loading the price…").font(CockpitTheme.Onboarding.status).foregroundColor(CockpitTheme.sec)
        }
    }
}

// MARK: - no usable quote yet (Paywall.tsx:444-481)

struct PaywallNoTermsScreen: View {
    let onClose: () -> Void
    let checkoutError: String?
    let quoteFailed: Bool
    let onRetryQuote: (() -> Void)?
    let dots: StepPosition?

    var body: some View {
        OnboardingStage(position: dots, dotsIdentifier: "step-dots") {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Turn on the autopilot")
                        .font(CockpitTheme.Onboarding.headline)
                        .tracking(CockpitTheme.Onboarding.headlineTracking)
                        .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                        .foregroundColor(CockpitTheme.text)
                    if let checkoutError {
                        calloutBox(checkoutError, testID: "checkout-error").padding(.top, FlowLayout.headlineToLede)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if quoteFailed {
                            Text("The price could not be loaded — check your connection.")
                                .font(CockpitTheme.Onboarding.body)
                                .foregroundColor(CockpitTheme.text)
                        } else {
                            Text("Loading the price…")
                                .font(CockpitTheme.Onboarding.body)
                                .foregroundColor(CockpitTheme.sec)
                        }
                    }
                    .padding(14)
                    .background(CockpitTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(CockpitTheme.hair, lineWidth: 1))
                    .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                    .padding(.top, FlowLayout.ledeToVisual)
                }
                PaywallCloseButtonView(onClick: onClose)
            }
        } footer: {
            // The retry is this state's ONLY forward action, so it takes
            // the corridor's primary slot (audit 2026-08-11: as a ghost
            // inside the panel it read as disabled body copy). While the
            // quote is merely still LOADING there is nothing to press and
            // the reserved 40pt band keeps the close button's vertical
            // position identical to every other corridor screen.
            if quoteFailed, let onRetryQuote {
                HStack(spacing: FlowLayout.footerControlSpacing) {
                    Spacer()
                    // VOICE.md: verb+object retry copy — was "Try again".
                    Button("Reload price", action: onRetryQuote)
                        .pwPrimary()
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("retry-quote")
                }
            } else {
                Color.clear
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noterms-screen")
    }
}

// MARK: - ⑨ Pro is on (Paywall.tsx:198-236)

struct PaywallActiveScreen: View {
    let ask: AskMachine
    let dots: StepPosition?
    /// N8 residual — see `PaywallDots.reservesProgressRow`.
    var reservesProgressRow = false
    let locale: String
    /// The fleet's promotable watch-only lanes (ProFlowLogic.watchOnlyLanes)
    /// — empty hides the whole section. Supplied with `move` by the
    /// composition root on BOTH the guided and reopened paths.
    var watchOnly: [WatchOnlyLane] = []
    var move: ActivationMoveModel? = nil

    private var facts: [String] {
        PaywallActiveFacts.build(
            accountsWatched: ask.accountsWatched, chargeDate: ask.license.trial?.chargeDate,
            remindDays: ask.remindDays, committedAmount: ask.committedAmount, locale: locale,
            watchOnly: watchOnly.count)
    }

    var body: some View {
        OnboardingStage(
            position: dots, dotsIdentifier: "step-dots",
            reservesProgressRow: reservesProgressRow
        ) {
            VStack(alignment: .leading, spacing: 0) {
                // Green is meaningful here (success/guaranteed state,
                // design/DESIGN-SYSTEM.md), not decoration — kept.
                Text("Pro is on")
                    .font(CockpitTheme.Onboarding.headline)
                    .tracking(CockpitTheme.Onboarding.headlineTracking)
                    .lineSpacing(CockpitTheme.Onboarding.headlineLineSpacing)
                    .foregroundColor(CockpitTheme.okTx)
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                        Text(f)
                            .font(CockpitTheme.Onboarding.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                        if i < facts.count - 1 {
                            Divider().overlay(CockpitTheme.hairSoft)
                        }
                    }
                }
                .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                .background(CockpitTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(CockpitTheme.hair, lineWidth: 1))
                .padding(.top, FlowLayout.headlineToLede)

                // Layer 1 (owner 2026-08-12): promote watch-only lanes AT
                // the activation moment — a paid buyer must never discover
                // on the board that the autopilot can't switch to anything.
                if let move, !watchOnly.isEmpty {
                    Text("Watch-only accounts show their usage, but the autopilot can't switch to them yet.")
                        .font(CockpitTheme.Onboarding.status)
                        .lineSpacing(CockpitTheme.Onboarding.statusLineSpacing)
                        .foregroundColor(CockpitTheme.sec)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, FlowLayout.ledeToVisual)
                    ActivationWatchOnlySection(lanes: watchOnly, move: move)
                        .frame(maxWidth: FlowLayout.copyColumnMaxWidth, alignment: .leading)
                        .padding(.top, FlowLayout.cardInternalSpacing)
                }
            }
        } footer: {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Spacer()
                Button("Open the cockpit", action: { ask.onDismiss() })
                    .pwPrimary()
                    .keyboardShortcut(.defaultAction) // Return advances (owner 2026-08-09)
                    .accessibilityIdentifier("active-open-cockpit")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-screen")
    }
}

/// The ⑨ watch-only promote list: one row per pinned lane with the
/// two-click move (AddAccountModel's consent idiom — warning between the
/// clicks, 3s auto-disarm). Notes render at SECTION level so a warning
/// outlives the row it was about.
private struct ActivationWatchOnlySection: View {
    let lanes: [WatchOnlyLane]
    @ObservedObject var move: ActivationMoveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { i, lane in
                    row(lane)
                    if i < lanes.count - 1 {
                        Divider().overlay(CockpitTheme.hairSoft)
                    }
                }
            }
            .background(CockpitTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(CockpitTheme.hair, lineWidth: 1))
            ForEach(move.notes.keys.sorted(), id: \.self) { dir in
                if let note = move.notes[dir] {
                    calloutBox(note, testID: "activation-move-note")
                        .padding(.top, FlowLayout.cardInternalSpacing)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activation-watch-only")
    }

    private func row(_ lane: WatchOnlyLane) -> some View {
        let armed = move.confirmDir == lane.configDir
        let busy = move.busyDir == lane.configDir
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: FlowLayout.footerControlSpacing) {
                Text(lane.email)
                    .font(CockpitTheme.Onboarding.controlLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button(action: { move.requestMove(lane.configDir) }) {
                    Text(busy ? AddAccountCopy.moving : (armed ? AddAccountCopy.moveConfirm : "Make switchable"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(move.busyDir != nil ? 0.5 : 1)
                .disabled(move.busyDir != nil)
                .accessibilityIdentifier("activation-make-switchable-\(lane.configDir)")
                .accessibilityLabel(busy ? AddAccountCopy.moving : (armed ? AddAccountCopy.moveConfirm : "Make switchable"))
            }
            if armed {
                // The consequence, stated BETWEEN the two clicks — the same
                // consent shape the Add-account sheet's move uses.
                Text(AddAccountCopy.moveWarning(lane.configDir))
                    .font(CockpitTheme.Onboarding.annotation)
                    .lineSpacing(CockpitTheme.Onboarding.annotationLineSpacing)
                    .foregroundColor(CockpitTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - container

/// Renders the screen `ask.screen` selects, exactly as `Paywall.tsx`'s own
/// if-chain does. Thin: every mutation goes through `ask` (or the two
/// external callbacks the web source also keeps external — `onRecover` and
/// the checkout handoff, which this chunk hands off via `onCheckoutHandoff`
/// rather than presenting `CheckoutSheet` itself, per this chunk's brief).
struct PaywallView: View {
    @ObservedObject var ask: AskMachine
    /// `nil` when `ask.guided == false` (a paywall reopened from the
    /// banner) — mirrors `dots !== undefined` in Paywall.tsx. The caller is
    /// responsible for keeping the two in agreement.
    var dots: PaywallDots? = nil
    /// Paywall.tsx's `quoteFailed`/`onRetryQuote` — NOT modeled by
    /// AskMachine (it only knows "no usable quote", not WHY), so these are
    /// plain display inputs the integrator supplies from its own quote
    /// fetch. See this chunk's final report.
    var quoteFailed = false
    var onRetryQuote: (() -> Void)? = nil
    var onRecover: () -> Void = {}
    /// Fires once per NEW handoff URL — the integrator presents
    /// `CheckoutSheet.present(url:on:onClosed:)` from here; this view never
    /// touches WebKit or a parent NSWindow itself.
    var onCheckoutHandoff: (URL) -> Void = { _ in }
    /// ⑨'s watch-only promote inputs (owner 2026-08-12, layer 1) — the
    /// composition root supplies both on the guided AND reopened paths.
    var watchOnly: [WatchOnlyLane] = []
    var activationMove: ActivationMoveModel? = nil

    var body: some View {
        Group {
            switch ask.screen {
            case .active:
                PaywallActiveScreen(
                    ask: ask, dots: PaywallDots.position(for: .active, base: dots),
                    reservesProgressRow: PaywallDots.reservesProgressRow(for: .active, base: dots),
                    locale: ask.locale, watchOnly: watchOnly, move: activationMove)
            case .remind:
                if let quote = ask.quote {
                    PaywallRemindScreen(
                        quote: quote,
                        remindDays: Binding(get: { ask.remindDays }, set: { ask.remindDays = $0 }),
                        offsets: ask.remindOffsets,
                        locale: ask.locale,
                        now: ask.now(),
                        onContinue: { ask.remindContinue() },
                        onClose: ask.closeButtonVisible ? { ask.close() } : nil,
                        dots: PaywallDots.position(for: .remind, base: dots))
                }
            case .price:
                if let copy = ask.offerCopy, let quote = ask.quote {
                    PaywallPriceScreen(
                        ask: ask, copy: copy, quote: quote,
                        dots: PaywallDots.position(for: .price, base: dots),
                        onRecover: onRecover)
                }
            case .paused:
                PaywallPausedScreen(
                    ask: ask, dots: PaywallDots.position(for: .paused, base: dots),
                    quoteFailed: quoteFailed, onRetryQuote: onRetryQuote, onRecover: onRecover)
            case .noTerms:
                PaywallNoTermsScreen(
                    onClose: { ask.close() }, checkoutError: ask.checkoutError,
                    quoteFailed: quoteFailed, onRetryQuote: onRetryQuote,
                    dots: PaywallDots.position(for: .noTerms, base: dots))
            case .receipt:
                if let quote = ask.quote {
                    PaywallReceiptScreen(
                        quote: quote, accountsSwitchable: ask.accountsSwitchable ?? 0,
                        onContinue: { ask.askReminder() },
                        onClose: ask.closeButtonVisible ? { ask.close() } : nil,
                        dots: PaywallDots.position(for: .receipt, base: dots))
                }
            }
        }
        .onChange(of: ask.handoffURL) { newValue in
            if let newValue, let url = URL(string: newValue) { onCheckoutHandoff(url) }
        }
    }
}
