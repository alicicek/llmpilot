import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Phase 4 chunk 4C — VIEW-WIRING tests for LicenseCardView.swift.
/// Cancel/recover/claim wire behavior is already pinned at the model layer
/// by ProAskMachineTests (LicenseAccountModel). These tests pin the layer
/// this chunk adds: `LicenseCardStatus.resolve` (status/copy/gating derived
/// from a `LicenseInfo?`), that the model's cancel/recover/claim calls the
/// stub API exactly as the card's actions would invoke them, and
/// crash-safety mounting for every status.
@MainActor
final class LicenseCardViewTests: XCTestCase {
    private func license(
        status: String, available: Bool = true, daysLeft: Int? = nil, chargeDate: Date? = nil,
        licenseIDMasked: String? = nil, errorCode: String? = nil
    ) -> LicenseInfo {
        var fields = [
            "\"available\":\(available)",
            "\"active\":false",
            "\"status\":\"\(status)\"",
            "\"nocard_trial_used\":false",
        ]
        if let daysLeft {
            var trial = "\"ends_at\":\"2026-08-10T00:00:00Z\",\"days_left\":\(daysLeft)"
            if let chargeDate {
                trial += ",\"charge_date\":\"\(ISO8601DateFormatter().string(from: chargeDate))\""
            }
            fields.append("\"trial\":{\(trial)}")
        }
        if let licenseIDMasked { fields.append("\"license_id_masked\":\"\(licenseIDMasked)\"") }
        if let errorCode { fields.append("\"error_code\":\"\(errorCode)\"") }
        let json = "{\(fields.joined(separator: ","))}"
        return try! DaemonDates.decoder().decode(LicenseInfo.self, from: Data(json.utf8))
    }

    // MARK: - LicenseCardStatus.resolve — LicenseSection.tsx:26-43,65-68

    func testNoLicenseFallsBackToNoneWhenOnline() {
        let s = LicenseCardStatus.resolve(license: nil, offline: false)
        XCTAssertEqual(s.status, "none")
        XCTAssertEqual(s.title, "Not active")
        XCTAssertTrue(s.showTurnOn)
        XCTAssertFalse(s.canCancel)
    }

    func testNoLicenseFallsBackToUnknownWhenOffline() {
        let s = LicenseCardStatus.resolve(license: nil, offline: true)
        XCTAssertEqual(s.status, "unknown")
        // "unknown" matches no known case — same "Not active" default copy.
        XCTAssertEqual(s.title, "Not active")
    }

    func testTrialingShowsDaysLeftAndCanCancel() {
        let l = license(status: "trialing", daysLeft: 3)
        let s = LicenseCardStatus.resolve(license: l, offline: false)
        XCTAssertEqual(s.title, "Free trial")
        XCTAssertTrue(s.hint.hasPrefix("3 days left"))
        XCTAssertTrue(s.canCancel)
        XCTAssertFalse(s.showTurnOn)
    }

    func testTrialingSingularDayWording() {
        let l = license(status: "trialing", daysLeft: 1)
        XCTAssertTrue(LicenseCardStatus.resolve(license: l, offline: false).hint.hasPrefix("1 day left"))
    }

    func testLifetimeNeverOffersCancelOrTurnOn() {
        let s = LicenseCardStatus.resolve(license: license(status: "lifetime"), offline: false)
        XCTAssertEqual(s.title, "Pro — lifetime")
        XCTAssertFalse(s.canCancel)
        XCTAssertFalse(s.showTurnOn)
    }

    func testLapsedAndRevokedOfferTurnOnNotCancel() {
        let lapsed = LicenseCardStatus.resolve(license: license(status: "lapsed"), offline: false)
        XCTAssertEqual(lapsed.title, "Paused")
        XCTAssertTrue(lapsed.showTurnOn)
        XCTAssertFalse(lapsed.canCancel)
        let revoked = LicenseCardStatus.resolve(license: license(status: "revoked"), offline: false)
        XCTAssertEqual(revoked.hint, "This purchase was refunded or disputed.")
        XCTAssertTrue(revoked.showTurnOn)
    }

    // MARK: - one-click cancel / recover / claim invoke the model
    // (LicenseAccountModel's own wire behavior is pinned by
    // ProAskMachineTests; these confirm the SAME model surface the card's
    // buttons call is what the card is built against.)

    func testCancelInvokesTheModelAndSurfacesReload() async {
        let api = StubCockpitAPI()
        api.licenseCancelResult = .success(LicenseCancelResult(status: "lapsed"))
        let model = LicenseAccountModel(api: api)
        var reloaded = 0
        model.onReload = { reloaded += 1 }

        await model.cancel()
        XCTAssertEqual(api.licenseCancelCalls, 1)
        XCTAssertEqual(reloaded, 1)
        XCTAssertNil(model.note)
    }

