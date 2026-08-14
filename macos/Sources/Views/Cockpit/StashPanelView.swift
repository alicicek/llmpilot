import SwiftUI

// Native port of web/src/shell/StashPanel.tsx — a swap preserved sign-ins it
// could not attribute to any registered account. Each entry has exactly two
// ways out: adopt it into the fleet, or discard it (deletes the stored
// credential). A dead entry (the token endpoint rejected its lineage) cannot
// be adopted: only a fresh sign-in recovers that account, so the button says
// so instead of failing (StashPanel.tsx:4-8).

/// Copy pinned verbatim against StashPanel.tsx so a future edit to either
/// side is a one-line diff, not a silent drift.
enum StashCopy {
    static let header = "Kept sign-ins from switching"
    static let body =
        "A switch found these signed in but not in your fleet, so it kept them — " +
        "add one to watch it here, or discard it to delete its stored credential."
    static let unknownAccount = "unknown account"
    static let keptPrefix = "kept "
    static let deadExpiry = "sign-in expired — log in to this account again to use it"
    static var deadSuffix: String { " · " + deadExpiry }
    static let addAccount = "Add account"
    static let adding = "Adding…"
    static let discard = "Discard sign-in"
    static let confirmDiscard = "Delete for good?"
}

/// Drives the native Stash panel: adopt/discard busy+error state and the
/// two-click discard confirm. Mirrors StashPanel.tsx's `useState` trio
/// (lines 10-14) and its `run` helper (lines 18-24).
@MainActor
final class StashPanelModel: ObservableObject {
    @Published private(set) var busy: String?
    @Published var err: String?
    @Published private(set) var confirmDiscard: String?

    private let api: CockpitDaemonAPI & DaemonAPI
    private var confirmResetTask: Task<Void, Never>?

    /// Production auto-revert for the pending confirm. The web reverts on
    /// `onBlur` (StashPanel.tsx:78) — a SwiftUI `Button` has no reliable
    /// cross-input-method blur callback, so a short timeout is the native
    /// equivalent of "the user moved on without confirming".
    var confirmResetDelay: TimeInterval = 3

    init(api: CockpitDaemonAPI & DaemonAPI) {
        self.api = api
    }

    /// Model-level predicate mirroring StashPanel.tsx:61
    /// `disabled={busy !== null || e.dead === true}`.
    func canAdopt(_ entry: StashEntry) -> Bool {
        busy == nil && entry.dead != true
    }

    /// StashPanel.tsx:69 `disabled={busy !== null}` — ANY in-flight action
    /// blocks discard, not just this row's.
    func canDiscard() -> Bool {
        busy == nil
    }

    func adopt(_ entry: StashEntry) {
        guard canAdopt(entry) else { return }
        // StashPanel.tsx:63 calls `adoptStash(e.fingerprint)` — no label.
        run(entry.fingerprint) { [api] in
            _ = try await api.stashAdopt(fingerprint: entry.fingerprint, label: nil)
        }
    }

    /// The two-click confirm state machine (StashPanel.tsx:70-77): first
    /// click arms it, second click (while still armed for THIS fingerprint)
    /// fires the discard.
    func requestDiscard(_ entry: StashEntry) {
        guard canDiscard() else { return }
        if confirmDiscard == entry.fingerprint {
            confirmResetTask?.cancel()
            confirmDiscard = nil
            run(entry.fingerprint) { [api] in
                try await api.stashDiscard(fingerprint: entry.fingerprint)
            }
        } else {
            confirmDiscard = entry.fingerprint
            scheduleConfirmReset(for: entry.fingerprint)
        }
    }

