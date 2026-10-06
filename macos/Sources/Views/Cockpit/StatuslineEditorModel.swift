import Foundation

// Native port of web/src/shell/StatuslineDialog.tsx — the segment/option/
// preset editor over ONE registry served by the daemon, whose preview is
// the REAL renderer's bytes, never a JS/Swift mock (preview==production).
// This file is the model half (state machine, no SwiftUI); StatuslineEditor
// .swift is the view half.

/// Copy pinned verbatim against StatuslineDialog.tsx so a future edit to
/// either side is a one-line diff, not a silent drift.
enum StatuslineEditorCopy {
    static func unreadable(_ err: String) -> String {
        "statusline.json is unreadable — showing defaults. \(err)"
    }
    static let unreachable = "Editor unreachable — daemon not running or too old."
    static let saveFailed = "Save failed — the daemon didn't take it."
    static let previewFailed = "Preview failed."
    static let applied = "Applied — your line updates on its next refresh."

    static let offlinePrefix =
        "Statusline editing needs the daemon — the preview is rendered by it, the same code that " +
        "prints your terminal line. Start it: "
    static let offlineCommand = "llmpilot daemon run"

    static let previewHelper =
        "Rendered by the daemon's real renderer. Claude Code cuts a row that's too wide with “…” — " +
        "so does this. Session fields (model, dir, cost) show sample values."
    /// The line above the preview box, split around the column count so
    /// the view can set the number in tabular numerals.
    /// The width is the last one ANY Claude Code session reported, so the
    /// copy never claims it is "your" terminal's.
    static func widthCaption(real: Bool) -> (lead: String, tail: String) {
        real
            ? ("At the width Claude Code last reported: ", " columns.")
            : ("Claude Code hasn't reported its width yet — previewing at ", " columns.")
    }
    static func previewLabel(columns: Int) -> String { "Statusline preview, \(columns) columns" }
    static let renderingPlaceholder = "rendering…"

    static let emptyLine = "Empty line — drag a segment up from the tray."
    static let yourLineHeader = "Your line"
    static let trayHeader = "Not in your line"
    static let trayEmpty = "Every segment is on your line."
    static let presetHeader = "Preset"
    static let customPreset = "Custom"
    static let legend = "Drag to reorder · drag a chip down to take it off the line · click a chip for its options · New line starts a second row."
    static let newlineHint = "next row starts here"
    static let quietSegment = "nothing to show right now"
    static let takeOffLine = "Take off the line"
    static let moveLeft = "Move left"
    static let moveRight = "Move right"
    static let addToLine = "Add to the line"
    static let done = "Done"
    static let daemonBadge = "daemon"
    static let onLine = "on your line"
    static let offLine = "not on your line"

    static let keptStatuslineTitle = "Kept statusline"
    static let keptStatuslineMid = " — runs above the llmpilot line: "
    static func keptPreviewNote(_ command: String) -> String {
        "(your kept statusline renders here: \(command))"
    }

    static let installHintPrefix = "Not wired into Claude Code yet? Run "
    static let installHintCommand = "llmpilot statusline install"
    static let installHintSuffix = " — an existing statusline is kept unless you say otherwise."

    static let applyButton = "Apply changes"
    static let discardButton = "Discard changes"
}

extension JSONValue {
    var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }
    var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }
}

enum StatuslineEditorError: Error {
    case encodingFailed
}

/// Drives the native statusline editor: fetch-on-open, a debounced live
/// preview through the daemon's real renderer, the preset-detach rule (any
/// manual reorder/add/remove/option-edit clears `preset`), and the
/// apply/discard state machine. Mirrors StatuslineDialog.tsx's `useState`
/// quartet (saved/draft/preview/err/applied) and its `patch`/`move`/`apply`
/// helpers.
@MainActor
final class StatuslineEditorModel: ObservableObject {
    @Published private(set) var meta: StatuslineSegmentsResponse?
    @Published private(set) var saved: StatuslineConfig?
    @Published var draft: StatuslineConfig?
    @Published private(set) var preview: String = ""
    /// The width `preview` was rendered at — the daemon's resolved columns.
    /// The view cuts and labels at it, so the bytes are never cut to a
    /// width they weren't rendered for.
    @Published private(set) var previewRenderedColumns: Int = 120
    /// True when that width is the one Claude Code last gave the
    /// statusline; false when the daemon never saw one and used 120.
    @Published private(set) var previewWidthIsReal = false
    /// False until the first full-line render has answered — the view shows
    /// no width caption before that (and after a failed first call).
    @Published private(set) var previewWidthLanded = false
    /// The registry's row break: a chip like any other, but it renders no
    /// bytes of its own (a lone-segment preview of it is a 400).
    static let newlineID = "newline"
    @Published var err: String?
    @Published private(set) var applied = false
    /// U1: each chip carries the renderer's own bytes for its segment,
    /// keyed by `segmentPreviewKey` (id + options) so a Usage chip in
    /// `bar` mode and one in `percent` mode are different entries.
    @Published private(set) var segmentPreviews: [String: SegmentBytes] = [:]

