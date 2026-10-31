import XCTest

// The start-race guard's fail case: the sheet closes while POST
// /v1/login/browser is in flight — phase must not park at .browserWait for a
// sign-in the user gave up on, and no poll may start.
@MainActor
final class AddAccountStartRaceTests: XCTestCase {
    func testCloseDuringStartNeverStartsPolling() async throws {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(try DaemonDates.decoder().decode(
            BrowserLoginStart.self, from: Data(#"{"attempt_id":"a1"}"#.utf8)))
        let model = AddAccountModel(api: api)
        var opened = 0
        model.openExternal = { _ in opened += 1 }

        model.browserSignIn()
        model.closed() // cancel lands before the task body's post-start guard

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(opened, 0, "llmpilot never opens a browser itself — Claude Code does")
        XCTAssertEqual(model.phase, .idle, "phase must not park at browserWait")
        XCTAssertTrue(api.browserLoginStatusRequests.isEmpty)
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

    /// Fire-and-forget async work (adopt/move/opened) is spawned from a
    /// synchronous entry point exactly like StashPanelModel — poll with
    /// small real waits (never over 50ms each) until it settles, mirroring
    /// StashLogicTests' precedent for the same pattern.
    private func waitUntil(_ condition: @autoclosure () -> Bool, tries: Int = 50) async {
        for _ in 0..<tries where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - copy

    func testCopy() {
        XCTAssertEqual(AddAccountCopy.signInButton, "Sign in with Claude")
        XCTAssertEqual(
            AddAccountCopy.waitBody,
            "Finish signing in in your browser. This updates on its own the moment you approve.")
        XCTAssertEqual(
            AddAccountCopy.doneMessage(outcome: "added", email: "b@example.dev"),
            "b@example.dev joined your fleet — switch to it any time.")
        XCTAssertEqual(
            AddAccountCopy.doneMessage(outcome: "updated", email: "b@example.dev"),
            "b@example.dev is signed in again.")
        XCTAssertEqual(
            AddAccountCopy.doneMessage(outcome: "active", email: "b@example.dev"),
            "b@example.dev is signed in — Claude Code is using it.")
        XCTAssertEqual(
            AddAccountCopy.doneMessage(outcome: nil, email: nil),
            "The account joined your fleet — switch to it any time.")
        XCTAssertEqual(AddAccountCopy.signInAgain, "Sign in again")
        XCTAssertEqual(
            AddAccountCopy.moveWarning("/Users/mira/.claude"),
            "The sign-in leaves /Users/mira/.claude — a terminal using that folder will need to sign in again.")
        XCTAssertEqual(AddAccountCopy.claudeCodeSetupURL.absoluteString, "https://code.claude.com/docs/en/setup")
    }

    func testDaemonClausesBecomeSentences() {
        XCTAssertEqual(AddAccountModel.sentence("the sign-in timed out — start it again"), "The sign-in timed out — start it again.")
        XCTAssertEqual(AddAccountModel.sentence("Already a sentence."), "Already a sentence.")
        XCTAssertEqual(AddAccountModel.sentence(""), "")
    }

    // MARK: - sign-in: start, poll, outcomes

    private func pollModel(_ api: StubCockpitAPI, clock: VirtualClock) -> AddAccountModel {
        let model = AddAccountModel(api: api)
        model.now = { clock.current }
        model.sleep = { await clock.advance($0) }
        model.openExternal = { _ in }
        return model
    }

    func testDoneShowsWhereTheAccountLandedAndAutoCloses() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-1"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "done", accountID: "acct-b", email: "b@example.dev", outcome: "added"))
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)
        var opened: [URL] = []
        model.openExternal = { opened.append($0) }
        var closes = 0
        model.onRequestClose = { closes += 1 }

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.doneMessage, "b@example.dev joined your fleet — switch to it any time.")
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(opened.isEmpty, "Claude Code opens the browser, never the app")
        XCTAssertEqual(api.startedLoginEmails, [nil])
        XCTAssertEqual(api.browserLoginStatusRequests, ["att-1"])
    }

    func testSignInAgainPassesTheEmail() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-1"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "done", outcome: "updated"))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn(email: "b@example.dev")

        XCTAssertEqual(api.startedLoginEmails, ["b@example.dev"])
    }

    func testFailedSurfacesServerErrorAsASentenceAndOffersTryAgain() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-2"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "failed", error: "the Claude Code sign-in ended without finishing: OAuth error: access_denied"))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, "The Claude Code sign-in ended without finishing: OAuth error: access_denied.")
        XCTAssertEqual(model.signInButtonTitle, AddAccountCopy.tryAgain)
    }