    private func scheduleConfirmReset(for fingerprint: String) {
        confirmResetTask?.cancel()
        let delay = confirmResetDelay
        confirmResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resetConfirm(for: fingerprint)
        }
    }

    /// Reverts an armed confirm back to idle — the timeout above calls this
    /// in production; tests call it directly to exercise the same
    /// transition the web's `onBlur` drives.
    func resetConfirm(for fingerprint: String) {
        guard confirmDiscard == fingerprint else { return }
        confirmResetTask?.cancel()
        confirmDiscard = nil
    }

    private func run(_ fingerprint: String, _ action: @escaping () async throws -> Void) {
        busy = fingerprint
        err = nil
        Task {
            do {
                try await action()
            } catch {
                err = error.localizedDescription
            }
            busy = nil
        }
    }
}

struct StashPanelView: View {
    @ObservedObject var model: StashPanelModel
    let stash: [StashEntry]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        // JS `toLocaleString([], {hour:"2-digit", minute:"2-digit",
        // day:"2-digit", month:"2-digit", hour12:false})` — capital "HH" in
        // a localized template keeps the 24-hour cycle regardless of the
        // user's locale-preferred hour format, matching `hour12: false`.
        f.setLocalizedDateFormatFromTemplate("ddMMHHmm")
        return f
    }()

    var body: some View {
        if stash.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StashCopy.header)
                .font(.system(size: 12.5, weight: .bold))
            Text(StashCopy.body)
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.sec)
            VStack(spacing: 0) {
                ForEach(Array(stash.enumerated()), id: \.element.id) { idx, entry in
                    row(entry, index: idx)
                    if idx != stash.count - 1 {
                        Divider().overlay(CockpitTheme.hairSoft)
                    }
                }
            }
            if let err = model.err {
                CockpitWarnBox {
                    Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }
        }
        .padding(16)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ entry: StashEntry, index: Int) -> some View {
        let isDead = entry.dead == true
        let confirming = model.confirmDiscard == entry.fingerprint
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label?.isEmpty == false ? entry.label! : StashCopy.unknownAccount)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(keptLine(entry, dead: isDead))
                    .font(CockpitTheme.numeric(10.5))
                    .foregroundColor(CockpitTheme.ter)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                addAccountButton(entry, index: index, dead: isDead)
                discardButton(entry, index: index, confirming: confirming)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func addAccountButton(_ entry: StashEntry, index: Int, dead: Bool) -> some View {
        let disabled = !model.canAdopt(entry)
        let label = model.busy == entry.fingerprint ? StashCopy.adding : StashCopy.addAccount
        let button = Button(action: { model.adopt(entry) }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                // actionFill, not accTx (owner 2026-08-12): one blue for every
                        // primary action, and white-on-accTx fails contrast in dark mode.
                        .background(CockpitTheme.actionFill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
        // Positional, NOT the fingerprint: the fingerprint is derived from
        // credential material (SHA-256 of the refresh token) and an AX
        // identifier is readable by any process holding Accessibility
        // permission — no credential-derived value crosses that surface
        // (review 2026-08-08 P2-5).
        .accessibilityIdentifier("stash-adopt-\(index)")
        .accessibilityLabel(dead ? "\(label), \(StashCopy.deadExpiry)" : label)

        if dead {
            button.help(Text(StashCopy.deadExpiry))
        } else {
            button
        }
    }

    private func discardButton(_ entry: StashEntry, index: Int, confirming: Bool) -> some View {
        let label = confirming ? StashCopy.confirmDiscard : StashCopy.discard
        return Button(action: { model.requestDiscard(entry) }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(confirming ? CockpitTheme.warn : CockpitTheme.sec)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(model.canDiscard() ? 1 : 0.5)
        .disabled(!model.canDiscard())
        .accessibilityIdentifier("stash-discard-\(index)") // positional — see adopt above
        .accessibilityLabel(label)
    }

    private func keptLine(_ entry: StashEntry, dead: Bool) -> String {
        let date = Self.dateFormatter.string(from: entry.stashedAt)
        var s = "\(StashCopy.keptPrefix)\(date)"
        if dead { s += StashCopy.deadSuffix }
        return s
    }
}
