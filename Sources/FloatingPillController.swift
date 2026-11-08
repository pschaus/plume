import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingPillController {
    static let shared = FloatingPillController()

    private var panel: NSPanel?
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
            onOpenEditor: { [weak self] in
                self?.onOpenMainEditor?()
            }
        )

        let hostingView = NSHostingView(rootView: pillView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 52)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 52),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
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
            .combineLatest(SettingsManager.shared.$showFloatingPill)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateVisibilityAndPosition()
            }
            .store(in: &cancellables)
    }

    func updateVisibilityAndPosition() {
        guard let panel else { return }
        guard SettingsManager.shared.showFloatingPill else {
            panel.orderOut(nil)
            return
        }

        let pillSize = NSSize(width: 340, height: 52)
        if let mailRect = MailIntegrationService.shared.mailWindowFrame {
            // Anchor to bottom-right corner of Apple Mail window
            let originX = max(20, mailRect.maxX - pillSize.width - 24)
            let originY = max(40, mailRect.minY + 20)
            panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: pillSize), display: true)
            panel.orderFrontRegardless()
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let originX = visible.maxX - pillSize.width - 28
            let originY = visible.minY + 28
            panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: pillSize), display: true)
            panel.orderFrontRegardless()
        }
    }
}

struct FloatingPillView: View {
    @ObservedObject var viewModel: SpellCheckerViewModel
    @ObservedObject var mailService: MailIntegrationService
    @ObservedObject var settings: SettingsManager
    var onOpenEditor: () -> Void

    private var l10n: L10n { settings.l10n }

    var body: some View {
        HStack(spacing: 10) {
            // Circular status badge
            Button(action: onOpenEditor) {
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

            // Quick Actions on Pill
            Button {
                Task {
                    await viewModel.pullFromMailAndCheck()
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
        if viewModel.result.issues.isEmpty {
            return Color(red: 0.14, green: 0.65, blue: 0.42) // Emerald Green
        }
        return Color(red: 0.90, green: 0.22, blue: 0.27) // Mistake Red
    }

    private var statusSubtitle: String {
        if viewModel.isChecking {
            return l10n.pillCheckingStatus(provider: settings.selectedProvider.rawValue)
        }
        let count = viewModel.result.issues.count
        if count == 0 {
            return l10n.pillNoIssuesStatus
        }
        return l10n.pillIssuesCountStatus(count)
    }
}