    func testFailedWithoutServerMessageUsesFallback() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-3"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "failed", error: ""))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertEqual(model.error, AddAccountCopy.signInFailedFallback)
    }

    func testPendingPicksUpTheManualLinkForTheNoBrowserPath() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-4"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "pending", manualURL: "https://claude.com/cai/oauth/authorize?code=true"))
        let model = AddAccountModel(api: api)
        model.sleep = { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        var opened: [URL] = []
        model.openExternal = { opened.append($0) }

        let task = Task { await model.runBrowserSignIn() }
        await waitUntil(model.manualURL != nil)
        XCTAssertEqual(model.phase, .browserWait)
        model.openSignInPage()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://claude.com/cai/oauth/authorize?code=true"])
        task.cancel()
    }

    func testPastedCodeGoesToTheRunningAttempt() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-5"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "pending"))
        let model = AddAccountModel(api: api)
        model.sleep = { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        let task = Task { await model.runBrowserSignIn() }
        await waitUntil(model.phase == .browserWait)

        model.pasteInput = "  abcdefgh#statestate \n"
        await model.submitPastedCode()

        XCTAssertEqual(api.submittedLoginCodes.map(\.attempt), ["att-5"])
        XCTAssertEqual(api.submittedLoginCodes.map(\.code), ["abcdefgh#statestate"])
        XCTAssertTrue(model.pasteBusy, "busy until the poll reports the outcome")
        task.cancel()
    }

    func testRejectedCodeSaysSoAndAllowsAnotherTry() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-6"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "pending"))
        api.submitLoginCodeResult = .failure(ApiError(
            status: 400, code: nil, message: "that doesn't look like the code from the sign-in page — copy it again"))
        let model = AddAccountModel(api: api)
        model.sleep = { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        let task = Task { await model.runBrowserSignIn() }
        await waitUntil(model.phase == .browserWait)

        model.pasteInput = "nope"
        await model.submitPastedCode()

        XCTAssertFalse(model.pasteBusy)
        XCTAssertEqual(model.pasteError, "That doesn't look like the code from the sign-in page — copy it again.")
        XCTAssertEqual(model.phase, .browserWait)
        task.cancel()
    }

    func testEmptyPasteSendsNothing() async {
        let api = StubCockpitAPI()
        let model = AddAccountModel(api: api)
        model.pasteInput = "   "
        await model.submitPastedCode()
        XCTAssertTrue(api.submittedLoginCodes.isEmpty)
    }

    func testClaudeCodeMissingOffersTheInstallPage() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .failure(ApiError(
            status: 409, code: "claude_missing", message: "server text"))
        let model = pollModel(api, clock: VirtualClock())
        var opened: [URL] = []
        model.openExternal = { opened.append($0) }

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.claudeMissing)
        XCTAssertEqual(model.error, AddAccountCopy.claudeMissing)
        XCTAssertTrue(api.browserLoginStatusRequests.isEmpty)
        model.openClaudeCodeSetup()
        XCTAssertEqual(opened, [AddAccountCopy.claudeCodeSetupURL])
    }

    func testDaemonDownOnStart() async {
        let api = StubCockpitAPI() // startBrowserLoginResult defaults to .down
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertEqual(model.error, AddAccountCopy.daemonDown)
        XCTAssertFalse(model.claudeMissing)
    }

    func testTransientPollErrorsAreSwallowedThenSelfTimesOut() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-8"))
        api.browserLoginStatusResult = .failure(DaemonError.down)
        let clock = VirtualClock()
        let model = pollModel(api, clock: clock)

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, AddAccountCopy.pollTimeout)
        XCTAssertGreaterThan(api.browserLoginStatusRequests.count, 100, "transient errors must not end the poll early")
        XCTAssertGreaterThanOrEqual(clock.current.timeIntervalSince1970, model.pollTimeout)
    }

    func testSignInAgainLandingOnAnotherAccountWarnsAndStaysOpen() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-11"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "done", email: "a@example.dev", outcome: "active", existing: "true"))
        let model = pollModel(api, clock: VirtualClock())
        var closes = 0
        model.onRequestClose = { closes += 1 }

        await model.runBrowserSignIn(email: "B@example.dev")

        XCTAssertTrue(model.doneIsWarning)
        XCTAssertEqual(model.doneMessage, AddAccountCopy.wrongAccount(landed: "a@example.dev", requested: "B@example.dev"))
        XCTAssertEqual(closes, 0, "a warning must stay on screen")

        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "pending"))
        model.signInAgainFromDone()
        await waitUntil(api.startedLoginEmails.count == 2)
        XCTAssertEqual(api.startedLoginEmails.last, "B@example.dev", "the retry asks for the same account")
        model.closed()
    }

    func testSignInAgainLandingOnTheSameAccountDifferentCaseIsSuccess() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-12"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "done", email: "b@example.dev", outcome: "updated", existing: "true"))
        let model = pollModel(api, clock: VirtualClock())
        var closes = 0
        model.onRequestClose = { closes += 1 }

        await model.runBrowserSignIn(email: "B@Example.dev")

        XCTAssertFalse(model.doneIsWarning)
        XCTAssertEqual(model.doneMessage, "b@example.dev is signed in again.")
        XCTAssertEqual(closes, 1)
    }

    func testAddLandingOnAnAccountAlreadyInTheFleetSaysSo() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-13"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "done", email: "a@example.dev", outcome: "active", existing: "true"))
        let model = pollModel(api, clock: VirtualClock())
        var closes = 0
        model.onRequestClose = { closes += 1 }

        await model.runBrowserSignIn()

        XCTAssertTrue(model.doneIsWarning)
        XCTAssertEqual(model.doneMessage, AddAccountCopy.alreadyInFleet("a@example.dev"))
        XCTAssertEqual(closes, 0)
    }

    func testFirstAccountOnAnEmptyClaudeCodeIsSuccess() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-14"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "done", email: "a@example.dev", outcome: "active", existing: ""))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertFalse(model.doneIsWarning)
        XCTAssertEqual(model.doneMessage, "a@example.dev is signed in — Claude Code is using it.")
    }

    func testDoneWithANoteStaysOpenToBeRead() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-16"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(
            status: "done", email: "c@example.dev", outcome: "added", existing: "",
            note: "Open Claude Code once on this Mac, then you can switch to this account."))
        let model = pollModel(api, clock: VirtualClock())
        var closes = 0
        model.onRequestClose = { closes += 1 }

        await model.runBrowserSignIn()

        XCTAssertFalse(model.doneIsWarning)
        XCTAssertEqual(model.doneNote, "Open Claude Code once on this Mac, then you can switch to this account.")
        XCTAssertEqual(closes, 0)
    }

    func testTryAgainAfterAFailedSignInAgainKeepsTheAccount() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-17"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "failed", error: "access denied"))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn(email: "b@example.dev")
        XCTAssertEqual(model.signInButtonTitle, AddAccountCopy.tryAgain)
        model.primarySignIn()
        await waitUntil(api.startedLoginEmails.count == 2)
        XCTAssertEqual(api.startedLoginEmails, ["b@example.dev", "b@example.dev"])

        // A fresh open is a plain Add account again.
        model.closed()
        await waitUntil(model.phase == .idle)
        model.primarySignIn()
        await waitUntil(api.startedLoginEmails.count == 3)
        XCTAssertEqual(api.startedLoginEmails.last, .some(nil))
        model.closed()
    }

    func testDaemonRestartEndsTheWaitAtOnce() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-15"))
        api.browserLoginStatusResult = .failure(DaemonError.http(404, "this sign-in is unknown or already finished — start it again"))
        let model = pollModel(api, clock: VirtualClock())

        await model.runBrowserSignIn()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.error, AddAccountCopy.attemptGone)
        XCTAssertEqual(api.browserLoginStatusRequests.count, 1)
    }

    // MARK: - cancel / close

    func testCancelStopsPollingAndCancelsOnTheDaemon() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-9"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "pending"))
        let model = AddAccountModel(api: api)
        model.sleep = { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        model.browserSignIn()
        await waitUntil(model.phase == .browserWait)

        model.cancelBrowserWait()
        XCTAssertEqual(model.phase, .idle)
        await waitUntil(!api.cancelledLogins.isEmpty)
        XCTAssertEqual(api.cancelledLogins, ["att-9"])

        let seen = api.browserLoginStatusRequests.count
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertLessThanOrEqual(api.browserLoginStatusRequests.count, seen + 1)
    }

    func testClosingStopsWatchingButLeavesTheSignInRunning() async {
        let api = StubCockpitAPI()
        api.startBrowserLoginResult = .success(BrowserLoginStart(attemptID: "att-10"))
        api.browserLoginStatusResult = .success(BrowserLoginStatus(status: "pending"))
        let model = AddAccountModel(api: api)
        model.sleep = { _ in try? await Task.sleep(nanoseconds: 1_000_000) }
        model.browserSignIn()
        await waitUntil(model.phase == .browserWait)

        model.closed()

        XCTAssertEqual(model.phase, .idle)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(api.cancelledLogins.isEmpty,
                      "approving in the browser after closing the sheet must still add the account")
    }

    // MARK: - reset-on-close

    func testCloseClearsPhaseAndError() {
        let model = AddAccountModel(api: StubCockpitAPI())
        model.error = "some earlier error"
        model.closed()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.error)
    }
}
