import XCTest
@testable import llmpilot

/// History keeps every range it has loaded — in memory, and on disk across
/// relaunches — so opening it again shows the last cards at once instead of
/// a skeleton while the daemon is asked again.
@MainActor
final class AnalyticsCacheTests: XCTestCase {
    private func response(tokens: Int, asOf: String = "2026-11-01T12:00:00Z") -> AnalyticsResponse {
        let json = """
        {"cells":[{"account_id":"a","project":"p","model":"claude-opus-5","day":"2026-11-01","messages":1,
                   "tokens":{"input":\(tokens),"output":1,"cache_creation":0,"cache_read":0}}],
         "hour_weekday":[],"files_total":1,"files_parsed":1,"files_reused":0,
         "as_of":"\(asOf)","plan_cost_monthly":{"a":200}}
        """
        return try! DaemonDates.decoder().decode(AnalyticsResponse.self, from: Data(json.utf8))
    }

    private func tempCache() -> AnalyticsDiskCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AnalyticsDiskCache(url: dir.appendingPathComponent("history-analytics.json"))
    }

    /// A range seen before stays up when its refresh fails, and a range
    /// never seen leaves the shown cards marked as another range's.
    func testAKeptRangeStaysUpThroughAFailedRefresh() async {
        let api = StubCockpitAPI()
        api.analyticsResult = .success(response(tokens: 10))
        let model = CockpitViewModel(api: api)
        await model.loadAnalytics(days: 7)
        XCTAssertEqual(model.analyticsDays, 7)

        api.analyticsResult = .failure(DaemonError.down)
        await model.loadAnalytics(days: 7)
        XCTAssertEqual(model.analytics, response(tokens: 10))
        XCTAssertEqual(model.analyticsDays, 7)

        await model.loadAnalytics(days: 30)
        XCTAssertEqual(model.analyticsDays, 7, "30 days was never loaded: the cards are still 7 days'")

        // Back and forth between ranges: one seen before shows its own cards
        // at once, whatever the daemon says.
        api.analyticsResult = .success(response(tokens: 30))
        await model.loadAnalytics(days: 30)
        api.analyticsResult = .failure(DaemonError.down)
        await model.loadAnalytics(days: 7)
        XCTAssertEqual(model.analytics, response(tokens: 10))
        XCTAssertEqual(model.analyticsDays, 7)
    }

    /// A relaunch (a new model over the same file) shows the last cards
    /// before — and without — the daemon answering.
    func testARelaunchShowsTheLastCardsFromDisk() async {
        let cache = tempCache()
        let first = StubCockpitAPI()
        first.analyticsResult = .success(response(tokens: 42))
        await CockpitViewModel(api: first, analyticsCache: cache).loadAnalytics(days: 7)

        let down = StubCockpitAPI() // the daemon not answering yet
        let relaunched = CockpitViewModel(api: down, analyticsCache: cache)
        await relaunched.loadAnalytics(days: 7)
        XCTAssertEqual(relaunched.analytics, response(tokens: 42))
        XCTAssertEqual(relaunched.analyticsDays, 7)
    }

    func testTheDiskCopyRoundTrips() {
        let cache = tempCache()
        let kept = [7: response(tokens: 1), 30: response(tokens: 2, asOf: "2026-10-31T08:30:00.5Z")]
        cache.save(kept)
        XCTAssertEqual(cache.load(), kept)
        XCTAssertEqual(AnalyticsDiskCache(url: cache.url.appendingPathExtension("missing")).load(), [:])
    }
}
