import XCTest
@testable import llmpilot

/// Model-level coverage for StatuslineEditorModel — the preset-detach rule,
/// dirty computation, option set/clear semantics, the debounced live
/// preview, the apply/discard state machine, and draft serialization
/// round-tripping. Mirrors the same fixture-through-JSON-decode discipline
/// as DoctorPanelModelTests.swift (the wire types carry custom decoders).
@MainActor
final class StatuslineEditorTests: XCTestCase {
    // MARK: - fixtures

    private enum Fixtures {
        static var segments: StatuslineSegmentsResponse {
            let json = """
            {
              "segments": [
                {"id":"account","name":"Account","desc":"which account","deps":["store"],"priority":90,"fleet":false,
                 "options":[{"key":"privacy","label":"Hide email","type":"bool","default":false}]},
                {"id":"usage","name":"Usage","desc":"runway buckets","deps":["store","stdin"],"priority":100,"fleet":false,
                 "options":[{"key":"mode","label":"Display","type":"enum","values":["percent","bar","time"],"default":"percent"}]},
                {"id":"text","name":"Text","desc":"a fixed label","deps":[],"priority":20,"fleet":false,
                 "options":[{"key":"text","label":"Text","type":"string"},{"key":"color","label":"Color","type":"color"}]}
              ],
              "presets": [
                {"id":"runway","name":"Runway","desc":"the classic line",
                 "config":{"version":1,"preset":"runway","flex":"off","segments":[{"id":"account"},{"id":"usage"}]}},
                {"id":"dev","name":"Dev","desc":"dev line",
                 "config":{"version":1,"preset":"dev","segments":[{"id":"account"},{"id":"text"}]}}
              ]
            }
            """
            return try! JSONDecoder().decode(StatuslineSegmentsResponse.self, from: Data(json.utf8))
        }

        static func config(loadError: String = "") -> StatuslineConfigResponse {
            let json = """
            {"config":{"version":1,"preset":"runway","flex":"off","segments":[{"id":"account"},{"id":"usage"}]},
             "load_error":"\(loadError)"}
            """
            return try! JSONDecoder().decode(StatuslineConfigResponse.self, from: Data(json.utf8))
        }

        static var preview: StatuslinePreviewResponse {
            StatuslinePreviewResponse(line: "preview-line", plain: "preview-line", width: 120, tier: "truecolor")
        }
    }

    /// A loaded model (segments + config fetched, no in-flight debounce
    /// left over) ready for mutation tests. Debounce delay is tiny so no
    /// test waits out a real 200ms.
    private func loadedModel(_ api: StubCockpitAPI) async -> StatuslineEditorModel {
        api.statuslineSegmentsResult = .success(Fixtures.segments)
        api.statuslineConfigResult = .success(Fixtures.config())
        api.statuslinePreviewResult = .success(Fixtures.preview)
        let model = StatuslineEditorModel(api: api)
        model.previewDebounceDelay = 0.005
        await model.load()
        try? await Task.sleep(nanoseconds: 30_000_000) // let the initial debounced preview settle
        return model
    }

    // MARK: - load / fetch-on-open

    func testLoadErrorDistinguishesUnreadableFromUnreachable() async {
        let api = StubCockpitAPI()
        api.statuslineSegmentsResult = .success(Fixtures.segments)
        api.statuslineConfigResult = .success(Fixtures.config(loadError: "unexpected EOF"))
        api.statuslinePreviewResult = .success(Fixtures.preview)
        let model = StatuslineEditorModel(api: api)
        await model.load()
        XCTAssertEqual(model.err, "statusline.json is unreadable — showing defaults. unexpected EOF")

        let api2 = StubCockpitAPI() // both results default to .failure(DaemonError.down)
        let model2 = StatuslineEditorModel(api: api2)
        await model2.load()
        XCTAssertEqual(model2.err, "Editor unreachable — daemon not running or too old.")
    }

    func testLoadSeedsSavedAndDraftIdentically() async {
        let model = await loadedModel(StubCockpitAPI())
        XCTAssertEqual(model.draft, model.saved)
        XCTAssertFalse(model.dirty)
    }

    // MARK: - preset-detach rule (StatuslineDialog.tsx move/add/remove/option clear `preset`)

