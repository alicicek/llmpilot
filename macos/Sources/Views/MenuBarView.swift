import SwiftUI

/// The dropdown: fleet lanes with runway bars, one-click switch, autopilot
/// status, first-run adoption, honest degraded states. Thin client — every
/// fact here came from the daemon API.
struct MenuBarView: View {
    @ObservedObject var model: FleetViewModel
    // Closes the menu bar popover after an action opens a window — otherwise
    // the popover lingers over the cockpit it just launched.
    @Environment(\.dismiss) private var dismiss
    var checkForUpdates: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            if model.showUpsell {
                Divider()
                upsellRow
            }
            if let err = model.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.crit)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("error-line")
            }
            Divider()
            footer
        }
        .frame(width: 344)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status == .live ? Theme.ok : Theme.drained)
                .frame(width: 6, height: 6)
            Text(headerLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.status == .live ? (model.showUpsell ? "autopilot paused" : model.autopilotLine) : "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerLine: String {
        switch model.status {
        case .live: return "daemon live"
        case .starting: return "starting the daemon…"
        case .connecting: return "connecting…"
        case .down: return "daemon not running"
        }
    }

    /// Official builds always ship the engine, so an unlicensed state is an
    /// upsell — the row opens the cockpit, where onboarding and the paywall live.
    private var upsellRow: some View {
        Button {
            if let url = model.cockpitURL {
                CockpitWindowController.shared.open(url: url)
                dismiss()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 10))
                Text("Turn on the autopilot").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.borderless)
        .disabled(model.cockpitURL == nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("upsell")
    }

    @ViewBuilder private var content: some View {
        switch model.status {
        case .down:
            switch model.startGate {
            case .requiresApproval:
                approvalGate
            case .moveToApplications:
                moveGate
            case nil:
                daemonDown
            }
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("starting the daemon…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .accessibilityIdentifier("starting-line")
        case .connecting:
            Text("connecting to daemon…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
        case .live:
            if model.accounts.isEmpty {
                firstRun
            } else {
                fleet
            }
        }
    }

    private var approvalGate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS is holding the daemon's background item.")
                .font(.system(size: 12, weight: .semibold))
            Text("Allow llmpilot under Login Items & Extensions, then reopen this menu.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items settings") {
                model.loginItems.openLoginItemsSettings()
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var moveGate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move llmpilot to Applications, then reopen it.")
                .font(.system(size: 12, weight: .semibold))
            Text("macOS runs apps from a disk image or download in a temporary place; the daemon can't start from there.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var fleet: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stale = model.staleLabel {
                Text(stale)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            ForEach(model.accounts) { account in
                lane(account)
                if account.id != model.accounts.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
            if !model.stash.isEmpty {
                Divider().padding(.leading, 12)
                stashRows
            }
            if model.unadoptedDetectedCount > 0 {
                Divider().padding(.leading, 12)
                detectedRow
            }
        }
        .padding(.vertical, 4)
    }

    /// Other Claude Code sign-ins found on this Mac that aren't part of the
    /// fleet yet — glanceable only; the move into the fleet is cockpit-only.
    private var detectedRow: some View {
        let count = model.unadoptedDetectedCount
        return Text(count == 1
            ? "1 more Claude sign-in found on this Mac — add it in the cockpit."
            : "\(count) more Claude sign-ins found on this Mac — add them in the cockpit.")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityIdentifier("detected-count")
    }

    /// A swap preserved sign-ins it could not attribute — say so and point
    /// at the cockpit, where adopt/discard lives.
    private var stashRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.stash) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(entry.label?.isEmpty == false ? entry.label! : "unknown account")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text(entry.dead == true ? "sign-in expired" : "kept from a switch")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Text("Add or discard these in the cockpit.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("stash-rows")
    }

    private func lane(_ account: AccountState) -> some View {
        let active = model.isActive(account)
        // Drain the lane when the whole feed is stale OR the daemon marked
        // THIS account stale (its token expired; the bars are frozen truth).
        let drained = model.staleLabel != nil || account.stale == true
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(model.displayName(for: account))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if account.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("pinned — the autopilot never switches to this account")
                }
                Spacer()
                if active {
                    Text("active")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else if !account.pinned {
                    Button {
                        Task { await model.switchTo(account.id) }
                    } label: {
                        if model.switchingID == account.id {
                            Text("switching…").font(.system(size: 10.5))
                        } else {
                            Text("Switch").font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.switchingID != nil)
                    .accessibilityIdentifier("switch-\(account.label)")
                }
            }
            // A pinned account lives in its own config dir by design — the
            // engine never swaps it into the global slot. That is a feature
            // (a per-dir session kept fresh in place), never user error, so
            // say what the lane is for instead of offering a verb it can't
            // do.
            if account.pinned, !active {
                Text("Pinned to its own config dir — used there directly, not switched into.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if let note = account.tokenNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warn)
            }
            if let buckets = account.snapshot?.buckets, !buckets.isEmpty {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                    RunwayBar(bucket: bucket, now: model.now, drained: drained)
                }
            } else {
                Text("no usage data yet")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var daemonDown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daemon not running — nothing here is live.")
                .font(.system(size: 12, weight: .semibold))
            Text("The daemon polls your accounts and performs switches; without it this menu has no data.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start daemon") {
                Task { await model.ensureRunning() }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private var firstRun: some View {
        // The daemon also flags dirs whose account is already registered —
        // only unregistered ones get an Adopt row, so branch on those.
        let unregistered = model.detected.filter { !$0.registered }
        return VStack(alignment: .leading, spacing: 8) {
            Text("No accounts yet.")
                .font(.system(size: 12, weight: .semibold))
            if unregistered.isEmpty {
                Text("No logged-in Claude Code accounts found. Log in with `claude` first, then reopen this menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Found logged-in Claude Code accounts. Adding reads usage only — macOS asks to allow Keychain access once per account.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unregistered) { d in
                    HStack {
                        // Email + folder: the same account can be signed in
                        // from more than one config dir (kept sign-ins), and
                        // two identical bare emails are indistinguishable —
                        // the cockpit's adopt screen already shows the path.
                        VStack(alignment: .leading, spacing: 1) {
                            let dir = d.configDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                            Text(d.email.isEmpty ? dir : d.email)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            if !d.email.isEmpty {
                                // Middle truncation: config dirs differ at the
                                // TAIL, and tail-truncating them recreates the
                                // identical-rows defect this line exists to fix.
                                Text(dir)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button(model.adoptingDir == d.configDir ? "adding…" : "Add") {
                            Task { await model.adopt(d.configDir) }
                        }
                        .controlSize(.small)
                        .disabled(model.adoptingDir != nil)
                    }
                }
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if let url = model.cockpitURL {
                    CockpitWindowController.shared.open(url: url)
                    dismiss()
                }
            } label: {
                Label("Open cockpit", systemImage: "macwindow")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .disabled(model.cockpitURL == nil || model.status != .live)
            .keyboardShortcut("o")
            Button {
                LoginWindowController.shared.open()
                dismiss()
            } label: {
                Label("Add account", systemImage: "person.badge.plus")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .disabled(model.status != .live)
            .accessibilityIdentifier("add-account")
            Spacer()
            Menu {
                Picker("Menu bar icon", selection: Binding(
                    get: { model.iconMode },
                    set: { model.iconMode = $0 }
                )) {
                    ForEach(FleetViewModel.IconMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Toggle("Privacy mode — hide emails", isOn: $model.privacyMode)
                Toggle("Start llmpilot at login", isOn: Binding(
                    get: { model.startAtLogin },
                    set: { on in Task { await model.setStartAtLogin(on) } }
                ))
                Divider()
                Button("Check for updates…", action: checkForUpdates)
                Divider()
                Button("Quit llmpilot") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { model.refreshLoginItemState() }
    }
}