    /// One chip's render: the coloured bytes for the eye, the plain ones
    /// for VoiceOver (review 2026-10-03: escape codes were being read out).
    struct SegmentBytes: Equatable {
        let line: String
        let plain: String
    }

    private let api: CockpitDaemonAPI & DaemonAPI
    private var previewTask: Task<Void, Never>?
    private var segmentPreviewTask: Task<Void, Never>?
    /// The last message `runPreview` wrote into `err`, so a good render can
    /// clear ITS error without touching a load/save one.
    private var lastPreviewError: String?

    /// The sheet's "Install statusline" control — the same model the doctor
    /// note and Settings mount, so the consent question has one wording.
    private(set) lazy var install = StatuslineInstallModel(api: api)

    /// Live preview debounce (StatuslineDialog.tsx:145 `setTimeout(…, 200)`).
    /// Injectable so tests never wait out a real 200ms.
    var previewDebounceDelay: TimeInterval = 0.2

    init(api: CockpitDaemonAPI & DaemonAPI) {
        self.api = api
    }

    // MARK: - derived state

    /// The "N segments" count: a row break is not a segment.
    var lineSegmentCount: Int {
        (draft?.segments ?? []).filter { $0.id != Self.newlineID }.count
    }

    /// StatuslineDialog.tsx:166 `JSON.stringify(draft) !== JSON.stringify(saved)`.
    var dirty: Bool { draft != saved }

    /// StatuslineDialog.tsx:395 `disabled={!dirty || segments.length === 0}`.
    var canApply: Bool { dirty && lineSegmentCount > 0 }

    /// StatuslineDialog.tsx:165 `available` — segments not already in the line.
    var availableSegments: [SLSegmentSpec] {
        guard let meta else { return [] }
        let inLine = Set((draft?.segments ?? []).map(\.id))
        return meta.segments.filter { !inLine.contains($0.id) }
    }

    func specFor(_ id: String) -> SLSegmentSpec? {
        meta?.segments.first { $0.id == id }
    }

    // MARK: - presets as a derived fact (U1)

    /// The preset whose segment list the draft matches exactly, with no
    /// option set anywhere — or nil. `draft.preset` records what the user
    /// PICKED (and the detach rule clears it on any edit); this derives
    /// what the line IS, so re-building a preset by hand re-lights its
    /// chip and the picker can never show a preset the line is not.
    static func presetMatching(_ cfg: StatuslineConfig, presets: [SLPreset]) -> String? {
        guard cfg.segments.allSatisfy({ ($0.options ?? [:]).isEmpty }) else { return nil }
        let ids = cfg.segments.map(\.id)
        return presets.first { $0.config.segments.map(\.id) == ids }?.id
    }

    /// What the segmented control highlights: a preset id, or "" = Custom.
    /// Derived ONLY from the line — a loaded file's `preset` field may
    /// disagree with its hand-edited segments, and the control must never
    /// light a preset the line is not.
    var selectedPresetID: String {
        guard let draft else { return "" }
        return Self.presetMatching(draft, presets: meta?.presets ?? []) ?? ""
    }

    // MARK: - per-segment chip bytes (U1)

