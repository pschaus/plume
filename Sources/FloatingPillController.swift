import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingPillController {
    static let shared = FloatingPillController()

    private var panel: NonKeyFloatingPanel?
    private var isOrderedFront: Bool = false
    private var cancellables = Set<AnyCancellable>()
    var onOpenMainEditor: (() -> Void)?

    private init() {
        setupPanel()
        bindPositioning()
    }

    private func setupPanel() {
        let pillView = FloatingPillView(
            viewModel: SpellCheckerViewModel.shared,
            mailService: MailIntegrationService.shared,
            settings: SettingsManager.shared,
            overlayController: MailInlineOverlayController.shared,
            onOpenEditor: { [weak self] in
                self?.onOpenMainEditor?()
            }
        )

        let hostingView = NSHostingView(rootView: pillView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 376, height: 52)

        let panel = NonKeyFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 52),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.allowKeyFocus = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView

        self.panel = panel
        updateVisibilityAndPosition()
    }

    private func bindPositioning() {
        MailIntegrationService.shared.$mailWindowFrame
            .combineLatest(
                MailIntegrationService.shared.$isMailFrontmost,
                SettingsManager.shared.$showFloatingPill
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateVisibilityAndPosition()
            }
            .store(in: &cancellables)
    }

    func updateVisibilityAndPosition() {
        guard let panel else { return }
        guard SettingsManager.shared.showFloatingPill,
              MailIntegrationService.shared.isMailFrontmost,
              let mailRect = MailIntegrationService.shared.mailWindowFrame else {
            panel.orderOut(nil)
            isOrderedFront = false
            return
        }

        let pillSize = NSSize(width: 376, height: 52)
        // Anchor to bottom-right corner of the active Apple Mail compose window
        let originX = max(20, mailRect.maxX - pillSize.width - 24)
        let originY = max(40, mailRect.minY + 20)
        let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: pillSize)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
        if !isOrderedFront {
            panel.orderFrontRegardless()
            isOrderedFront = true
        }
    }
}

struct FloatingPillView: View {
    @ObservedObject var viewModel: SpellCheckerViewModel
    @ObservedObject var mailService: MailIntegrationService
    @ObservedObject var settings: SettingsManager
    @ObservedObject var overlayController: MailInlineOverlayController
    var onOpenEditor: () -> Void

    private var l10n: L10n { settings.l10n }

    var body: some View {
        HStack(spacing: 8) {
            // Circular status badge (toggles inline popover in Mail when issues exist, or opens editor)
            Button {
                if !viewModel.result.issues.isEmpty {
                    overlayController.togglePopoverFromPill()
                } else {
                    onOpenEditor()
                }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 28, height: 28)

                        if viewModel.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else if !viewModel.result.issues.isEmpty {
                            Text("\(viewModel.result.issues.count)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(viewModel.result.displayFlag)
                                .font(.system(size: 12))
                            Text(l10n.localizedDetectedLanguage(viewModel.result.detectedLanguage))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        Text(statusSubtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            // Toggle inline highlighting in the current email
            Button {
                overlayController.toggleInlineHighlight()
            } label: {
                Image(systemName: overlayController.isInlineHighlightEnabled ? "highlighter" : "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(
                        overlayController.isInlineHighlightEnabled
                            ? Color(red: 0.38, green: 0.34, blue: 0.92)
                            : .secondary
                    )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(
                overlayController.isInlineHighlightEnabled
                    ? l10n.pillToggleHighlightOffTooltip
                    : l10n.pillToggleHighlightOnTooltip
            )

            // Quick Actions on Pill
            Button {
                Task {
                    await viewModel.pullFromMailAndCheck(activatePlumeAfterPull: false)
                }
            } label: {
                Label(l10n.pillCheckMailButton, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(l10n.pullFromMailTooltip)

            if !viewModel.result.issues.isEmpty {
                Button {
                    viewModel.acceptAll(syncToMail: true)
                } label: {
                    Text(l10n.pillFixAllButton)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.14, green: 0.62, blue: 0.42))
                .controlSize(.small)
                .help(l10n.applyToMailTooltip)
            } else {
                Button(action: onOpenEditor) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(l10n.menuOpenEditor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private var badgeColor: Color {
        if viewModel.isChecking {
            return .blue
        }
        if !overlayController.isInlineHighlightEnabled {
            return .gray
        }
        if viewModel.result.issues.isEmpty {
            return Color(red: 0.14, green: 0.65, blue: 0.42) // Emerald Green
        }
        return Color(red: 0.90, green: 0.22, blue: 0.27) // Mistake Red
    }

    private var statusSubtitle: String {
        if viewModel.isChecking {
            return l10n.pillCheckingStatus(provider: settings.selectedProvider.rawValue)
        }
        if !overlayController.isInlineHighlightEnabled {
            return l10n.pillHighlightDisabledStatus
        }
        let count = viewModel.result.issues.count
        if count == 0 {
            return l10n.pillNoIssuesStatus
        }
        return l10n.pillIssuesCountStatus(count)
    }
}
