import SwiftUI

/// The dropdown: fleet lanes with runway bars, one-click switch, autopilot
/// status, first-run adoption, honest degraded states. Thin client — every
/// fact here came from the daemon API.
struct MenuBarView: View {
    @ObservedObject var model: FleetViewModel
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
            Text(model.status == .live ? "daemon live" : "daemon not running")
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

    /// Official builds always ship the engine, so an unlicensed state is an
    /// upsell — the row opens the cockpit, where onboarding and the paywall live.
    private var upsellRow: some View {
        Button {
            if let url = model.cockpitURL {
                CockpitWindowController.shared.open(url: url)
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
            daemonDown
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
        }
        .padding(.vertical, 4)
    }

    private func lane(_ account: AccountState) -> some View {
        let active = model.isActive(account)
        let drained = model.staleLabel != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(model.displayName(for: account))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if account.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("pinned — excluded from rotation")
                }
                Spacer()
                if active {
                    Text("active")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else {
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
                Task { await model.startDaemon() }
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
                Text("Found logged-in Claude Code accounts. Adopt reads usage only — macOS asks to allow Keychain access once per account.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unregistered) { d in
                    HStack {
                        Text(d.email.isEmpty ? d.configDir : d.email)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer()
                        Button(model.adoptingDir == d.configDir ? "adopting…" : "Adopt") {
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
                }
            } label: {
                Label("Open cockpit", systemImage: "macwindow")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .disabled(model.cockpitURL == nil || model.status != .live)
            .keyboardShortcut("o")
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
    }
}
