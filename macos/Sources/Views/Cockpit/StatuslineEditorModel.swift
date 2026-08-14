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
        "Rendered by the daemon's real renderer, shown at 120 columns, full color. Your " +
        "terminal's own width and color depth apply there. Session fields (model, dir, cost) " +
        "show sample values here."
    static let renderingPlaceholder = "rendering…"

    static let emptyLine = "Empty line — add at least one segment below."
    static let yourLineHeader = "Your line — drag to reorder"
    static let addSegmentsHeader = "Add segments"

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
    @Published var err: String?
    @Published private(set) var applied = false

    private let api: CockpitDaemonAPI & DaemonAPI
    private var previewTask: Task<Void, Never>?

    /// Live preview debounce (StatuslineDialog.tsx:145 `setTimeout(…, 200)`).
    /// Injectable so tests never wait out a real 200ms.
    var previewDebounceDelay: TimeInterval = 0.2

    init(api: CockpitDaemonAPI & DaemonAPI) {
        self.api = api
    }

    // MARK: - derived state

    /// StatuslineDialog.tsx:166 `JSON.stringify(draft) !== JSON.stringify(saved)`.
    var dirty: Bool { draft != saved }

    /// StatuslineDialog.tsx:395 `disabled={!dirty || segments.length === 0}`.
    var canApply: Bool { dirty && !(draft?.segments.isEmpty ?? true) }

    /// StatuslineDialog.tsx:165 `available` — segments not already in the line.
    var availableSegments: [SLSegmentSpec] {
        guard let meta else { return [] }
        let inLine = Set((draft?.segments ?? []).map(\.id))
        return meta.segments.filter { !inLine.contains($0.id) }
    }

    func specFor(_ id: String) -> SLSegmentSpec? {
        meta?.segments.first { $0.id == id }
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

    /// StatuslineDialog.tsx:376-382 `+ segment` chip.
    func addSegment(_ id: String) {
        patch { c in
            var c = c
            c.preset = ""
            c.segments.append(SLSegmentConfig(id: id, options: nil))
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
        do {
            let cfgJSON = try Self.encode(draft)
            let resp = try await api.statuslinePreview(width: 120, tier: "truecolor", config: cfgJSON)
            guard !Task.isCancelled else { return }
            preview = resp.line
        } catch is CancellationError {
            // teardown/superseded — never surfaces as an error
        } catch {
            err = errorMessage(error, fallback: StatuslineEditorCopy.previewFailed)
        }
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
