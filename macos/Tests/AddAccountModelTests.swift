import XCTest

// The start-race guard's fail case: the sheet closes while POST
// /v1/login/browser is in flight — a browser tab must NOT open for a
// sign-in the user gave up on, and phase must not park at .browserWait.
@MainActor
final class AddAccountStartRaceTests: XCTestCase {
    func testCloseDuringStartNeverOpensBrowser() async throws {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(try DaemonDates.decoder().decode(
            BrowserLoginStart.self,
            from: Data(#"{"authorize_url":"https://claude.ai/x","attempt_id":"a1"}"#.utf8)))
        let model = AddAccountModel(api: api)
        var opened = 0
        model.openExternal = { _ in opened += 1 }

        model.browserSignIn()
        model.closed() // cancel lands before the task body's post-start guard

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(opened, 0, "a cancelled start must never open a browser tab")
        XCTAssertEqual(model.phase, .idle, "phase must not park at browserWait")
    }
}
@testable import llmpilot

/// AddAccountModel — the native port of AddAccountDialog.tsx. Driven
/// entirely against StubCockpitAPI (no real daemon, no real webview) and,
/// for the poll loop, a virtual clock so the 2s-interval / 5-minute
/// self-timeout runs in microseconds, not real minutes.
@MainActor
final class AddAccountModelTests: XCTestCase {
    // A virtual clock: `advance` fast-forwards `now` with no real delay, so
    // 150 poll iterations (5 min / 2s) cost nothing in wall time.
    final class VirtualClock {
        private(set) var current = Date(timeIntervalSince1970: 0)
        func advance(_ seconds: TimeInterval) async {
            current = current.addingTimeInterval(seconds)
        }
    }

    private func detected(
        dir: String = "/tmp/dir", email: String = "mira@example.com",
        registered: Bool = false, moved: Bool = false, signedIn: Bool? = nil
    ) -> DetectedDir {
        DetectedDir(configDir: dir, email: email, registered: registered, moved: moved, signedIn: signedIn)
    }

    /// Fire-and-forget async work (adopt/move/opened) is spawned from a
    /// synchronous entry point exactly like StashPanelModel — poll with
    /// small real waits (never over 50ms each) until it settles, mirroring
    /// StashLogicTests' precedent for the same pattern.
    private func waitUntil(_ condition: @autoclosure () -> Bool, tries: Int = 50) async {
        for _ in 0..<tries where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - copy strings, pinned against AddAccountDialog.tsx

    func testCopyStringsMatchTheWebSource() {
        XCTAssertEqual(AddAccountCopy.intro, "Sign in with your Claude account and it joins the fleet — no terminal needed.")
        XCTAssertEqual(AddAccountCopy.browserButton, "Sign in with your browser (faster)")
        XCTAssertEqual(AddAccountCopy.windowButton, "Sign in in this window")
        XCTAssertEqual(
            AddAccountCopy.browserWaitBody,
            "Finish signing in in your browser — your password manager works there. This updates " +
                "on its own the moment you're done.")
        XCTAssertEqual(AddAccountCopy.done, "Signed in — the account is joining your fleet now.")
        XCTAssertEqual(AddAccountCopy.signInFailedFallback, "Sign-in failed — try again.")
        XCTAssertEqual(
            AddAccountCopy.pollTimeout,
            "Didn't detect a completed sign-in — finish it in your browser, or try again.")
        XCTAssertEqual(AddAccountCopy.moved, "Already moved into the fleet.")
        XCTAssertEqual(
            AddAccountCopy.registeredElsewhere,
            "A second folder for an account llmpilot already watches. One account means one " +
                "limit, so adding this folder would add no headroom.")
        // No CLI in the remedy (owner 2026-08-12): the row offers the
        // sheet's own sign-in as a button instead.
        XCTAssertEqual(
            AddAccountCopy.signedOut,
            "Signed out — this folder remembers the account, but its sign-in is gone.")
        XCTAssertEqual(AddAccountCopy.signInAgain, "Sign in again")
        XCTAssertEqual(
            AddAccountCopy.cloneSuspectFallback,
            "A second copy of this sign-in may still exist — llmpilot will not switch to it until that's resolved.")
        XCTAssertEqual(
            AddAccountCopy.moveWarning("/Users/mira/.claude"),
            "The sign-in leaves /Users/mira/.claude — a terminal using that folder will need to sign in again.")
    }

    // MARK: - detected-row classification table (AddAccountDialog.tsx:130-201)

    func testClassifyMovedWinsOverEverything() {
        let d = detected(registered: true, moved: true, signedIn: false)
        XCTAssertEqual(AddAccountModel.classify(d, fleetEmails: []), .moved)
    }

    func testClassifySignedOutAndWatchedElsewhereIsCaseFolded() {
        let d = detected(email: "Alex@Example.dev", registered: false, moved: false, signedIn: false)
        XCTAssertEqual(AddAccountModel.classify(d, fleetEmails: ["alex@example.dev"]), .registeredElsewhere)
    }

    func testClassifySignedOutAndNotWatchedAnywhere() {
        let d = detected(email: "new@example.com", registered: false, moved: false, signedIn: false)
        XCTAssertEqual(AddAccountModel.classify(d, fleetEmails: ["someone-else@example.com"]), .signedOut)
    }

    func testClassifyUnregisteredNormalRow() {
        let d = detected(registered: false, moved: false, signedIn: true)
        XCTAssertEqual(AddAccountModel.classify(d, fleetEmails: []), .unregistered)
    }

    func testClassifyRegisteredKeepsOnlyTheMigrationVerb() {
        let d = detected(registered: true, moved: false, signedIn: true)
        XCTAssertEqual(AddAccountModel.classify(d, fleetEmails: []), .registered)
    }

    func testClassifyAbsentSignedInFieldReadsAsSignedIn() {
        // Older daemons omit signed_in — absence must read as signed in,
        // the pre-existing behavior (AddAccountDialog.tsx / api.ts:96-100).
        let d = detected(registered: false, moved: false, signedIn: nil)
        XCTAssertEqual(AddAccountModel.classify(d, fleetEmails: []), .unregistered)
    }

    func testCandidatesExcludeTheFleetsOwnConfigDir() async {
        let api = StubCockpitAPI()
        api.detectResult = .success([
            detected(dir: "/fleet", email: "me@x.com"),
            detected(dir: "/other", email: "you@x.com"),
        ])
        let model = AddAccountModel(api: api, fleetDir: "/fleet")
        await model.refreshDetected()
        XCTAssertEqual(model.candidates.map(\.configDir), ["/other"])
    }

    func testDetectedSectionEmptyWhenNoCandidatesAndNoNotes() async {
        let api = StubCockpitAPI()
        api.detectResult = .success([])
        let model = AddAccountModel(api: api)
        await model.refreshDetected()
        XCTAssertTrue(model.isDetectedSectionEmpty)
    }

    // MARK: - adopt: single-flight across rows

    func testAdoptSetsRowBusySynchronouslyAndBlocksOtherRows() {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)

        model.adoptRow("/a")
        XCTAssertEqual(model.rowBusy, AddAccountModel.RowBusy(dir: "/a", action: .adopt))

        // A second row's action while busy is a no-op — AddAccountDialog.
        // tsx:168,176 `disabled={busy !== null}` blocks EVERY row, not just
        // this one.
        model.adoptRow("/b")
        XCTAssertEqual(model.rowBusy, AddAccountModel.RowBusy(dir: "/a", action: .adopt))
        model.requestMove("/c")
        XCTAssertNil(model.confirmMove, "move must not arm while another row's request is in flight")
    }

    func testAdoptSuccessRefreshesDetectedAndClearsBusy() async {
        let api = StubCockpitAPI()
        api.adoptResult = .success(())
        api.detectResult = .success([detected(dir: "/still-here")])
        let model = AddAccountModel(api: api)

        model.adoptRow("/a")
        await waitUntil(model.rowBusy == nil)

        XCTAssertEqual(api.adopted, ["/a"])
        XCTAssertNil(model.rowBusy)
        XCTAssertEqual(model.detected.map(\.configDir), ["/still-here"])
    }

    func testAdoptFailureSurfacesRowErrorAndClearsBusy() async {
        let api = StubCockpitAPI()
        api.adoptResult = .failure(DaemonError.down)
        let model = AddAccountModel(api: api)

        model.adoptRow("/a")
        await waitUntil(model.rowBusy == nil)

        XCTAssertNotNil(model.rowError)
        XCTAssertNil(model.rowBusy)
    }

    // MARK: - move: two-click confirm state machine, incl. disarm

    func testMoveFirstClickArmsConfirmWithoutCallingAPI() {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        model.requestMove("/a")
        XCTAssertEqual(model.confirmMove, "/a")
        XCTAssertTrue(api.adoptMoveRequests.isEmpty)
    }

    func testMoveSecondClickOnSameDirFires() async {
        let api = StubCockpitAPI()
        api.adoptMoveResult = .success(
            AdoptMoveResult(
                account: CockpitAccount(id: "1", label: "mira", email: "mira@x.com", configDir: "/a", keychainService: "svc", pinned: true),
                outcome: "complete", note: ""))
        let model = AddAccountModel(api: api)

        model.requestMove("/a")
        model.requestMove("/a")
        XCTAssertNil(model.confirmMove, "a fired move must clear the armed state")

        await waitUntil(model.rowBusy == nil)
        XCTAssertEqual(api.adoptMoveRequests.map(\.configDir), ["/a"])
    }

    func testMoveOnADifferentDirRearmsInsteadOfFiring() {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        model.requestMove("/a")
        XCTAssertEqual(model.confirmMove, "/a")
        model.requestMove("/b")
        XCTAssertEqual(model.confirmMove, "/b", "clicking a different row's move arms THAT row, not a fire")
        XCTAssertTrue(api.adoptMoveRequests.isEmpty)
    }

    func testResetMoveConfirmRevertsToIdle() {
        // The native analog of AddAccountDialog.tsx:184's onBlur reset.
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        model.requestMove("/a")
        XCTAssertEqual(model.confirmMove, "/a")
        model.resetMoveConfirm(for: "/a")
        XCTAssertNil(model.confirmMove)
        // A reverted confirm means the next click arms again, not a fire.
        model.requestMove("/a")
        XCTAssertEqual(model.confirmMove, "/a")
        XCTAssertTrue(api.adoptMoveRequests.isEmpty)
    }

    func testResetMoveConfirmIsANoOpForAnUnarmedOrDifferentDir() {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        model.resetMoveConfirm(for: "nothing-armed")
        XCTAssertNil(model.confirmMove)

        model.requestMove("/a")
        model.resetMoveConfirm(for: "/b")
        XCTAssertEqual(model.confirmMove, "/a", "a different row's reset must not disarm /a")
    }

    func testMoveConfirmAutoRevertsAfterTheConfiguredDelay() async {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        model.confirmResetDelay = 0.02 // 20ms — small real wait, like StashPanelModel's precedent
        model.requestMove("/a")
        XCTAssertEqual(model.confirmMove, "/a")
        await waitUntil(model.confirmMove == nil)
        XCTAssertNil(model.confirmMove, "the armed confirm must auto-revert")
        XCTAssertTrue(api.adoptMoveRequests.isEmpty, "a timed-out confirm must never fire the move")
    }

    // MARK: - outcome-note persistence and clearing

    func testCloneSuspectMoveLeavesAWarningNoteUsingServerText() async {
        let api = StubCockpitAPI()
        api.adoptMoveResult = .success(
            AdoptMoveResult(
                account: CockpitAccount(id: "1", label: "m", email: "m@x.com", configDir: "/a", keychainService: "s", pinned: true),
                outcome: "clone_suspect", note: "a second copy of this exact sign-in lives at /other too"))
        api.detectResult = .success([]) // the row itself vanishes after the move
        let model = AddAccountModel(api: api)

        model.requestMove("/a")
        model.requestMove("/a")
        await waitUntil(model.rowBusy == nil)

        XCTAssertEqual(model.moveNotes["/a"], "a second copy of this exact sign-in lives at /other too")
        XCTAssertTrue(model.candidates.isEmpty, "the row vanishes from the list")
        XCTAssertFalse(model.isDetectedSectionEmpty, "the section survives to show the note")
    }

    func testCloneSuspectMoveWithoutServerNoteUsesVerbatimFallback() async {
        let api = StubCockpitAPI()
        api.adoptMoveResult = .success(
            AdoptMoveResult(
                account: CockpitAccount(id: "1", label: "m", email: "m@x.com", configDir: "/a", keychainService: "s", pinned: true),
                outcome: "clone_suspect", note: ""))
        let model = AddAccountModel(api: api)

        model.requestMove("/a")
        model.requestMove("/a")
        await waitUntil(model.rowBusy == nil)

        XCTAssertEqual(model.moveNotes["/a"], AddAccountCopy.cloneSuspectFallback)
    }

    func testALaterCleanMoveOfTheSameDirClearsTheEarlierNote() async {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)

        // First: a clone-suspect move leaves a note.
        api.adoptMoveResult = .success(
            AdoptMoveResult(
                account: CockpitAccount(id: "1", label: "m", email: "m@x.com", configDir: "/a", keychainService: "s", pinned: true),
                outcome: "clone_suspect", note: "watch out"))
        model.requestMove("/a")
        model.requestMove("/a")
        await waitUntil(model.rowBusy == nil)
        XCTAssertEqual(model.moveNotes["/a"], "watch out")

        // A later clean move of the SAME dir resolves it.
        api.adoptMoveResult = .success(
            AdoptMoveResult(
                account: CockpitAccount(id: "1", label: "m", email: "m@x.com", configDir: "/a", keychainService: "s", pinned: true),
                outcome: "complete", note: ""))
        model.requestMove("/a")
        model.requestMove("/a")
        await waitUntil(model.moveNotes["/a"] == nil)

        XCTAssertNil(model.moveNotes["/a"], "a note that is no longer true must not linger")
    }

    // MARK: - browser poll loop: done / failed / transient-swallow / self-timeout

    private func pollModel(_ api: StubCockpitAPI, clock: VirtualClock) -> AddAccountModel {
        let model = AddAccountModel(api: api)
        model.now = { clock.current }
        model.sleep = { await clock.advance($0) }
        model.openExternal = { _ in }
        return model
    }

    func testPollDoneTransitionsAndAutoClosesAfterLinger() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://claude.example/auth", attemptID: "att-1"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "done", error: nil, accountID: "acc-1"))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)
        var opened: [URL] = []
        model.openExternal = { opened.append($0) }
        var closes = 0
        model.onRequestClose = { closes += 1 }

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://claude.example/auth"])
        XCTAssertEqual(api.startedBrowserLogins, 1)
        XCTAssertEqual(api.browserLoginStatusRequests, ["att-1"])
    }

    func testPollFailedSurfacesServerErrorAndReturnsToIdle() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-2"))
        api.browserLoginStatusResult = .success(
            BrowserLoginStatus(status: "failed", error: "Claude declined the sign-in — try again", accountID: nil))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, "Claude declined the sign-in — try again")
    }

    /// Found in review (both reviewers, confirmed): the REAL exchange
    /// 429 arrives via the STATUS poll — /v1/login/browser succeeds, the
    /// code exchange fails later, and the poll's "failed" carries
    /// code == "rate_limited". The sheet must offer Try again there, not
    /// only for a 429 on the start call.
    func testPollFailedWithRateLimitCodeOffersTryAgain() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-rl"))
        api.browserLoginStatusResult = .success(
            BrowserLoginStatus(
                status: "failed",
                error: "the sign-in server is rate-limited right now — wait a minute and try again",
                code: "rate_limited"))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.signInRateLimited, "an exchange 429 must arm the Try-again state")
        XCTAssertEqual(model.browserButtonTitle, AddAccountCopy.tryAgain)
    }

    /// FAIL CASE: a failed poll WITHOUT the rate-limited code (or with any
    /// other code) must not arm Try again — the flag keys off the stable
    /// code, never off the prose.
    func testPollFailedWithoutRateLimitCodeDoesNotOfferTryAgain() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-nrl"))
        api.browserLoginStatusResult = .success(
            BrowserLoginStatus(status: "failed", error: "rate-limited words in prose only", code: ""))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.signInRateLimited, "prose mentioning rate limits must not arm Try again without the code")
    }

    func testPollFailedWithoutServerMessageUsesVerbatimFallback() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-3"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "failed", error: "", accountID: nil))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, AddAccountCopy.signInFailedFallback)
    }

    func testTransientPollErrorsAreSwallowedThenSelfTimesOutAtFiveMinutes() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-4"))
        api.browserLoginStatusResult = .failure(DaemonError.down) // every poll "fails transiently"
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        // Exercise the REAL production constants, not shortened test values
        // — the self-timeout is deliberately shorter than the daemon's
        // 10-minute attempt TTL (internal/daemon/login.go loginAttemptTTL).
        XCTAssertEqual(model.pollInterval, 2)
        XCTAssertEqual(model.pollTimeout, 5 * 60)

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, AddAccountCopy.pollTimeout)
        // floor(300/2) = 150 ticks before the self-timeout fires, and no poll
        // fetch ever threw the error INTO `error` (it must be the timeout
        // copy, proving every failure really was swallowed).
        XCTAssertEqual(api.browserLoginStatusRequests.count, 150)
    }

    func testStartBrowserLoginFailureReturnsToIdleWithoutPolling() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .failure(DaemonError.http(500, "boom"))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, "boom")
        XCTAssertFalse(model.signInRateLimited, "a plain 500 is not the rate-limited case")
        XCTAssertEqual(model.browserButtonTitle, AddAccountCopy.browserButton, "an ordinary error keeps the default label")
        XCTAssertTrue(api.browserLoginStatusRequests.isEmpty)
    }

    // MARK: - F8 (2026-08-16 fresh-user audit): sign-in 429 states what
    // happened + the wait, and swaps the primary button to an explicit retry.

    func testStartBrowserLoginRateLimitedStatesWhatHappenedAndOffersRetry() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .failure(DaemonError.http(429, "rate limited"))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, AddAccountCopy.rateLimitedSignIn)
        XCTAssertTrue(model.signInRateLimited)
        XCTAssertEqual(model.browserButtonTitle, AddAccountCopy.tryAgain, "VOICE.md verb+object retry copy")
    }

    func testRateLimitedButtonTitleClearsOnceARetryStarts() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .failure(DaemonError.http(429, "rate limited"))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()
        XCTAssertEqual(model.browserButtonTitle, AddAccountCopy.tryAgain)

        // A fresh attempt (the "Try again" tap) clears the rate-limited
        // state up front — a successful retry behaves exactly as before.
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-8"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "done", error: nil, accountID: "acc-1"))
        model.openExternal = { _ in }

        await model.runBrowserSignIn()

        XCTAssertFalse(model.signInRateLimited)
        XCTAssertEqual(model.phase, .done)
    }

    func testPollFailedAfterAnEarlierRateLimitClearsTheRateLimitedFlag() async {
        // A start-call 429 followed by a genuinely different poll failure
        // must not leave the button stuck on "Try again".
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-9"))
        api.browserLoginStatusResult = .success(
            BrowserLoginStatus(status: "failed", error: "Claude declined the sign-in — try again", accountID: nil))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()

        XCTAssertFalse(model.signInRateLimited)
        XCTAssertEqual(model.browserButtonTitle, AddAccountCopy.browserButton)
    }

    // MARK: - poll cancellation on sheet close / Cancel

    func testClosingCancelsAnInFlightPollAndResetsToIdle() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-5"))
        api.browserLoginStatusResult = .failure(DaemonError.down) // never resolves — keeps polling
        let model = AddAccountModel(api: api)
        model.openExternal = { _ in }
        model.pollInterval = 0.01 // real, but each individual sleep stays well under 50ms

        model.browserSignIn()
        await waitUntil(!api.browserLoginStatusRequests.isEmpty)
        XCTAssertFalse(api.browserLoginStatusRequests.isEmpty, "the poll never started")
        let seenBeforeClose = api.browserLoginStatusRequests.count

        model.closed()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.error)
        try? await Task.sleep(nanoseconds: 40_000_000) // let any in-flight iteration finish
        XCTAssertLessThanOrEqual(
            api.browserLoginStatusRequests.count, seenBeforeClose + 1,
            "cancellation must stop the loop, not just reset the phase")
    }

    func testCancelBrowserWaitStopsPollingAndReturnsToIdle() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-6"))
        api.browserLoginStatusResult = .failure(DaemonError.down)
        let model = AddAccountModel(api: api)
        model.openExternal = { _ in }
        model.pollInterval = 0.01

        model.browserSignIn()
        await waitUntil(!api.browserLoginStatusRequests.isEmpty)
        let seenBeforeCancel = api.browserLoginStatusRequests.count

        model.cancelBrowserWait()

        XCTAssertEqual(model.phase, .idle)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertLessThanOrEqual(api.browserLoginStatusRequests.count, seenBeforeCancel + 1)
    }

    // MARK: - reset-on-close (full state, not just phase)

    func testCloseClearsPhaseErrorAndDetectedRowState() async {
        let api = StubCockpitAPI()
        api.adoptMoveResult = .success(
            AdoptMoveResult(
                account: CockpitAccount(id: "1", label: "m", email: "m@x.com", configDir: "/a", keychainService: "s", pinned: true),
                outcome: "clone_suspect", note: "watch out"))
        let model = AddAccountModel(api: api)
        model.error = "some earlier error"
        model.requestMove("/a") // arm the confirm
        model.requestMove("/a") // fire it
        await waitUntil(model.rowBusy == nil)
        XCTAssertEqual(model.moveNotes["/a"], "watch out")

        model.closed()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.error)
        XCTAssertNil(model.confirmMove)
        XCTAssertNil(model.rowBusy)
        XCTAssertNil(model.rowError)
        XCTAssertTrue(model.moveNotes.isEmpty, "a persistent native model must clear DetectedSection state on close the way the web's unmount does")
    }

    func testLeavingIdleForABrowserSignInClearsDetectedRowState() async {
        // AddAccountDialog.tsx renders DetectedSection only `phase === "idle"
        // && <DetectedSection/>` — leaving idle unmounts it, discarding its
        // local state, before any Cancel/close ever runs.
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(authorizeURL: "https://x", attemptID: "att-7"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "pending", error: nil, accountID: nil))
        let model = AddAccountModel(api: api)
        model.openExternal = { _ in }
        model.requestMove("/a")
        XCTAssertEqual(model.confirmMove, "/a")

        let task = Task { await model.runBrowserSignIn() }
        await waitUntil(model.phase != .idle)

        XCTAssertNil(model.confirmMove, "detected-row state must not survive leaving idle")
        task.cancel()
    }

    // MARK: - windowSignIn: always the bridge branch natively

    func testWindowSignInOpensLoginWindowAndClosesTheSheetSynchronously() {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        var openedWindow = 0
        var closedSheet = 0
        model.openLoginWindow = { openedWindow += 1 }
        model.onRequestClose = { closedSheet += 1 }

        model.windowSignIn()

        XCTAssertEqual(openedWindow, 1)
        XCTAssertEqual(closedSheet, 1)
        XCTAssertEqual(model.phase, .idle, "no phase change — this is a synchronous bridge hop, not a network flow")
    }

    // (The terminal-fallback copy-command test went with the CLI block
    // itself — owner 2026-08-12: the sheet never points users at the CLI.)

    // MARK: - opened() refreshes detected dirs

    func testOpenedRefreshesDetectedDirs() async {
        let api = StubCockpitAPI()
        api.detectResult = .success([detected(dir: "/fresh")])
        let model = AddAccountModel(api: api)

        model.opened()
        await waitUntil(!model.detected.isEmpty)

        XCTAssertEqual(model.detected.map(\.configDir), ["/fresh"])
    }
}
