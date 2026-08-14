import SwiftUI

// Native port of web/src/history/ChartKit.tsx (card shell, quiet state,
// legend row — the tooltip pill has no native port, see the note on
// `HistoryCard` below) and web/src/history/Filters.tsx (the range/account
// filter row). Shared by every card in HistoryCards.swift/HistoryCardsMore.swift.

/// Resolves one of `HistoryColors`' hex strings to a `Color`. `HistoryColors`
/// already bakes the light/dark choice into the hex it returns (the caller
/// passes its own `dark` bool in) — this is a flat parse, never an
/// appearance-tracking dynamic color like `CockpitTheme`'s.
func historyColor(_ hex: String) -> Color {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard let v = UInt32(s, radix: 16) else { return CockpitTheme.grayDot }
    return Color(
        red: Double((v >> 16) & 0xFF) / 255,
        green: Double((v >> 8) & 0xFF) / 255,
        blue: Double(v & 0xFF) / 255
    )
}

// MARK: - Card (ChartKit.tsx `Card`, lines 6-28)

struct HistoryCard<Content: View>: View {
    let title: String
    var subCaption: String?
    var wide: Bool = false
    var loading: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(CockpitTheme.sec)
                if let subCaption {
                    Text(subCaption)
                        .font(.system(size: 10))
                        .foregroundColor(CockpitTheme.ter)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CockpitTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(loading ? 0.6 : 1)
        .animation(.easeInOut(duration: CockpitTheme.Motion.swap), value: loading)
    }
}

// MARK: - QuietState (ChartKit.tsx `QuietState`, lines 32-42)

struct HistoryQuietState: View {
    let message: String
    var wide: Bool = false

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(CockpitTheme.ter)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.horizontal, 16)
            .background(CockpitTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - LegendRow (ChartKit.tsx `LegendRow`, lines 64-76)

struct HistoryLegendEntry: Identifiable {
    var id: String { label }
    let label: String
    let color: Color
    let share: Double
}

struct HistoryLegendRow: View {
    let entries: [HistoryLegendEntry]

    var body: some View {
        // SwiftUI has no CSS-style flex-wrap; a fixed-width `LazyVGrid` of
        // adaptive columns is the idiomatic native equivalent for a legend
        // that wraps at the card's own width.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], alignment: .leading, spacing: 6) {
            ForEach(entries) { e in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(e.color)
                        .frame(width: 8, height: 8)
                    Text(e.label)
                        .font(.system(size: 10.5))
                        .foregroundColor(CockpitTheme.sec)
                    Text("\(Int(e.share.rounded()))%")
                        .font(.system(size: 10.5))
                        .foregroundColor(CockpitTheme.ter)
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - FiltersRow (Filters.tsx)

struct HistoryFiltersRow: View {
    let range: HistoryRangeKey
    let onRangeChange: (HistoryRangeKey) -> Void
    let accountOptions: [HistoryDerivation.AccountOption]
    let selected: Set<String>
    let onToggle: (String) -> Void
    let onSelectAll: () -> Void

    private var accountsLabel: String {
        HistoryDerivation.accountsCaption(selectedCount: selected.count, totalCount: accountOptions.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            rangeTabs
            accountsMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var rangeTabs: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRangeKey.allCases) { key in
                Button(action: { onRangeChange(key) }) {
                    Text(key.tabLabel)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(range == key ? CockpitTheme.accTx : Color.clear)
                        .foregroundColor(range == key ? .white : CockpitTheme.sec)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date range")
    }

    // NOTE (deviation): Filters.tsx's account menu is a Radix
    // DropdownMenu.CheckboxItem list that stays OPEN across multiple
    // toggles (`onSelect={(e) => e.preventDefault()}`) so a user can check
    // several accounts in one click sequence. AppKit's native `Menu` closes
    // after each item selection — there is no public SwiftUI API to keep a
    // `Menu` open across a click the way the web's custom dropdown does.
    // Each toggle still applies correctly; it just costs a re-open per
    // account, a real but minor UX regression versus the web multi-check
    // menu, accepted rather than building a custom popover for this chunk.
    private var accountsMenu: some View {
        Menu {
            ForEach(accountOptions) { opt in
                Button {
                    onToggle(opt.id)
                } label: {
                    if selected.contains(opt.id) {
                        Label(opt.label, systemImage: "checkmark")
                    } else {
                        Text(opt.label)
                    }
                }
            }
            Divider()
            Button("Select all", action: onSelectAll)
        } label: {
            Text(accountsLabel)
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.sec)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.hair, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Accounts filter: \(accountsLabel)")
    }
}
