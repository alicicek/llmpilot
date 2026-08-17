import AVFoundation
import XCTest
@testable import llmpilot

/// F18 (audit 2026-08-16, root-caused 2026-08-17): the board's tick sounds
/// started an `AVAudioEngine` with NO nodes attached, and on macOS 26.5
/// `start()` on such an engine raises an Objective-C exception (not a Swift
/// error) — thrown from inside a SwiftUI gesture callback it left the
/// window's gesture environment un-reset and every later click dead. The
/// exception itself cannot be exercised in-process (an ObjC throw would take
/// the test runner down), so the guard under test is the PRECONDITION the
/// engine asserts: the output graph exists before `start()` is ever called.
final class BoardAudioTests: XCTestCase {
    /// The guard: `makeEngine()` returns an engine whose main mixer is
    /// already attached (and thereby connected to the output node) — the
    /// exact condition `AVAudioEngineGraph::Initialize` requires.
    func testMakeEngineBuildsOutputGraphBeforeStart() {
        let engine = BoardAudio.makeEngine()
        XCTAssertFalse(engine.isRunning, "makeEngine must not start the engine itself")
        XCTAssertTrue(engine.attachedNodes.contains(engine.mainMixerNode),
                      "the mixer must be attached before start() — an empty graph throws on macOS 26.5")
        XCTAssertEqual(engine.outputNode.numberOfInputs, 1)
    }

    /// The fail case the guard exists for: a bare `AVAudioEngine()` — the
    /// shape 1.3.0 shipped — has NO nodes attached, which is the state whose
    /// `start()` raises `required condition is false: inputNode != nullptr ||
    /// outputNode != nullptr`. Pinning it keeps a future "simplification"
    /// back to the bare engine from passing silently.
    func testBareEngineHasEmptyGraph() {
        let bare = AVAudioEngine()
        XCTAssertTrue(bare.attachedNodes.isEmpty, "a bare engine has no graph — starting it is the F18 throw")
    }

    /// End-to-end on a Mac with an output device: the graph-first engine
    /// starts cleanly. Skipped (not failed) where CoreAudio has no device
    /// to offer — the Swift error path is the one `ensureEngine` handles.
    func testGraphFirstEngineStarts() throws {
        let engine = BoardAudio.makeEngine()
        do {
            try engine.start()
        } catch {
            throw XCTSkip("no audio output device available: \(error)")
        }
        XCTAssertTrue(engine.isRunning)
        engine.stop()
    }
}
