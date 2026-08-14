import XCTest

@testable import llmpilot

/// The login window's state machine, driven entirely against fakes — no real
/// webview, no browser, no daemon (Proof: W12 Swift leg).
@MainActor
final class LoginFlowModelTests: XCTestCase {
    private func makeModel(_ api: StubAPI) -> LoginFlowModel {
        LoginFlowModel(api: api)
    }

    private func callback(_ query: String) -> URL {
        URL(string: "https://platform.claude.com/oauth/code/callback?" + query)!
    }

    func testStartLoadsAuthorizeURL() async {
        let api = StubAPI()
        let model = makeModel(api)
        var loaded: [URL] = []
        model.loadInWeb = { loaded.append($0) }

        await model.start()

        XCTAssertEqual(api.startedLogins, 1)
        XCTAssertEqual(model.expectedState, "st-1")
        guard case .web(let url) = model.phase else {
            return XCTFail("phase = \(model.phase)")
        }
        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(loaded, [url])
    }

    func testStartFailureSurfacesHonestly() async {
        let api = StubAPI()
        api.startLoginResult = .failure(DaemonError.down)
        let model = makeModel(api)

        await model.start()

        guard case .failed(let msg) = model.phase else {
            return XCTFail("phase = \(model.phase)")
        }
        XCTAssertTrue(msg.contains("daemon"), msg)
    }

    func testCallbackInterceptedAndExchanged() async {
        let api = StubAPI()
        let model = makeModel(api)
        await model.start()

        // Non-callback navigations (the login page itself) load untouched.
        XCTAssertEqual(model.handleNavigation(URL(string: "https://claude.ai/login")!), .allow)

        let decision = model.handleNavigation(callback("code=the-code&state=st-1"))
        XCTAssertEqual(decision, .intercept)
        XCTAssertEqual(model.phase, .exchanging)
        await model.completePending()

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(api.completedLogins.count, 1)
        XCTAssertEqual(api.completedLogins.first?.code, "the-code")
        XCTAssertEqual(api.completedLogins.first?.state, "st-1")
    }

    func testCallbackStateMismatchRejectedBeforeExchange() async {
        let api = StubAPI()
        let model = makeModel(api)
        await model.start()

        let decision = model.handleNavigation(callback("code=c&state=forged"))
        XCTAssertEqual(decision, .intercept)
        guard case .failed = model.phase else {
            return XCTFail("phase = \(model.phase)")
        }
        await model.completePending()
        XCTAssertTrue(api.completedLogins.isEmpty, "exchange ran for a forged state")
    }

    func testCallbackErrorSurfacedWithoutExchange() async {
        let api = StubAPI()
        let model = makeModel(api)
        await model.start()

        XCTAssertEqual(model.handleNavigation(callback("error=access_denied&state=st-1")), .intercept)
        guard case .failed(let msg) = model.phase else {
            return XCTFail("phase = \(model.phase)")
        }
        XCTAssertTrue(msg.contains("access_denied"), msg)
        await model.completePending()
        XCTAssertTrue(api.completedLogins.isEmpty)
    }

    func testCallbackWithoutCodeFailsClosed() async {
        let api = StubAPI()
        let model = makeModel(api)
        await model.start()

        XCTAssertEqual(model.handleNavigation(callback("state=st-1")), .intercept)
        guard case .failed = model.phase else {
            return XCTFail("phase = \(model.phase)")
        }
        XCTAssertTrue(api.completedLogins.isEmpty)
    }

    func testIsCallbackPinsHttpsAndExactHost() {
        XCTAssertTrue(LoginFlowModel.isCallback(
            URL(string: "https://platform.claude.com/oauth/code/callback?code=c&state=s")!))
        // Plaintext downgrade, look-alike host, userinfo spoof, subdomain.
        XCTAssertFalse(LoginFlowModel.isCallback(
            URL(string: "http://platform.claude.com/oauth/code/callback?code=c&state=s")!))
        XCTAssertFalse(LoginFlowModel.isCallback(
            URL(string: "https://platform.claude.com.evil.com/oauth/code/callback?code=c")!))
        XCTAssertFalse(LoginFlowModel.isCallback(
            URL(string: "https://platform.claude.com@evil.com/oauth/code/callback?code=c")!))
        XCTAssertFalse(LoginFlowModel.isCallback(
            URL(string: "https://evil.platform.claude.com/oauth/code/callback?code=c")!))
    }

    func testBrowserFallbackAndPaste() async {
        let api = StubAPI()
        let model = makeModel(api)
        var opened: [URL] = []
        model.openExternal = { opened.append($0) }
        await model.start()

        model.openInBrowser()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(model.phase, .paste)

        model.pasteInput = "  pasted-code#st-1 \n"
        await model.submitPaste()

        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(api.completedLogins.first?.code, "pasted-code")
        XCTAssertEqual(api.completedLogins.first?.state, "st-1")
    }

    func testMalformedPasteRejectedWithoutExchange() async {
        let api = StubAPI()
        let model = makeModel(api)
        await model.start()
        model.openInBrowser()

        for bad in ["", "no-hash", "#leading", "trailing#"] {
            model.pasteInput = bad
            await model.submitPaste()
            XCTAssertEqual(model.phase, .paste, "paste \(bad) moved phase")
            XCTAssertNotNil(model.pasteError, "paste \(bad) produced no error")
        }
        XCTAssertTrue(api.completedLogins.isEmpty)
    }

    func testExchangeFailureSurfacesAndRetryRestarts() async {
        let api = StubAPI()
        api.completeLoginResult = .failure(
            DaemonError.http(400, "this sign-in attempt is unknown, expired, or already used — start the sign-in again"))
        let model = makeModel(api)
        await model.start()

        XCTAssertEqual(model.handleNavigation(callback("code=c&state=st-1")), .intercept)
        await model.completePending()
        guard case .failed(let msg) = model.phase else {
            return XCTFail("phase = \(model.phase)")
        }
        XCTAssertTrue(msg.contains("start the sign-in again"), msg)

        // Retry begins a FRESH attempt (new daemon state, new URL).
        await model.retry()
        XCTAssertEqual(api.startedLogins, 2)
        guard case .web = model.phase else {
            return XCTFail("phase after retry = \(model.phase)")
        }
    }

    func testDoneCallsOnFinishedOnce() async {
        let api = StubAPI()
        let model = makeModel(api)
        var finished = 0
        model.onFinished = { finished += 1 }
        await model.start()
        _ = model.handleNavigation(callback("code=c&state=st-1"))
        await model.completePending()
        // A second completePending (double delegate fire) must be a no-op.
        await model.completePending()
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(api.completedLogins.count, 1)
    }
}
