import AppKit
import SwiftUI

// The statusline editor's view half (the model half is
// StatuslineEditorModel.swift). Rebuilt 2026-10-03 (owner-picked design,
// UX audit U1): the line IS the UI — a strip of
// draggable chips, each carrying the segment's own rendered bytes, above a
// tray of everything not on it. Drag between the strips to add, remove and
// reorder; click a chip for its options. The preview strip stays the
// daemon's bytes for the whole line (preview == production).
// The drag is in-view (2026-10-04): a pressed chip lifts and follows the
// pointer, and the other chips slide aside to open the gap it will land in.

private extension Color {
    /// Parses `#rrggbb` (the only shape a statusline "color" option ever
    /// carries — internal/statusline/tier.go parseHex). Distinct from
    /// Ansi.swift's `AnsiSpan.swiftUIColor`, which also accepts `rgb(...)`
    /// for preview-strip spans; option values are hex-only.
    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    /// The inverse — matches HTML `<input type="color">`'s own wire format
    /// (lowercase `#rrggbb`), which is what the web editor stores.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

/// One segment's option row — native mirror of StatuslineDialog.tsx's
/// `OptionControl` (lines 39-114): bool -> Toggle, enum -> Picker,
/// color -> ColorPicker + conditional "clear" link, string -> TextField
/// where an empty value DELETES the key.
private struct StatuslineOptionControl: View {
    let spec: SLOptionSpec
    let segLabel: String
    let segmentID: String
    @ObservedObject var model: StatuslineEditorModel

    private var currentValue: JSONValue? { model.optionValue(segmentID: segmentID, key: spec.key) }
    private var a11yLabel: String { "\(segLabel): \(spec.label)" }

