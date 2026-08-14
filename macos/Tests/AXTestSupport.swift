import AppKit
import SwiftUI
import XCTest

@testable import llmpilot

/// Hosting helper for view-mount smoke tests (DoctorPanelHostingTests'
/// pattern: mount the REAL view in a real, offscreen window and assert an
/// observable effect — here, that construction/first layout never crashes
/// across every machine state a screen can render for).
///
/// NOT a full accessibility walker: an in-process `NSAccessibilityProtocol`
/// query (`accessibilityChildren()`/`accessibilityIdentifier()`) was tried
/// for this chunk and empirically does not surface descendants or
/// identifiers in this XCTest host — confirmed against BOTH a SwiftUI
/// `Button` and a plain `NSButton` with `setAccessibilityIdentifier(_:)`
/// called directly, so the gap is environmental (no trusted external AX
/// client attached), not SwiftUI-specific. This repo has no ViewInspector
/// dependency either, so button-press-driven assertions ("pressing X calls
/// Y") are out of reach for this chunk's tests; see the final report. The
/// screens' PURE decision logic (screen/dots selection, copy composition)
/// is instead factored out as static functions in PaywallViews.swift /
/// OnboardingFlowView.swift / LicenseCardView.swift and tested directly.
@MainActor
enum AXTestSupport {
    /// Hosts `view` in a real (offscreen) window and forces one layout
    /// pass. The caller is responsible for `window.orderOut(nil)` when done.
    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 700, height: 900)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return window
    }
}