    static func segmentPreviewKey(id: String, options: [String: JSONValue]?) -> String {
        guard let options, !options.isEmpty else { return id }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(options)) ?? Data()
        return id + "|" + (String(data: data, encoding: .utf8) ?? "")
    }

    /// The bytes a chip shows: the segment as the renderer prints it with
    /// THESE options (the line's chips) or its defaults (the tray's). nil
    /// until the daemon has answered for that key.
    func segmentPreview(id: String, options: [String: JSONValue]?) -> SegmentBytes? {
        segmentPreviews[Self.segmentPreviewKey(id: id, options: options)]
    }

    /// One request per key not yet cached: the line's segments with their
    /// options plus every registry segment with defaults (the tray).
    private func refreshSegmentPreviews() {
        guard let meta else { return }
        var wanted: [(key: String, cfg: StatuslineConfig)] = []
        var seen = Set<String>()
        func want(_ id: String, _ options: [String: JSONValue]?) {
            let key = Self.segmentPreviewKey(id: id, options: options)
            guard id != Self.newlineID, !seen.contains(key), segmentPreviews[key] == nil else { return }
            seen.insert(key)
            // The draft's colour mode rides along so a colour-off line gets
            // colour-off chips; flex off so a chip never collapses itself.
            wanted.append((key, StatuslineConfig(version: 1, preset: nil, separator: nil, flex: "off", color: draft?.color, keep: nil,
                                                 segments: [SLSegmentConfig(id: id, options: options)])))
        }
        for sc in draft?.segments ?? [] { want(sc.id, sc.options) }
        for spec in meta.segments { want(spec.id, nil) }
        guard !wanted.isEmpty else { return }
        segmentPreviewTask?.cancel()
        segmentPreviewTask = Task { [weak self] in
            for item in wanted {
                guard !Task.isCancelled, let self else { return }
                guard let json = try? Self.encode(item.cfg),
                      let resp = try? await self.api.statuslineSegmentPreview(config: json) else { continue }
                self.segmentPreviews[item.key] = SegmentBytes(line: resp.line, plain: resp.plain)
            }
        }
    }

    func optionValue(segmentID: String, key: String) -> JSONValue? {
        draft?.segments.first { $0.id == segmentID }?.options?[key]
    }

    // MARK: - load (fetch-on-open)

    /// Fetches segments meta + config concurrently. A load_error on a
    /// clean fetch means the file itself is unreadable (defaults shown,
    /// StatuslineDialog.tsx:137); a fetch failure means the daemon itself
    /// is unreachable (StatuslineDialog.tsx:139) — two distinct messages,
    /// never conflated.
    func load() async {
        applied = false
        // Chip bytes are live data (percentages, countdowns); an editor
        // reopened an hour later must not show last hour's numbers under a
        // fresh full-line preview (review 2026-10-03 P1).
        segmentPreviews = [:]
        segmentPreviewTask?.cancel()
        // Same for the width caption: the terminal may have been resized
        // since; say nothing until this open's render lands.
        previewWidthLanded = false
        do {
            async let metaResult = api.statuslineSegments()
            async let configResult = api.statuslineConfig()
            let (m, c) = try await (metaResult, configResult)
            meta = m
            saved = c.config
            draft = c.config
            let loadErr = c.loadError ?? ""
            err = loadErr.isEmpty ? nil : StatuslineEditorCopy.unreadable(loadErr)
            schedulePreview()
        } catch {
            err = StatuslineEditorCopy.unreachable
        }
    }

    // MARK: - segment list mutations (the preset-detach rule)

    /// StatuslineDialog.tsx `move` (lines 168-175): reorder clears `preset`.
    func move(from: Int, to: Int) {
        patch { c in
            guard to >= 0, to < c.segments.count else { return c }
            var c = c
            var segs = c.segments
            let row = segs.remove(at: from)
            segs.insert(row, at: to)
            c.segments = segs
            c.preset = ""
            return c
        }
    }

    /// Native `List.onMove` — only ever a single-item drag in this editor.
    func onMove(from source: IndexSet, to destination: Int) {
        guard source.count == 1 else { return }
        patch { c in
            var c = c
            c.segments.move(fromOffsets: source, toOffset: destination)
            c.preset = ""
            return c
        }
    }

    /// StatuslineDialog.tsx:376-382 `+ segment` chip. `at` = drop index
    /// (U1 drag from the tray); nil appends.
    func addSegment(_ id: String, at index: Int? = nil) {
        guard isKnownSegment(id) else { return }
        patch { c in
            var c = c
            guard !c.segments.contains(where: { $0.id == id }) else { return c }
            c.preset = ""
            let at = min(max(index ?? c.segments.count, 0), c.segments.count)
            c.segments.insert(SLSegmentConfig(id: id, options: nil), at: at)
            return c
        }
    }

    /// The line accepts plain-text drops, and plain text can come from
    /// anywhere (a Safari selection, the popover's own text field). Only a
    /// registry id is a segment; until the registry has loaded nothing is.
    func isKnownSegment(_ id: String) -> Bool {
        meta?.segments.contains { $0.id == id } == true
    }

    /// U1 drag within the line: move segment `id` so it lands BEFORE the
    /// segment currently at `index` (index == count appends).
    func moveSegment(_ id: String, before index: Int) {
        patch { c in
            guard let from = c.segments.firstIndex(where: { $0.id == id }) else { return c }
            var c = c
            var segs = c.segments
            let row = segs.remove(at: from)
            // `index` counts positions in the line BEFORE the removal, so
            // everything past `from` has shifted down by one; adjust, then
            // clamp into the shorter array.
            let shifted = index > from ? index - 1 : index
            segs.insert(row, at: min(max(shifted, 0), segs.count))
            guard segs != c.segments else { return c }
            c.segments = segs
            c.preset = ""
            return c
        }
    }

    /// StatuslineDialog.tsx:342-348 `✕` remove.
    func removeSegment(_ id: String) {
        patch { c in
            var c = c
            c.preset = ""
            c.segments.removeAll { $0.id == id }
            return c
        }
    }

    /// StatuslineDialog.tsx:307-319 option onChange: a `nil` value DELETES
    /// the key (empty string never stored; color "clear" removes the key).
    func setOption(segmentID: String, key: String, value: JSONValue?) {
        patch { c in
            var c = c
            c.preset = ""
            // A tray chip's option edit ADDS the segment carrying it — the
            // picked design does the same; before, the control snapped
            // back and the draft was marked dirty for a change nobody could
            // see (review 2026-10-03 P1).
            if !c.segments.contains(where: { $0.id == segmentID }), isKnownSegment(segmentID) {
                c.segments.append(SLSegmentConfig(id: segmentID, options: nil))
            }
            c.segments = c.segments.map { row in
                guard row.id == segmentID else { return row }
                var row = row
                var options = row.options ?? [:]
                if let value {
                    options[key] = value
                } else {
                    options.removeValue(forKey: key)
                }
                row.options = options.isEmpty ? nil : options
                return row
            }
            return c
        }
    }

    // MARK: - presets (StatuslineDialog.tsx:256-261)

    /// Selecting a preset swaps the segment composition but PRESERVES
    /// `draft.keep` — the coexist setting is orthogonal to which segments
    /// are on the line.
    func selectPreset(_ preset: SLPreset) {
        applied = false
        var cfg = preset.config
        cfg.preset = preset.id
        cfg.keep = draft?.keep
        draft = cfg
        schedulePreview()
    }

    // MARK: - kept statusline (StatuslineDialog.tsx:236-250)

    /// Removing the kept-statusline chip does NOT clear `preset` — unlike
    /// every other mutation above, this is orthogonal to segment composition.
    func clearKeep() {
        patch { c in
            var c = c
            c.keep = nil
            return c
        }
    }

    // MARK: - apply / discard (StatuslineDialog.tsx:177-188, 400-404)

    func apply() {
        guard let draft else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.putStatuslineConfig(draft)
                self.saved = draft
                self.applied = true
                self.err = nil
            } catch {
                self.applied = false
                self.err = self.errorMessage(error, fallback: StatuslineEditorCopy.saveFailed)
            }
        }
    }

    func discard() {
        draft = saved
        applied = false
        schedulePreview()
    }

    // MARK: - live preview (debounced, real renderer)

    private func patch(_ fn: (StatuslineConfig) -> StatuslineConfig) {
        guard let draft else { return }
        applied = false
        self.draft = fn(draft)
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let draft else { return }
        let delay = max(previewDebounceDelay, 0)
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runPreview(draft)
        }
    }

    private func runPreview(_ draft: StatuslineConfig) async {
        // An empty line is a valid editing state the daemon refuses to
        // render (400) — show it empty instead of the previous line.
        guard draft.segments.contains(where: { $0.id != Self.newlineID }) else {
            preview = ""
            clearPreviewError()
            refreshSegmentPreviews()
            return
        }
        do {
            let cfgJSON = try Self.encode(draft)
            // width nil = auto: the daemon answers at the columns Claude Code
            // last gave the statusline, so the preview is YOUR terminal's.
            let resp = try await api.statuslinePreview(width: nil, tier: "truecolor", config: cfgJSON)
            guard !Task.isCancelled else { return }
            preview = resp.line
            previewRenderedColumns = resp.width > 0 ? resp.width : 120
            previewWidthIsReal = resp.widthSource == "claude-code"
            previewWidthLanded = true
            clearPreviewError()
            refreshSegmentPreviews()
        } catch is CancellationError {
            // teardown/superseded — never surfaces as an error
        } catch {
            let msg = errorMessage(error, fallback: StatuslineEditorCopy.previewFailed)
            lastPreviewError = msg
            err = msg
        }
    }

    private func clearPreviewError() {
        if let last = lastPreviewError, err == last { err = nil }
        lastPreviewError = nil
    }

    private func errorMessage(_ error: Error, fallback: String) -> String {
        let msg = error.localizedDescription
        return msg.isEmpty ? fallback : msg
    }

    /// Serializes the draft with the SAME field spelling the daemon accepts
    /// — StatuslineConfig's CodingKeys already mirror
    /// internal/statusline.Config's json tags 1:1 (version/preset/separator/
    /// flex/color/keep/segments), so a plain JSONEncoder round-trips clean.
    private static func encode(_ cfg: StatuslineConfig) throws -> String {
        let data = try JSONEncoder().encode(cfg)
        guard let str = String(data: data, encoding: .utf8) else {
            throw StatuslineEditorError.encodingFailed
        }
        return str
    }
}