    var body: some View {
        HStack(spacing: 12) {
            Text(spec.label).font(.system(size: 11.5)).foregroundColor(CockpitTheme.sec)
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.type {
        case "bool":
            Toggle("", isOn: Binding(
                get: { (currentValue ?? spec.defaultValue)?.boolValue == true },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: .bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(a11yLabel)

        case "enum":
            let values = spec.values ?? []
            let current = currentValue?.stringValue ?? spec.defaultValue?.stringValue ?? values.first ?? ""
            Picker("", selection: Binding(
                get: { current },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: .string($0)) }
            )) {
                ForEach(values, id: \.self) { v in Text(v).tag(v) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 200)
            .accessibilityLabel(a11yLabel)

        case "color":
            let isSet: Bool = {
                if case let .string(s)? = currentValue, !s.isEmpty { return true }
                return false
            }()
            let hex = isSet ? (currentValue?.stringValue ?? "#0a7aff") : "#0a7aff"
            HStack(spacing: 6) {
                if isSet {
                    Button("clear") {
                        model.setOption(segmentID: segmentID, key: spec.key, value: nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
                    .accessibilityLabel("Clear \(a11yLabel)")
                }
                ColorPicker("", selection: Binding(
                    get: { Color(hexString: hex) ?? CockpitTheme.accent },
                    set: { model.setOption(segmentID: segmentID, key: spec.key, value: .string($0.hexString)) }
                ))
                .labelsHidden()
                .accessibilityLabel(a11yLabel)
            }

        default: // "string"
            TextField("", text: Binding(
                get: { currentValue?.stringValue ?? "" },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: $0.isEmpty ? nil : .string($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 160)
            .accessibilityLabel(a11yLabel)
        }
    }
}

// MARK: - chip flow layout

/// A subview laid out as if absent. The dragged chip's own view stays
/// mounted in its home strip — its gesture lives there — while the strip
/// closes up around it.
struct ChipCollapsed: LayoutValueKey {
    static let defaultValue = false
}

/// Wraps chips into rows like the mock's flex-wrap strips. A `Layout` so
/// the strips can report real chip frames for drop-index math, and so a
/// change of order animates as chips sliding to their new places.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for sv in subviews where !sv[ChipCollapsed.self] {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            if sv[ChipCollapsed.self] {
                sv.place(at: bounds.origin, proposal: .zero)
                continue
            }
            let s = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Chip, gap and strip frames in the editor's coordinate space — what the
/// in-view drag hit-tests against.
struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

enum ChipStrip: Equatable {
    case line, tray
}

/// What a strip lays out while a drag is live: a chip, or the gap the
/// dragged chip would land in.
enum ChipSlot: Hashable, Identifiable {
    case chip(String)
    case gap

    var id: String {
        switch self {
        case let .chip(id): return id
        case .gap: return ChipDrop.gapKey
        }
    }
}

/// The chip in the air. Plain state, so where it lands is testable
/// without a view.
struct ChipDrag: Equatable {
    let id: String
    let home: ChipStrip
    /// Its slot in the home strip at press.
    let homeIndex: Int
    /// Its frame at press, editor space.
    let origin: CGRect
    /// Where the press began, editor space.
    let press: CGPoint
    /// Where it would land now — home when it is over neither strip — and
    /// the slot there, counted with this chip taken out.
    var target: ChipStrip
    var index: Int
    /// Past the click threshold: a release drops instead of opening options.
    var moved = false
    /// Released: the gap is gone and the chip waits as a ghost in its
    /// landing slot while the lifted copy settles onto it.
    var settling = false

    init(id: String, home: ChipStrip, homeIndex: Int, origin: CGRect, press: CGPoint) {
        self.id = id
        self.home = home
        self.homeIndex = homeIndex
        self.origin = origin
        self.press = press
        target = home
        index = homeIndex
    }

    /// The pointer's offset into the chip: it hangs where it was grabbed.
    var grab: CGSize { CGSize(width: press.x - origin.minX, height: press.y - origin.minY) }

    mutating func goHome() {
        target = home
        index = homeIndex
    }
}

/// The drag's pure rules: which slot is under the pointer, what each strip
/// shows, and what a release does to the line.
enum ChipDrop {
    static let gapKey = "\u{0}gap"
    static let lineKey = "\u{0}line"
    static let trayKey = "\u{0}tray"
    static let previewKey = "\u{0}preview"
    static let previewBoxKey = "\u{0}previewbox"

    /// Where a drop at `point` lands among chips laid out in rows — the
    /// index of the first chip that is on a LOWER row, or on the same row
    /// with its midpoint right of the point. `count` when past every chip.
    static func index(at point: CGPoint, frames: [CGRect]) -> Int {
        for (i, f) in frames.enumerated() {
            if point.y < f.minY { return i }
            if point.y <= f.maxY, point.x < f.midX { return i }
        }
        return frames.count
    }

    /// The line slot under `point`, from the chips as they sit now (the
    /// dragged one excluded). While the pointer is inside the open gap the
    /// slot holds, so chips that slid aside can't flip it straight back.
    static func lineIndex(at point: CGPoint, chips: [CGRect], gap: CGRect?, current: Int) -> Int {
        if let gap, gap.insetBy(dx: -3, dy: -3).contains(point) { return current }
        return index(at: point, frames: chips)
    }

    /// The tray keeps the registry's order, so a chip put there lands in
    /// its registry slot, not under the pointer.
    static func trayIndex(of id: String, registry: [String], tray: [String]) -> Int {
        guard let r = registry.firstIndex(of: id) else { return tray.count }
        let earlier = Set(registry[..<r])
        return tray.filter { earlier.contains($0) }.count
    }

    /// A strip's slots: its chips (the dragged one stays in its home list —
    /// the view collapses it) plus the gap, if the chip would land here.
    static func slots(_ ids: [String], strip: ChipStrip, drag: ChipDrag?) -> [ChipSlot] {
        var out = ids.map(ChipSlot.chip)
        guard let drag, !drag.settling, drag.target == strip else { return out }
        let others = ids.filter { $0 != drag.id }
        let k = min(max(drag.index, 0), others.count)
        let at = k < others.count ? (ids.firstIndex(of: others[k]) ?? ids.count) : ids.count
        out.insert(.gap, at: at)
        return out
    }

    enum Landing: Equatable {
        case none
        case move(String, before: Int)
        case add(String, at: Int)
        case remove(String)
    }

    /// What releasing `drag` does to the line (`line` = its ids now).
    static func landing(_ drag: ChipDrag, line: [String]) -> Landing {
        switch (drag.home, drag.target) {
        case (.line, .line):
            guard let from = line.firstIndex(of: drag.id) else { return .none }
            // `index` counts with the chip taken out; moveSegment's
            // `before` counts with it still in.
            let before = drag.index >= from ? drag.index + 1 : drag.index
            return before == from || before == from + 1 ? .none : .move(drag.id, before: before)
        case (.line, .tray):
            return .remove(drag.id)
        case (.tray, .line):
            return .add(drag.id, at: drag.index)
        case (.tray, .tray):
            return .none
        }
    }

    /// Hands a landing to the model's existing edits — the drag adds no
    /// new way to change the line.
    @MainActor
    static func commit(_ landing: Landing, to model: StatuslineEditorModel) {
        switch landing {
        case .none: break
        case let .move(id, before): model.moveSegment(id, before: before)
        case let .add(id, at): model.addSegment(id, at: at)
        case let .remove(id): model.removeSegment(id)
        }
    }
}

/// The pointer while a chip is in the air.
final class ChipPointer: ObservableObject {
    @Published var point: CGPoint = .zero
}

/// The lifted copy: opaque, drag shadow + 1.5px accent ring, a slight
/// scale, hung off the pointer where it was grabbed. Tracking is raw; only
/// the lift and the settle animate.
private struct LiftedChip<Face: View>: View {
    @ObservedObject var pointer: ChipPointer
    let drag: ChipDrag
    let settleFrame: CGRect?
    let up: Bool
    let reduceMotion: Bool
    let motion: Animation?
    let face: Face

    var body: some View {
        let at = settleFrame?.origin
            ?? CGPoint(x: pointer.point.x - drag.grab.width, y: pointer.point.y - drag.grab.height)
        let shadow = CockpitTheme.shadowDrag[0]
        face
            .frame(width: drag.origin.width, height: drag.origin.height)
            .background(RoundedRectangle(cornerRadius: 6).fill(CockpitTheme.win))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CockpitTheme.accent, lineWidth: 1.5).opacity(up ? 1 : 0))
            .scaleEffect(up && !reduceMotion ? 1.04 : 1)
            .shadow(color: up ? shadow.color : .clear, radius: shadow.radius, x: shadow.x, y: up ? shadow.y : 0)
            .animation(motion, value: up)
            .offset(x: at.x, y: at.y)
            .transaction { if settleFrame == nil { $0.animation = nil } }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - the editor

struct StatuslineEditorView: View {
    @ObservedObject var model: StatuslineEditorModel
    var offline: Bool = false

    /// The chip whose options popover is open.
    @State private var selectedID: String?
    @State private var frames: [String: CGRect] = [:]
    /// The width the preview section has, so the box can size its font.
    @State private var previewAvailable: CGFloat = 0
    /// The chip in the air.
    @State private var drag: ChipDrag?
    /// The raw pointer, in its own object so a pointer move re-renders the
    /// lifted chip alone, never the whole editor (and is never animated).
    @StateObject private var pointer = ChipPointer()
    /// Set on release: the frame the lifted chip settles onto.
    @State private var settleFrame: CGRect?
    /// Flips on once the lifted chip is on screen, so the lift animates.
    @State private var lifted = false
    /// The line's height at press, held while a chip is in the air: a line
    /// that shrank as its chip left would pull the tray up from under the
    /// pointer, and the chip would flip back home.
    @State private var heldLineHeight: CGFloat?
    /// The press Escape cancelled — the rest of that gesture is ignored.
    @State private var cancelledPress: CGPoint?
    @State private var escapeMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "statusline-editor"
    /// DESIGN-SYSTEM.md Motion: state changes 150ms ease-out; reduced
    /// motion = instant.
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.15) }

    var body: some View {
        Group {
            if offline {
                offlineView
            } else {
                onlineView
            }
        }
        .task(id: offline) { // re-load when the daemon comes up mid-open (StatuslineDialog.tsx:140 deps [open, offline])
            guard !offline else { return }
            await model.load()
        }
    }

    // MARK: - offline (StatuslineDialog.tsx:192-197)

    private var offlineView: some View {
        (
            Text(StatuslineEditorCopy.offlinePrefix)
                + Text(StatuslineEditorCopy.offlineCommand).fontWeight(.semibold).font(.system(size: 12, design: .monospaced))
        )
        .font(.system(size: 12))
        .foregroundColor(CockpitTheme.sec)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - online

    private var onlineView: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewSection
            Text(StatuslineEditorCopy.previewHelper)
                .font(.system(size: 10.5))
                .foregroundColor(CockpitTheme.ter)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.err {
                CockpitWarnBox {
                    Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }

            keptStatuslineChip

            if model.meta != nil {
                eyebrow(StatuslineEditorCopy.presetHeader)
                presetsRow

                HStack(alignment: .firstTextBaseline) {
                    eyebrow(StatuslineEditorCopy.yourLineHeader)
                    Spacer()
                    let n = model.lineSegmentCount
                    if n > 0 {
                        Text("\(n) segment\(n == 1 ? "" : "s")")
                            .font(CockpitTheme.numeric(10.5))
                            .foregroundColor(CockpitTheme.ter)
                    }
                }
                lineStrip
                Text(StatuslineEditorCopy.legend)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)

                eyebrow(StatuslineEditorCopy.trayHeader)
                trayStrip
            }

            footer
        }
        // No root padding: SheetChrome owns the inset ring (owner
        // 2026-08-13 — the doubled padding broke the HIG's equal-margins
        // rule on all three cockpit sheets).
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ChipFramesKey.self) { frames = $0 }
        .overlay(alignment: .topLeading) { liftedChip }
        .onDisappear { endDrag() } // the strips unmount (daemon down, sheet closed): no release will come
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundColor(CockpitTheme.ter)
    }

    // MARK: - preview strip (StatuslineDialog.tsx:200-223)

    /// The preview box is a monospaced terminal: one cell per column. It
    /// hugs its rows (`previewBoxCells`), so a wide real terminal with a
    /// short line stays a compact box at the full 11.5pt. The font shrinks
    /// only when the cells would overflow the sheet, never under 9pt
    /// (DESIGN-SYSTEM.md); past that the box scrolls sideways.
    static let previewFontBase: CGFloat = 11.5
    static let previewFontFloor: CGFloat = 9
    static let previewBoxInset: CGFloat = 12

    /// One monospaced cell at `fontSize`.
    static func previewAdvance(fontSize: CGFloat) -> CGFloat {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).maximumAdvancement.width
    }