    func testRecoverInvokesTheModelWithUniformNoteCopy() async {
        let api = StubCockpitAPI()
        api.licenseRecoverResult = .success(())
        let model = LicenseAccountModel(api: api)

        await model.recover(email: "buyer@example.dev")
        XCTAssertEqual(api.licenseRecoverRequests, ["buyer@example.dev"])
        XCTAssertEqual(model.note, "If that email has a purchase, a recovery link is on its way. Open it on this Mac.")
    }

    func testClaimInvokesTheModelAndSurfacesRestoredNote() async {
        let api = StubCockpitAPI()
        api.licenseClaimResult = .success(LicenseClaimResult(status: "lifetime"))
        let model = LicenseAccountModel(api: api)
        var reloaded = 0
        model.onReload = { reloaded += 1 }

        await model.claim(token: "code123")
        XCTAssertEqual(api.licenseClaimRequests, ["code123"])
        XCTAssertEqual(model.note, "Restored — Pro is back on.")
        XCTAssertEqual(reloaded, 1)
    }

    // MARK: - reveal/copy (Phase 4 chunk 4E, gap ①) — LicenseSection.tsx:117-124

    func testRevealFetchesTheFullLicenseIDWithTheBearerToken() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "lifetime", licenseIDMasked: "••••ab12"))
        // The full id — LicenseAccountModel.reveal() is exercised against
        // whatever GET /v1/license?reveal=1 returns, independent of the
        // masked field on the ALREADY-held (unrevealed) license value.
        let model = LicenseAccountModel(api: api)

        await model.reveal()
        XCTAssertEqual(api.licenseRevealRequests, [true])
        XCTAssertNil(model.note)
    }

    func testRevealPrefersTheFullIDOverTheMaskedOne() async {
        let api = StubCockpitAPI()
        let full = try! DaemonDates.decoder().decode(
            LicenseInfo.self,
            from: Data(
                #"{"available":true,"active":true,"status":"lifetime","nocard_trial_used":false,"license_id":"lic_full_123","license_id_masked":"••••ab12"}"#
                    .utf8))
        api.licenseResult = .success(full)
        let model = LicenseAccountModel(api: api)

        await model.reveal()
        XCTAssertEqual(model.revealedID, "lic_full_123")
    }

    func testRevealFallsBackToTheMaskedIDWhenNoFullIDRides() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "lifetime", licenseIDMasked: "••••ab12"))
        let model = LicenseAccountModel(api: api)

        await model.reveal()
        XCTAssertEqual(model.revealedID, "••••ab12")
    }

    func testRevealFailureSurfacesTheUniformRemedyNote() async {
        let api = StubCockpitAPI()
        api.licenseResult = .failure(DaemonError.down)
        let model = LicenseAccountModel(api: api)

        await model.reveal()
        XCTAssertNil(model.revealedID)
        XCTAssertEqual(model.note, "Could not read the license id.")
    }

    // MARK: - hosting: mounting every status never crashes

    private func mount<V: View>(_ view: V) {
        let window = AXTestSupport.host(view)
        defer { window.orderOut(nil) }
        XCTAssertNotNil(window.contentView)
    }

    func testMountsEveryStatusWithoutCrashing() {
        let statuses = ["none", "trialing", "lifetime", "lapsed", "revoked"]
        for status in statuses {
            let model = LicenseAccountModel(api: StubCockpitAPI())
            mount(LicenseCardView(license: license(status: status, daysLeft: 4), model: model, onTurnOn: {}))
        }
        // No license at all (source build / offline fallback).
        mount(LicenseCardView(license: nil, offline: true, model: LicenseAccountModel(api: StubCockpitAPI()), onTurnOn: {}))
    }

    func testMountsUnavailableSourceBuildCardWithoutCrashing() {
        let model = LicenseAccountModel(api: StubCockpitAPI())
        mount(LicenseCardView(license: license(status: "none", available: false), model: model, onTurnOn: {}))
    }

    func testMountsWithMaskedLicenseIDAndErrorCodeWithoutCrashing() {
        let model = LicenseAccountModel(api: StubCockpitAPI())
        let l = license(status: "lifetime", licenseIDMasked: "••••ab12", errorCode: "seat_limit_reached")
        mount(LicenseCardView(license: l, model: model, onTurnOn: {}))
    }

    func testMountsWithARevealedLicenseIDWithoutCrashing() async {
        let api = StubCockpitAPI()
        api.licenseResult = .success(license(status: "lifetime", licenseIDMasked: "••••ab12"))
        let model = LicenseAccountModel(api: api)
        await model.reveal()
        XCTAssertNotNil(model.revealedID)
        let l = license(status: "lifetime", licenseIDMasked: "••••ab12")
        mount(LicenseCardView(license: l, model: model, onTurnOn: {}))
    }
}
