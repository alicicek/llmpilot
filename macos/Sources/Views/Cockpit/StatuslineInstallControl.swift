import SwiftUI

/// The "Install statusline" button plus its consent step and result line —
/// the one control every surface mounts (doctor note, Settings, the
/// statusline editor), so the consent question never gets a second wording.
struct StatuslineInstallControl: View {
    @ObservedObject var model: StatuslineInstallModel
    /// Where the control sits decides the button's look: the doctor's
    /// remedy column uses its filled action button, Settings its plain
    /// system buttons.
    var filled = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch model.phase {
            case .idle, .busy:
                button(model.phase == .busy ? StatuslineInstallCopy.working : StatuslineInstallCopy.button,
                       action: model.install, identifier: "statusline-install")
                    .disabled(model.phase == .busy)
            case .needsConsent:
                VStack(alignment: .trailing, spacing: 6) {
                    Text(StatuslineInstallCopy.consent)
                        .font(.system(size: 10.5))
                        .foregroundColor(CockpitTheme.sec)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(StatuslineInstallCopy.cancel, action: model.cancel)
                            .accessibilityIdentifier("statusline-install-cancel")
                        Button(StatuslineInstallCopy.keepBoth, action: model.keep)
                            .accessibilityIdentifier("statusline-install-keep")
                        Button(StatuslineInstallCopy.replaceIt, action: model.replace)
                            .accessibilityIdentifier("statusline-install-replace")
                    }
                }
            case let .done(outcome):
                Text(StatuslineInstallCopy.result(outcome))
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.okTx)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("statusline-install-result")
            case let .failed(message):
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundColor(CockpitTheme.warn)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    button(StatuslineInstallCopy.button, action: model.install, identifier: "statusline-install")
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ title: String, action: @escaping () -> Void, identifier: String) -> some View {
        if filled {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(CockpitTheme.actionFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(title)
        } else {
            Button(title, action: action)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
    }
}
