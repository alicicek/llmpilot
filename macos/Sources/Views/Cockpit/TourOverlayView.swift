import AppKit
import SwiftUI

// Native port of web/src/shell/Tour.tsx's spotlight overlay: a dimmed
// backdrop with a cutout ring over a REAL cockpit element, and a small card
// naming what the user is looking at. TourModel.swift (ViewModels) holds the
// pure step/renumbering state machine this view drives.

// MARK: - anchors (Tour.tsx's `data-tour="..."` / `rectOf`)

/// One entry per `.tourAnchor(_:)`-tagged view, keyed by the same string
/// Tour.tsx used as its `data-tour` value. `reduce` keeps the FIRST writer
/// for a given id, mirroring `document.querySelector` returning the first
/// DOM match — this matters for "switch", which (like LaneHeader.tsx:73)
/// rides EVERY non-active, non-pinned lane: the web spotlights the topmost
/// lane's SWITCH, so the native side must too (review 2026-08-08 P2-1: a
/// last-writer merge picked the bottom-most).
struct TourAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { existing, _ in existing }
    }
}

extension View {
    /// Tags this view as a tour target, the native twin of the web's
    /// `data-tour="<id>"`. Layout changes (resize, scroll, a lane
    /// appearing/disappearing) update the resolved rect automatically —
    /// SwiftUI recomputes anchor preferences as part of layout, so there is
    /// no polling loop here (Tour.tsx:74-76's 500ms `setInterval` has no
    /// native equivalent needed).
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
    }

    /// Conditional twin of `tourAnchor(_:)` — LaneHeader.tsx:119's
    /// `data-tour={active ? "runway" : undefined}` tags the runway anchor
    /// on the ACTIVE lane only; every other lane renders identically but
    /// carries no anchor.
    @ViewBuilder
    func tourAnchor(_ id: String, when condition: Bool) -> some View {
        if condition {
            tourAnchor(id)
        } else {
            self
        }
    }
}

// MARK: - spotlight cutout (Tour.tsx:129-139)

/// Even-odd fill: the outer rect minus a rounded hole at the target —
/// native twin of the web's enormous-spread `boxShadow` trick. `hole` is
/// already outset by the ring's -4pt/+8pt (TourOverlayView applies that
/// before constructing this shape).
private struct SpotlightMask: Shape {
    let hole: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return p
    }
}

// MARK: - keyboard (Tour.tsx:84-94)

/// App-wide `NSEvent` key monitor scoped to this view's own window, same
/// discipline as BoardInspector.swift's `DismissMonitor`: the guard on
/// `event.window === self.window && isKeyWindow` means Escape/→ are
/// swallowed here ONLY while the tour's own window is key — the instant a
/// `.sheet` is presented on top (Settings, Add account), ITS window becomes
/// key instead, so its own `.keyboardShortcut(.cancelAction)` Close button
/// receives Escape unmolested. (In practice the tour's full-window backdrop
/// button already blocks every click that could open such a sheet while the
/// guide is up, but the guard costs nothing and removes the ambiguity for
/// good.)
private struct TourKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onArrowRight: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEscape = onEscape
        view.onArrowRight = onArrowRight
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onArrowRight = onArrowRight
    }

    final class MonitorView: NSView {
        var onEscape: (() -> Void)?
        var onArrowRight: (() -> Void)?
        private var keyMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      self.window?.isKeyWindow == true
                else { return event }
                switch event.keyCode {
                case 53: // Escape
                    self.onEscape?()
                    return nil
                case 124: // Right arrow
                    self.onArrowRight?()
                    return nil
                default:
                    return event
                }
            }
        }

        private func teardown() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        deinit { teardown() }
    }
}

// MARK: - overlay

/// The full-window guide: mount this from `.overlayPreferenceValue(TourAnchorPreferenceKey.self)`
/// at an ancestor of every `.tourAnchor(_:)`-tagged view (NativeCockpitWindow.swift's `content(_:)`),
/// wrapped in a `GeometryReader` so anchors resolve into this view's own
/// coordinate space.
struct TourOverlayView: View {
    @ObservedObject var model: TourModel
    let anchors: [String: Anchor<CGRect>]
    let geometry: GeometryProxy
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nextFocused: Bool
    @State private var cardHeight: CGFloat = TourCardLayout.cardHeightEstimate
    @State private var appeared = false