    /// The width of the box's content: `cells` cells.
    static func previewBoxWidth(cells: Int, fontSize: CGFloat) -> CGFloat {
        CGFloat(cells) * previewAdvance(fontSize: fontSize)
    }

    /// The box content's width for `rows`: `cells` monospaced cells, or —
    /// when a row holds wide glyphs (CJK, emoji) that render wider than one
    /// cell each — the widest row as actually laid out at `fontSize`, plus
    /// the 2-cell indent. The cut rule counts Characters and is unchanged.
    static func previewContentWidth(rows: [[AnsiSpan]], cells: Int, fontSize: CGFloat) -> CGFloat {
        let cellsWidth = previewBoxWidth(cells: cells, fontSize: fontSize)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let widest = rows
            .map { NSAttributedString(string: $0.map(\.text).joined(), attributes: [.font: font]).size().width }
            .max() ?? 0
        return max(cellsWidth, ceil(widest) + 2 * previewAdvance(fontSize: fontSize))
    }

    /// 11.5pt, or the largest size down to the floor at which `width(size)`
    /// fits `available` points. `available` <= 0 means not measured yet.
    static func previewFontSize(available: CGFloat, width: (CGFloat) -> CGFloat) -> CGFloat {
        guard available > 0, width(previewFontBase) > available else { return previewFontBase }
        var size = previewFontBase * available / width(previewFontBase)
        while size > previewFontFloor, width(size) > available { size -= 0.1 }
        return max(previewFontFloor, size)
    }

