import XCTest
@testable import llmpilot

@MainActor
final class StashLogicTests: XCTestCase {
    private func entry(fingerprint: String = "fp1", label: String? = "mira", dead: Bool? = nil) -> StashEntry {
        StashEntry(fingerprint: fingerprint, label: label, stashedAt: Date(), dead: dead)
    }

    // MARK: - copy strings, pinned against StashPanel.tsx

    func testCopyStringsMatchTheWebSource() {
        XCTAssertEqual(StashCopy.header, "Kept sign-ins from switching") // StashPanel.tsx:32
        XCTAssertEqual(
            StashCopy.body,
            "A switch found these signed in but not in your fleet, so it kept them — " +
                "add one to watch it here, or discard it to delete its stored credential.") // StashPanel.tsx:35-36
        XCTAssertEqual(StashCopy.unknownAccount, "unknown account") // StashPanel.tsx:46
        XCTAssertEqual(
            StashCopy.deadExpiry,
            "sign-in expired — log in to this account again to use it") // StashPanel.tsx:56,62
        XCTAssertEqual(StashCopy.deadSuffix, " · sign-in expired — log in to this account again to use it")
        XCTAssertEqual(StashCopy.addAccount, "Add account") // StashPanel.tsx:66
        XCTAssertEqual(StashCopy.adding, "Adding…") // StashPanel.tsx:66
        XCTAssertEqual(StashCopy.discard, "Discard sign-in") // StashPanel.tsx:81
        XCTAssertEqual(StashCopy.confirmDiscard, "Delete for good?") // StashPanel.tsx:81
    }

    // MARK: - adopt disabled for dead entries (model-level predicate)

    func testCanAdoptFalseWhenDead() {
        let model = StashPanelModel(api: StubCockpitAPI())
        XCTAssertFalse(model.canAdopt(entry(dead: true)))
    }

    func testCanAdoptTrueWhenAliveAndIdle() {
        let model = StashPanelModel(api: StubCockpitAPI())
        XCTAssertTrue(model.canAdopt(entry(dead: nil)))
        XCTAssertTrue(model.canAdopt(entry(dead: false)))
    }

    func testCanAdoptFalseWhileAnyActionIsBusy() {
        // StashPanel.tsx:61 `disabled={busy !== null || e.dead === true}` —
        // ANY in-flight action blocks adopt, not just this row's.
        let api = StubCockpitAPI()
        // Synchronous assertion below: `busy` is set before the async Task
        // spawned by `adopt` gets a chance to run, so the failure result
        // never has a chance to clear it within this test.
        api.stashAdoptResult = .failure(DaemonError.down)
        let model = StashPanelModel(api: api)
        let a = entry(fingerprint: "fp-a", dead: nil)
        let b = entry(fingerprint: "fp-b", dead: nil)
        model.adopt(a)
        XCTAssertFalse(model.canAdopt(b), "a busy adopt on another row must still block this one")
    }

    func testAdoptNeverCallsAPIForADeadEntry() {
        let api = StubCockpitAPI()
        let model = StashPanelModel(api: api)
        model.adopt(entry(dead: true))
        XCTAssertTrue(api.stashAdoptRequests.isEmpty, "a dead entry must never reach stashAdopt")
    }

    func testAdoptCallsStashAdoptWithNoLabel() async {
        // StashPanel.tsx:63 calls `adoptStash(e.fingerprint)` — no label arg.
        let api = StubCockpitAPI()
        api.stashAdoptResult = .failure(DaemonError.down)
        let model = StashPanelModel(api: api)
        model.adopt(entry(fingerprint: "fp1", label: "mira", dead: false))
        for _ in 0..<50 where model.busy != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(api.stashAdoptRequests.count, 1)
        XCTAssertEqual(api.stashAdoptRequests.first?.fingerprint, "fp1")
        XCTAssertNil(api.stashAdoptRequests.first?.label)
    }

    // MARK: - discard: two-click confirm state machine

    func testDiscardFirstClickArmsConfirmWithoutCallingAPI() {
        let api = StubCockpitAPI()
        let model = StashPanelModel(api: api)
        let e = entry(fingerprint: "fp1")
        model.requestDiscard(e)
        XCTAssertEqual(model.confirmDiscard, "fp1")
        XCTAssertTrue(api.stashDiscardRequests.isEmpty)
    }

    func testDiscardSecondClickOnSameFingerprintFires() async {
        let api = StubCockpitAPI()
        api.stashDiscardResult = .success(())
        let model = StashPanelModel(api: api)
        let e = entry(fingerprint: "fp1")
        model.requestDiscard(e)
        model.requestDiscard(e)
        XCTAssertNil(model.confirmDiscard, "a fired discard must clear the armed state")
        for _ in 0..<50 where model.busy != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(api.stashDiscardRequests, ["fp1"])
    }

    func testDiscardOnADifferentRowRearmsInsteadOfFiring() {
        let api = StubCockpitAPI()
        let model = StashPanelModel(api: api)
        let a = entry(fingerprint: "fp-a")
        let b = entry(fingerprint: "fp-b")
        model.requestDiscard(a)
        XCTAssertEqual(model.confirmDiscard, "fp-a")
        model.requestDiscard(b)
        XCTAssertEqual(model.confirmDiscard, "fp-b", "clicking a different row's discard arms THAT row, not a fire")
        XCTAssertTrue(api.stashDiscardRequests.isEmpty)
    }

    func testResetConfirmRevertsToIdle() {
        // The native analog of StashPanel.tsx:78's onBlur reset.
        let api = StubCockpitAPI()
        let model = StashPanelModel(api: api)
        let e = entry(fingerprint: "fp1")
        model.requestDiscard(e)
        XCTAssertEqual(model.confirmDiscard, "fp1")
        model.resetConfirm(for: "fp1")
        XCTAssertNil(model.confirmDiscard)
        // A reverted confirm means the next click arms again, it does not fire.
        model.requestDiscard(e)
        XCTAssertEqual(model.confirmDiscard, "fp1")
        XCTAssertTrue(api.stashDiscardRequests.isEmpty)
    }

    func testResetConfirmIsANoOpForAnUnarmedOrDifferentFingerprint() {
        let api = StubCockpitAPI()
        let model = StashPanelModel(api: api)
        model.resetConfirm(for: "nothing-armed")
        XCTAssertNil(model.confirmDiscard)

        model.requestDiscard(entry(fingerprint: "fp-a"))
        model.resetConfirm(for: "fp-b") // a different row's reset must not disarm fp-a
        XCTAssertEqual(model.confirmDiscard, "fp-a")
    }

    func testDiscardAutoRevertsAfterTheConfiguredDelay() async {
        let api = StubCockpitAPI()
        let model = StashPanelModel(api: api)
        model.confirmResetDelay = 0.02
        let e = entry(fingerprint: "fp1")
        model.requestDiscard(e)
        XCTAssertEqual(model.confirmDiscard, "fp1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(model.confirmDiscard, "the armed confirm must auto-revert like the web's blur reset")
        XCTAssertTrue(api.stashDiscardRequests.isEmpty, "a timed-out confirm must never fire the discard")
    }

    func testDiscardDisabledWhileAnyActionIsBusy() {
        let api = StubCockpitAPI()
        api.stashAdoptResult = .failure(DaemonError.down)
        let model = StashPanelModel(api: api)
        model.adopt(entry(fingerprint: "fp-a", dead: false))
        XCTAssertFalse(model.canDiscard())
    }
}