    func testMoveClearsPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        XCTAssertEqual(model.draft?.preset, "runway")
        model.move(from: 0, to: 1)
        XCTAssertEqual(model.draft?.preset, "")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["usage", "account"])
    }

    func testMoveOutOfBoundsIsANoOpAndKeepsPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        model.move(from: 0, to: -1) // "up" from the top row
        XCTAssertEqual(model.draft?.preset, "runway", "an out-of-bounds move must not detach the preset")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "usage"])
    }

    func testAddSegmentClearsPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        model.addSegment("text")
        XCTAssertEqual(model.draft?.preset, "")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "usage", "text"])
    }

    func testRemoveSegmentClearsPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        model.removeSegment("usage")
        XCTAssertEqual(model.draft?.preset, "")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account"])
    }

    func testOptionEditClearsPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        model.setOption(segmentID: "account", key: "privacy", value: .bool(true))
        XCTAssertEqual(model.draft?.preset, "")
    }

    func testOnMoveDragClearsPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        model.onMove(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(model.draft?.preset, "")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["usage", "account"])
    }

    // MARK: - preset select preserves `keep`

    func testSelectingAPresetPreservesKeep() async {
        let model = await loadedModel(StubCockpitAPI())
        model.draft?.keep = SLKeepConfig(command: "~/bin/oldstatus")
        let devPreset = model.meta!.presets.first { $0.id == "dev" }!

        model.selectPreset(devPreset)

        XCTAssertEqual(model.draft?.preset, "dev")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "text"])
        XCTAssertEqual(model.draft?.keep?.command, "~/bin/oldstatus", "keep must survive a preset swap")
    }

    func testClearKeepDoesNotTouchPreset() async {
        let model = await loadedModel(StubCockpitAPI())
        model.draft?.keep = SLKeepConfig(command: "~/bin/oldstatus")
        XCTAssertEqual(model.draft?.preset, "runway")

        model.clearKeep()

        XCTAssertNil(model.draft?.keep)
        XCTAssertEqual(model.draft?.preset, "runway", "removing keep is orthogonal to segment composition")
    }

    // MARK: - dirty computation

    func testDirtyTracksDraftVsSavedEquality() async {
        let model = await loadedModel(StubCockpitAPI())
        XCTAssertFalse(model.dirty)
        model.addSegment("text")
        XCTAssertTrue(model.dirty)

        // Removing it again restores the SEGMENT shape but the preset stays
        // detached (move/add/remove always clears it) — the config is still
        // not byte-for-byte the saved one, so dirty correctly stays true.
        model.removeSegment("text")
        XCTAssertEqual(model.draft?.segments.map(\.id), model.saved?.segments.map(\.id))
        XCTAssertTrue(model.dirty, "a cleared preset keeps the draft dirty even once segments match again")

        model.discard()
        XCTAssertFalse(model.dirty, "discard is the only way back to a clean draft once preset detaches")
    }

    func testCanApplyRequiresDirtyAndNonEmptySegments() async {
        let model = await loadedModel(StubCockpitAPI())
        XCTAssertFalse(model.canApply, "not dirty yet")
        model.removeSegment("account")
        model.removeSegment("usage")
        XCTAssertTrue(model.draft!.segments.isEmpty)
        XCTAssertFalse(model.canApply, "dirty but empty must still block apply")
        model.addSegment("account")
        XCTAssertTrue(model.canApply)
    }

    // MARK: - option set/clear semantics

    func testStringOptionEmptyValueDeletesTheKey() async {
        let model = await loadedModel(StubCockpitAPI())
        model.addSegment("text")
        model.setOption(segmentID: "text", key: "text", value: .string("hello"))
        XCTAssertEqual(model.optionValue(segmentID: "text", key: "text")?.stringValue, "hello")

        // Empty input never stores "" — the caller passes nil, which deletes.
        model.setOption(segmentID: "text", key: "text", value: nil)
        XCTAssertNil(model.optionValue(segmentID: "text", key: "text"))
        let row = model.draft!.segments.first { $0.id == "text" }!
        XCTAssertNil(row.options?["text"], "the key itself must be gone, not present with an empty string")
    }

    func testColorOptionClearRemovesTheKey() async {
        let model = await loadedModel(StubCockpitAPI())
        model.addSegment("text")
        model.setOption(segmentID: "text", key: "color", value: .string("#ff0000"))
        XCTAssertEqual(model.optionValue(segmentID: "text", key: "color")?.stringValue, "#ff0000")

        model.setOption(segmentID: "text", key: "color", value: nil)
        XCTAssertNil(model.optionValue(segmentID: "text", key: "color"))
    }

    func testBoolOptionAlwaysSetsExplicitly() async {
        let model = await loadedModel(StubCockpitAPI())
        model.setOption(segmentID: "account", key: "privacy", value: .bool(true))
        XCTAssertEqual(model.optionValue(segmentID: "account", key: "privacy")?.boolValue, true)
        model.setOption(segmentID: "account", key: "privacy", value: .bool(false))
        XCTAssertEqual(model.optionValue(segmentID: "account", key: "privacy")?.boolValue, false)
    }

    // MARK: - debounced live preview

    func testDebounceFiresExactlyOnceAfterAQuietPeriod() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        let baseline = api.statuslinePreviewRequests.count
        XCTAssertEqual(baseline, 1, "load() schedules exactly one initial preview")

        // Three rapid mutations inside the debounce window — each cancels
        // and reschedules the pending preview task.
        model.setOption(segmentID: "account", key: "privacy", value: .bool(true))
        model.setOption(segmentID: "account", key: "privacy", value: .bool(false))
        model.setOption(segmentID: "account", key: "privacy", value: .bool(true))

        try? await Task.sleep(nanoseconds: 40_000_000) // < 50ms, well past the 5ms debounce
        XCTAssertEqual(
            api.statuslinePreviewRequests.count, baseline + 1,
            "rapid mutations must coalesce into exactly one preview call, not one per change")
        XCTAssertEqual(api.statuslinePreviewRequests.last?.width, 120)
        XCTAssertEqual(api.statuslinePreviewRequests.last?.tier, "truecolor")
    }

    func testPreviewRequestCarriesTheDraftAsJSON() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.addSegment("text")
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard let last = api.statuslinePreviewRequests.last, let cfgJSON = last.config else {
            XCTFail("no preview request recorded with a config payload")
            return
        }
        let decoded = try! JSONDecoder().decode(StatuslineConfig.self, from: Data(cfgJSON.utf8))
        XCTAssertEqual(decoded, model.draft)
    }

    // MARK: - apply / discard state machine

    func testApplySuccessSyncsSavedAndFlashesApplied() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.addSegment("text")
        XCTAssertTrue(model.dirty)

        api.putStatuslineConfigResult = .success(Fixtures.config())
        model.apply()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.saved, model.draft)
        XCTAssertTrue(model.applied)
        XCTAssertNil(model.err)
        XCTAssertEqual(api.putStatuslineConfigs.count, 1)
    }

    func testApplyFailureSurfacesSaveFailedAndStaysDirty() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.addSegment("text")
        let savedBefore = model.saved

        api.putStatuslineConfigResult = .failure(DaemonError.down)
        model.apply()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(model.dirty)
        XCTAssertEqual(model.saved, savedBefore, "a failed save must not move saved forward")
        XCTAssertFalse(model.applied)
        XCTAssertNotNil(model.err)
    }

    func testDiscardRevertsDraftToSaved() async {
        let model = await loadedModel(StubCockpitAPI())
        let savedBefore = model.saved
        model.addSegment("text")
        XCTAssertTrue(model.dirty)

        model.discard()

        XCTAssertEqual(model.draft, savedBefore)
        XCTAssertFalse(model.dirty)
        XCTAssertFalse(model.applied)
    }

    func testMutatingAfterApplyClearsTheAppliedFlash() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.addSegment("text")
        api.putStatuslineConfigResult = .success(Fixtures.config())
        model.apply()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(model.applied)

        model.removeSegment("text")
        XCTAssertFalse(model.applied, "any further edit must clear the applied flash")
    }

    // MARK: - draft serialization round-trips

    func testDraftRoundTripsThroughStatuslineConfigDecodeUnchanged() async {
        let model = await loadedModel(StubCockpitAPI())
        model.addSegment("text")
        model.setOption(segmentID: "text", key: "text", value: .string("hi"))
        model.setOption(segmentID: "text", key: "color", value: .string("#00ff00"))
        model.draft?.keep = SLKeepConfig(command: "~/bin/oldstatus")

        let data = try! JSONEncoder().encode(model.draft!)
        let decoded = try! JSONDecoder().decode(StatuslineConfig.self, from: data)

        XCTAssertEqual(decoded, model.draft)
    }
}