    static func previewFontSize(cells: Int, available: CGFloat) -> CGFloat {
        previewFontSize(available: available) { previewBoxWidth(cells: cells, fontSize: $0) }
    }

    private struct PreviewWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var previewSection: some View {
        let columns = model.previewRenderedColumns
        let rows = previewRows(model.preview, columns: columns)
        let placeholder = model.lineSegmentCount == 0
            ? StatuslineEditorCopy.emptyLine
            : StatuslineEditorCopy.renderingPlaceholder
        let cells = rows.isEmpty ? min(columns, placeholder.count + 2) : previewBoxCells(rows, columns: columns)
        let available = max(previewAvailable - Self.previewBoxInset * 2, 0)
        let contentWidth = { (size: CGFloat) in Self.previewContentWidth(rows: rows, cells: cells, fontSize: size) }
        let fontSize = Self.previewFontSize(available: available, width: contentWidth)
        let advance = Self.previewAdvance(fontSize: fontSize)
        let boxWidth = contentWidth(fontSize)
        // What VoiceOver reads is what the eye sees: the rows as cut.
        let plain = rows.map { $0.map(\.text).joined() }.joined(separator: "\n")
        let caption = StatuslineEditorCopy.widthCaption(real: model.previewWidthIsReal)

        // One Text per row, never wrapped — Claude Code cuts a long row with
        // "…" and previewRows does the same.
        let box = VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Text(placeholder)
                    .foregroundColor(CockpitTheme.grayDot)
                    .padding(.leading, advance * 2)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, spans in
                    Text(spans.isEmpty
                        ? AttributedString(" ")
                        : ansiAttributedString(spans, defaultColor: CockpitTheme.hudTx))
                        .padding(.leading, advance * 2)
                }
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .frame(width: boxWidth, alignment: .topLeading)
        .padding(.horizontal, Self.previewBoxInset)
        .padding(.vertical, 10)
        .background(CockpitTheme.hudBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatuslineEditorCopy.previewLabel(columns: columns))
        .accessibilityValue(plain)
        .background(frameReporter(ChipDrop.previewBoxKey))