    var body: some View {
        ZStack {
            if let step = model.current, let anchor = anchors[step.target] {
                content(step: step, rect: geometry[anchor])
            }
        }
        .background(TourKeyMonitor(onEscape: dismiss, onArrowRight: advance))
        .onAppear { syncAnchors() }
        .onChange(of: Set(anchors.keys)) { _ in syncAnchors() }
    }

    private func syncAnchors() {
        model.availableTargets = Set(anchors.keys)
        if model.isDone { onDone() }
    }

    private func dismiss() {
        model.end()
        onDone()
    }

    private func advance() {
        model.advance()
        if model.isDone { onDone() }
    }

    @ViewBuilder
    private func content(step: TourStep, rect: CGRect) -> some View {
        let ring = rect.insetBy(dx: -4, dy: -4)
        let origin = TourCardLayout.origin(targetRect: rect, cardHeight: cardHeight, viewport: geometry.size)

        // Tour.tsx:129-139 — the dimmed backdrop with the cutout ring.
        // Visual only: `.allowsHitTesting(false)` so the click-through-ends
        // backdrop button below still owns every click, including one
        // landing on the "spotlighted" element itself (Tour.tsx's own ring
        // div is `pointer-events-none` for the same reason).
        SpotlightMask(hole: ring, cornerRadius: 7)
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

        RoundedRectangle(cornerRadius: 7)
            .stroke(CockpitTheme.accent, lineWidth: 2)
            .frame(width: ring.width, height: ring.height)
            .position(x: ring.midX, y: ring.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

        // Tour.tsx:141-145 — backdrop click ends the guide, the same escape
        // the close affordance gives.
        Button(action: dismiss) {
            Color.clear
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityIdentifier("tour-close")
        .accessibilityLabel("Close the guide")

        card(step: step)
            .position(x: origin.x + TourCardLayout.cardWidth / 2, y: origin.y + cardHeight / 2)
            .onAppear { appeared = true }
    }

    private func card(step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(model.stepNumber) OF \(model.total)")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundColor(CockpitTheme.ter)
                // A plain Text's own AXStaticText role reports its rendered
                // string as AXValue natively — more reliable over external
                // AX (scripts/e2e-native.sh) than a custom
                // `.accessibilityValue(_:)` on the "tour-card" GROUP below,
                // which measured as ungettable through System Events despite
                // being set (an AXGroup constructed via `.accessibilityElement
                // (children: .contain)` did not publish it).
                .accessibilityIdentifier("tour-step")
            Text(step.title)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.top, 6)
            Text(step.body)
                .font(.system(size: 11.5))
                .foregroundColor(CockpitTheme.sec)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack {
                if !model.isLast {
                    Button("Skip the guide", action: dismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(CockpitTheme.ter)
                        .accessibilityIdentifier("tour-skip")
                }
                Spacer()
                Button(model.isLast ? "Got it" : "Next", action: advance)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CockpitTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .focused($nextFocused)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tour-next")
            }
            .padding(.top, 12)
        }
        .padding(14)
        .frame(width: TourCardLayout.cardWidth, alignment: .leading)
        .background(CockpitTheme.win, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(CockpitTheme.hair, lineWidth: 1))
        .background(alignment: .topLeading) {
            GeometryReader { geo in
                Color.clear.preference(key: TourCardHeightKey.self, value: geo.size.height)
            }
        }
        .onPreferenceChange(TourCardHeightKey.self) { h in
            if h > 0, abs(h - cardHeight) > 1 { cardHeight = h }
        }
        // Tour.tsx's `animate-[rise-in_200ms_ease-out_both]`: 8px rise +
        // fade, collapsed to a snap under reduced motion (theme.css's
        // prefers-reduced-motion override zeroes every animation duration).
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appeared)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour-card")
        .onAppear { nextFocused = true }
    }
}

private struct TourCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