        return VStack(alignment: .leading, spacing: 6) {
            // Nothing until a render has answered: before that the width is
            // unknown, and the default's text would be a claim about nothing.
            if model.previewWidthLanded {
                (Text(caption.lead) + Text("\(columns)").font(CockpitTheme.numeric(10.5)) + Text(caption.tail))
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
                    .accessibilityIdentifier("statusline-width-caption")
            }
            if let command = model.draft?.keep?.command {
                Text(StatuslineEditorCopy.keptPreviewNote(command))
                    .font(.system(size: 11.5, design: .monospaced))
                    .italic()
                    .foregroundColor(CockpitTheme.grayDot)
            }
            // Last resort: a very wide terminal AND a very long row at the
            // 9pt floor. Claude Code isn't cutting that row either, so
            // scrolling it is the truth, not a clip.
            if available > 0, boxWidth > available + 0.5 {
                // Capped at the section's own width: a ScrollView reports its
                // content's width as its ideal, which would grow the sheet.
                ScrollView(.horizontal) { box }
                    .frame(maxWidth: previewAvailable)
            } else {
                box
            }
        }
        // minWidth 0: a box wider than the sheet must not widen this
        // section — it measures the width the sheet GIVES it, and the
        // font shrinks (or the box scrolls) to fit.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(frameReporter(ChipDrop.previewKey))
        .background(GeometryReader { geo in
            Color.clear.preference(key: PreviewWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(PreviewWidthKey.self) { previewAvailable = $0 }
    }

    // MARK: - kept statusline chip (StatuslineDialog.tsx:236-250)

    @ViewBuilder
    private var keptStatuslineChip: some View {
        if let command = model.draft?.keep?.command {
            HStack {
                (
                    Text(StatuslineEditorCopy.keptStatuslineTitle).fontWeight(.semibold)
                        + Text(StatuslineEditorCopy.keptStatuslineMid)
                        + Text(command).font(.system(size: 10.5, design: .monospaced))
                )
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.sec)
                Spacer(minLength: 8)
                Button(action: { model.clearKeep() }) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(CockpitTheme.ter)
                .accessibilityLabel("Remove kept statusline")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
        }
    }

    // MARK: - presets (a segmented control; Custom lights up by itself)

    private var presetsRow: some View {
        let presets = model.meta?.presets ?? []
        let selected = model.selectedPresetID
        return segmentedTrack {
            ForEach(presets) { p in
                presetSegment(title: p.name, isOn: selected == p.id, enabled: true) {
                    selectedID = nil
                    model.selectPreset(p)
                }
                .help(Text(p.desc))
                .accessibilityIdentifier("statusline-preset-\(p.id)")
            }
            presetSegment(title: StatuslineEditorCopy.customPreset, isOn: selected.isEmpty, enabled: false) {}
                .help(Text("Becomes active as soon as you change the line"))
                .accessibilityIdentifier("statusline-preset-custom")
        }
    }

    /// The track the preset segments sit in.
    private func segmentedTrack<Segments: View>(@ViewBuilder _ segments: () -> Segments) -> some View {
        HStack(spacing: 2, content: segments)
            .padding(2)
            .background(CockpitTheme.hatchBg)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(CockpitTheme.hairSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func presetSegment(title: String, isOn: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isOn ? CockpitTheme.text : (enabled ? CockpitTheme.sec : CockpitTheme.grayDot))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isOn ? CockpitTheme.toolbar : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn ? CockpitTheme.hair : Color.clear, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - your line

    private var lineSegments: [SLSegmentConfig] { model.draft?.segments ?? [] }

    private var lineStrip: some View {
        let slots = ChipDrop.slots(lineSegments.map(\.id), strip: .line, drag: drag)
        // Lit only when a tray chip is about to join — a reorder inside
        // the line already shows its gap.
        let targeted = drag.map { !$0.settling && $0.home == .tray && $0.target == .line } ?? false
        return stripContent(slots, strip: .line, empty: StatuslineEditorCopy.emptyLine)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: max(64, heldLineHeight ?? 0), alignment: .topLeading)
            .background(targeted ? CockpitTheme.accA : CockpitTheme.toolbar)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? CockpitTheme.accBd : CockpitTheme.hair, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(frameReporter(ChipDrop.lineKey))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(StatuslineEditorCopy.yourLineHeader)
            .accessibilityIdentifier("statusline-line")
    }

    // MARK: - not in your line

    private var trayStrip: some View {
        let slots = ChipDrop.slots(model.availableSegments.map(\.id), strip: .tray, drag: drag)
        let targeted = drag.map { !$0.settling && $0.home == .line && $0.target == .tray } ?? false
        return stripContent(slots, strip: .tray, empty: StatuslineEditorCopy.trayEmpty)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(targeted ? CockpitTheme.accA : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(targeted ? CockpitTheme.accBd : CockpitTheme.hair))
            .background(frameReporter(ChipDrop.trayKey))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(StatuslineEditorCopy.trayHeader)
            .accessibilityIdentifier("statusline-tray")
    }

    /// One strip's chips. The layout stays mounted while the dragged chip
    /// is its only (collapsed) member: unmounting it would end the drag.
    private func stripContent(_ slots: [ChipSlot], strip: ChipStrip, empty: String) -> some View {
        let showsNothing = slots.allSatisfy { if case let .chip(id) = $0 { return isCollapsed(id) } else { return false } }
        return ZStack(alignment: .topLeading) {
            if showsNothing {
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.grayDot)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            if !slots.isEmpty {
                ChipFlowLayout(spacing: 6) {
                    ForEach(slots) { slot in
                        Group {
                            switch slot {
                            case .gap: gap
                            case let .chip(id): chip(id: id, strip: strip)
                            }
                        }
                        .layoutValue(key: ChipCollapsed.self, value: slot.id == drag?.id && isCollapsed(slot.id))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The dragged chip's own view while it is in the air.
    private func isCollapsed(_ id: String) -> Bool {
        drag?.id == id && drag?.settling == false
    }

    private func frameReporter(_ key: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: ChipFramesKey.self, value: [key: geo.frame(in: .named(Self.space))])
        }
    }

    /// DESIGN-SYSTEM.md ghost: 1.5px dashed accBd at 50% — where the chip
    /// will sit when you let go.
    private var ghostOutline: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundColor(CockpitTheme.accBd.opacity(0.5))
    }

    private var gap: some View {
        let size = drag?.origin.size ?? .zero
        return Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(ghostOutline)
            .background(frameReporter(ChipDrop.gapKey))
            .accessibilityHidden(true)
    }

    // MARK: - chip

    private func chip(id: String, strip: ChipStrip) -> some View {
        let onLine = strip == .line
        let options = onLine ? lineSegments.first(where: { $0.id == id })?.options : nil
        let name = model.specFor(id)?.name ?? id
        let rendered = model.segmentPreview(id: id, options: options)
        let isSelected = selectedID == id
        let lineIDs = lineSegments.map(\.id)
        let position = lineIDs.firstIndex(of: id)
        let inAir = drag?.id == id
        // A Button, not a tap gesture: it is focusable under Full Keyboard
        // Access and Space/Return opens the options — the keyboard and
        // VoiceOver path the old chevron buttons used to be (review
        // 2026-10-03 P1). The pointer goes through the drag gesture, which
        // treats a release without movement as the click.
        return Button(action: { selectedID = isSelected ? nil : id }) {
            chipFace(id: id, options: options, onLine: onLine, isSelected: isSelected)
                .opacity(inAir ? 0 : (onLine ? 1 : 0.62))
                .overlay { if inAir && drag?.settling == true { ghostOutline } }
        }
        .buttonStyle(.plain)
        .highPriorityGesture(dragGesture(id: id, strip: strip))
        .background(frameReporter(id))
        .popover(isPresented: Binding(get: { selectedID == id }, set: { if !$0, selectedID == id { selectedID = nil } }),
                 arrowEdge: .bottom) {
            optionsPopover(id: id, onLine: onLine)
        }
        .accessibilityLabel("\(name), \(onLine ? StatuslineEditorCopy.onLine : StatuslineEditorCopy.offLine)")
        .accessibilityValue(id == StatuslineEditorModel.newlineID ? StatuslineEditorCopy.newlineHint : (rendered?.plain ?? ""))
        .accessibilityAction(named: Text(onLine ? StatuslineEditorCopy.takeOffLine : StatuslineEditorCopy.addToLine)) {
            if onLine { model.removeSegment(id) } else { model.addSegment(id) }
        }
        .accessibilityAction(named: Text(StatuslineEditorCopy.moveLeft)) {
            if let position, position > 0 { model.moveSegment(id, before: position - 1) }
        }
        .accessibilityAction(named: Text(StatuslineEditorCopy.moveRight)) {
            if let position, position < lineIDs.count - 1 { model.moveSegment(id, before: position + 2) }
        }
        .accessibilityIdentifier("statusline-chip-\(id)")
    }

    /// What a chip looks like, shared by the chip in its strip and the
    /// lifted copy that follows the pointer.
    private func chipFace(id: String, options: [String: JSONValue]?, onLine: Bool, isSelected: Bool) -> some View {
        let spec = model.specFor(id)
        let name = spec?.name ?? id
        let bytes = model.segmentPreview(id: id, options: options)?.line
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(CockpitTheme.grayDot)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundColor(onLine ? CockpitTheme.accTx : CockpitTheme.sec)
                if spec?.fleet == true {
                    Text(StatuslineEditorCopy.daemonBadge)
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(CockpitTheme.chipBg)
                        .foregroundColor(CockpitTheme.accTx)
                        .clipShape(Capsule())
                }
            }
            Group {
                if id == StatuslineEditorModel.newlineID {
                    // A row break renders no bytes of its own: say what it does.
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(StatuslineEditorCopy.newlineHint)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(CockpitTheme.grayDot)
                } else if let bytes, !bytes.isEmpty {
                    Text(ansiAttributedString(parseAnsi(bytes), defaultColor: CockpitTheme.text))
                        .font(.system(size: 11.5, design: .monospaced))
                } else if bytes != nil {
                    Text(StatuslineEditorCopy.quietSegment)
                        .font(.system(size: 11))
                        .foregroundColor(CockpitTheme.grayDot)
                } else {
                    Text(StatuslineEditorCopy.renderingPlaceholder)
                        .font(.system(size: 11))
                        .foregroundColor(CockpitTheme.grayDot)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        // Wide enough for a long fleet line, never wider than the strip:
        // a chip past the strip's edge used to be cut mid-text.
        .frame(maxWidth: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .background(onLine ? CockpitTheme.chipBg : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(onLine ? CockpitTheme.chipBd : CockpitTheme.hair, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.accent, lineWidth: isSelected ? 2.5 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    // MARK: - drag (the chip lifts and follows the pointer)

    @ViewBuilder
    private var liftedChip: some View {
        if let drag {
            let onLine = drag.home == .line
            let options = onLine ? lineSegments.first(where: { $0.id == drag.id })?.options : nil
            LiftedChip(pointer: pointer, drag: drag, settleFrame: settleFrame, up: lifted && !drag.settling,
                       reduceMotion: reduceMotion, motion: motion,
                       face: chipFace(id: drag.id, options: options, onLine: onLine, isSelected: false))
                .onAppear { lifted = true }
                .id("\(drag.press.x),\(drag.press.y)") // a new drag, a new lift
        }
    }

    private func dragGesture(id: String, strip: ChipStrip) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { dragChanged(id: id, strip: strip, value: $0) }
            .onEnded { dragEnded(id: id, value: $0) }
    }

    private func dragChanged(id: String, strip: ChipStrip, value v: DragGesture.Value) {
        if let cancelledPress {
            if cancelledPress == v.startLocation { return }
            self.cancelledPress = nil
        }
        if let current = drag, current.press != v.startLocation {
            endDrag() // a new press: finish a settle now, or drop a drag whose release never came
        }
        guard let current = drag else {
            // Press: pick the chip up from where it sits.
            let homeIDs = strip == .line ? lineSegments.map(\.id) : model.availableSegments.map(\.id)
            guard let origin = frames[id], let homeIndex = homeIDs.firstIndex(of: id) else { return }
            drag = ChipDrag(id: id, home: strip, homeIndex: homeIndex, origin: origin, press: v.startLocation)
            pointer.point = v.location
            heldLineHeight = frames[ChipDrop.lineKey]?.height
            armEscape()
            return
        }
        guard current.id == id, !current.settling else { return }
        pointer.point = v.location
        var next = current
        if !next.moved, hypot(v.translation.width, v.translation.height) > 3 {
            next.moved = true
            selectedID = nil
        }
        if next.moved { aim(&next, at: v.location) }
        guard next != current else { return }
        if next.target != current.target || next.index != current.index {
            withAnimation(motion) { drag = next } // the others slide aside
        } else {
            drag = next
        }
    }

    /// Where the chip would land with the pointer at `p`.
    private func aim(_ d: inout ChipDrag, at p: CGPoint) {
        if let r = frames[ChipDrop.lineKey], r.insetBy(dx: -8, dy: -8).contains(p) {
            let others = lineSegments.map(\.id).filter { $0 != d.id }
            let chips = others.compactMap { frames[$0] }
            guard chips.count == others.count else { return }
            let gap = d.target == .line ? frames[ChipDrop.gapKey] : nil
            d.index = ChipDrop.lineIndex(at: p, chips: chips, gap: gap, current: d.index)
            d.target = .line
        } else if let r = frames[ChipDrop.trayKey], r.insetBy(dx: -8, dy: -8).contains(p) {
            d.target = .tray
            d.index = d.home == .tray
                ? d.homeIndex
                : ChipDrop.trayIndex(of: d.id, registry: model.meta?.segments.map(\.id) ?? [],
                                     tray: model.availableSegments.map(\.id))
        } else {
            d.goHome()
        }
    }

    private func dragEnded(id: String, value v: DragGesture.Value) {
        if cancelledPress == v.startLocation {
            cancelledPress = nil
            return
        }
        guard let d = drag, d.id == id, !d.settling else { return }
        disarmEscape()
        guard d.moved else {
            // A click: set it back down and open its options.
            settle(d, onto: d.origin)
            selectedID = selectedID == id ? nil : id
            return
        }
        let landing = ChipDrop.landing(d, line: lineSegments.map(\.id))
        let dest = landing == .none ? d.origin : (frames[ChipDrop.gapKey] ?? d.origin)
        ChipDrop.commit(landing, to: model)
        settle(d, onto: dest)
    }

    /// Release: the gap becomes the chip's ghost in the same frame, and the
    /// lifted copy eases onto it. `slideHome` animates the strips too (an
    /// Escape mid-drag sends the other chips back where they were).
    private func settle(_ d: ChipDrag, onto dest: CGRect, slideHome: Bool = false) {
        var s = d
        if slideHome { s.goHome() }
        s.settling = true
        if slideHome { withAnimation(motion) { drag = s } } else { drag = s }
        guard let motion else { return endDrag() }
        withAnimation(motion) { settleFrame = dest }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if drag?.settling == true, drag?.press == d.press { endDrag() }
        }
    }

    private func endDrag() {
        drag = nil
        settleFrame = nil
        lifted = false
        disarmEscape()
        withAnimation(motion) { heldLineHeight = nil }
    }

    /// Escape mid-drag sends the chip home. A local monitor, because no
    /// view holds focus while the pointer is down; it lives only for the
    /// drag, so Escape still closes the sheet otherwise.
    private func armEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, let d = drag, !d.settling else { return event }
            cancelledPress = d.press
            disarmEscape()
            settle(d, onto: d.origin, slideHome: true)
            return nil
        }
    }

    private func disarmEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - options popover

    private func optionsPopover(id: String, onLine: Bool) -> some View {
        let spec = model.specFor(id)
        let name = spec?.name ?? id
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(CockpitTheme.ter)
                Spacer()
                Text(onLine ? StatuslineEditorCopy.onLine : StatuslineEditorCopy.offLine)
                    .font(.system(size: 9))
                    .foregroundColor(CockpitTheme.grayDot)
            }
            .padding(.bottom, 4)
            if let desc = spec?.desc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            if let opts = spec?.options, !opts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(opts, id: \.key) { o in
                        StatuslineOptionControl(spec: o, segLabel: name, segmentID: id, model: model)
                            .overlay(alignment: .top) { Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1) }
                    }
                }
            }
            HStack(spacing: 10) {
                if onLine {
                    Button(StatuslineEditorCopy.takeOffLine) {
                        selectedID = nil
                        model.removeSegment(id)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(CockpitTheme.crit)
                    .accessibilityIdentifier("statusline-chip-remove")
                    let ids = lineSegments.map(\.id)
                    if let at = ids.firstIndex(of: id) {
                        Button(action: { model.moveSegment(id, before: at - 1) }) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(at == 0)
                        .opacity(at == 0 ? 0.3 : 1)
                        .foregroundColor(CockpitTheme.sec)
                        .accessibilityLabel(StatuslineEditorCopy.moveLeft)
                        .accessibilityIdentifier("statusline-chip-move-left")
                        Button(action: { model.moveSegment(id, before: at + 2) }) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(at == ids.count - 1)
                        .opacity(at == ids.count - 1 ? 0.3 : 1)
                        .foregroundColor(CockpitTheme.sec)
                        .accessibilityLabel(StatuslineEditorCopy.moveRight)
                        .accessibilityIdentifier("statusline-chip-move-right")
                    }
                } else {
                    Button(StatuslineEditorCopy.addToLine) {
                        selectedID = nil
                        model.addSegment(id)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(CockpitTheme.accTx)
                    .accessibilityIdentifier("statusline-chip-add")
                }
                Spacer()
                Button(StatuslineEditorCopy.done) { selectedID = nil }
                    .buttonStyle(.plain)
                    .foregroundColor(CockpitTheme.accTx)
            }
            .font(.system(size: 11.5))
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1) }
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - footer (StatuslineDialog.tsx:392-415)

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { model.apply() }) {
                Text(StatuslineEditorCopy.applyButton)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(CockpitTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(model.canApply ? 1 : 0.4)
            .disabled(!model.canApply)
            .accessibilityIdentifier("statusline-apply")

            Button(action: { model.discard() }) {
                Text(StatuslineEditorCopy.discardButton)
                    .font(.system(size: 12))
                    .foregroundColor(CockpitTheme.sec)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
            .opacity(model.dirty ? 1 : 0.4)
            .disabled(!model.dirty)
            .accessibilityIdentifier("statusline-discard")

            if model.applied {
                Text(StatuslineEditorCopy.applied)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.okTx)
                    .padding(.top, 6)
            }

            Spacer(minLength: 8)

            // U5: wire Claude Code from the same sheet — no terminal.
            StatuslineInstallControl(model: model.install)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1)
        }
    }
}
