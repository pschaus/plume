import AppKit
import Combine
import SwiftUI

final class NonKeyFloatingPanel: NSPanel {
    var allowKeyFocus: Bool = false
    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if !allowKeyFocus && (event.type == .leftMouseDown || event.type == .rightMouseDown) {
            if #available(macOS 14.0, *),
               let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) {
                NSApp.yieldActivation(to: mailApp)
            }
        }
        super.sendEvent(event)
        if !allowKeyFocus && (event.type == .leftMouseUp || event.type == .rightMouseUp) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let anyMainEditorKey = NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible && $0.isKeyWindow }
                if !anyMainEditorKey,
                   let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) {
                    MailIntegrationService.shared.activateMailApplication(mailApp)
                }
            }
        }
    }
}

@MainActor
final class MailInlineOverlayController: ObservableObject {
    static let shared = MailInlineOverlayController()

    @Published var snapshot: MailComposeOverlaySnapshot? = nil
    @Published var activeIssueID: UUID? = nil
    @Published var isPopoverVisible: Bool = false
    @Published var isPinnedByPill: Bool = false
    @Published var isInlineHighlightEnabled: Bool = true

    private var underlinePanel: NonKeyFloatingPanel?
    private var popoverPanel: NonKeyFloatingPanel?
    private var isUnderlineOrderedFront: Bool = false
    private var isPopoverOrderedFront: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var trackingTimer: Timer?
    private var lastHoverTimestamp: Date = .distantPast
    private var lastAXSnapshotTimestamp: Date = .distantPast

    var onOpenMainEditor: (() -> Void)?

    private init() {
        setupPanels()
        bindState()
        startTrackingTimer()
    }

    private func setupPanels() {
        // 1. Transparent click-through underline overlay panel
        let overlayView = MailUnderlineOverlayView(controller: self)
        let overlayHosting = NSHostingView(rootView: overlayView)

        let uPanel = NonKeyFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        uPanel.allowKeyFocus = false
        uPanel.becomesKeyOnlyIfNeeded = true
        uPanel.isFloatingPanel = true
        uPanel.hidesOnDeactivate = false
        uPanel.level = .floating
        uPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        uPanel.backgroundColor = .clear
        uPanel.isOpaque = false
        uPanel.hasShadow = false
        uPanel.ignoresMouseEvents = true // 100% click-through: never blocks typing or clicking in Mail
        uPanel.acceptsMouseMovedEvents = false
        uPanel.contentView = overlayHosting
        self.underlinePanel = uPanel

        // 2. Interactive inline suggestion popover card panel (never steals keyWindow unless editing text field)
        let popoverView = MailInlinePopoverView(
            controller: self,
            viewModel: SpellCheckerViewModel.shared,
            settings: SettingsManager.shared
        )
        let popoverHosting = NSHostingView(rootView: popoverView)

        let pPanel = NonKeyFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: 156),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        pPanel.allowKeyFocus = false
        pPanel.becomesKeyOnlyIfNeeded = true
        pPanel.isFloatingPanel = true
        pPanel.hidesOnDeactivate = false
        pPanel.level = NSPanel.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        pPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pPanel.backgroundColor = .clear
        pPanel.isOpaque = false
        pPanel.hasShadow = true
        pPanel.ignoresMouseEvents = false
        pPanel.contentView = popoverHosting
        self.popoverPanel = pPanel
    }

    func setPopoverKeyFocusAllowed(_ allowed: Bool) {
        popoverPanel?.allowKeyFocus = allowed
        if allowed {
            popoverPanel?.makeKey()
        } else if let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) {
            MailIntegrationService.shared.activateMailApplication(mailApp)
        }
    }

    func toggleInlineHighlight() {
        isInlineHighlightEnabled.toggle()
        if !isInlineHighlightEnabled {
            snapshot = nil
            underlinePanel?.orderOut(nil)
            isUnderlineOrderedFront = false
            hidePopover()
        } else {
            refreshOverlay()
        }
    }

    private func bindState() {
        SpellCheckerViewModel.shared.$result
            .combineLatest(
                MailIntegrationService.shared.$isMailFrontmost,
                MailIntegrationService.shared.$mailWindowFrame,
                SettingsManager.shared.$showFloatingPill
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshOverlay()
            }
            .store(in: &cancellables)
    }

    private func startTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickTracking()
            }
        }
    }

    func togglePopoverFromPill() {
        let issues = SpellCheckerViewModel.shared.result.issues
        guard !issues.isEmpty else { return }

        if isPopoverVisible && isPinnedByPill {
            hidePopover()
            return
        }

        if !isInlineHighlightEnabled {
            isInlineHighlightEnabled = true
        }
        refreshOverlay()
        isPinnedByPill = true
        if activeIssueID == nil || !issues.contains(where: { $0.id == activeIssueID }) {
            activeIssueID = snapshot?.locatedIssues.first?.issue.id ?? issues.first?.id
        }
        isPopoverVisible = true
        updatePopoverPosition()
    }

    func hidePopover() {
        if isPopoverVisible {
            isPopoverVisible = false
        }
        if isPinnedByPill {
            isPinnedByPill = false
        }
        popoverPanel?.allowKeyFocus = false
        popoverPanel?.orderOut(nil)
        isPopoverOrderedFront = false
    }

    func selectOffsetIssue(delta: Int) {
        let issues = SpellCheckerViewModel.shared.result.issues
        guard !issues.isEmpty else { return }
        let currentIdx = issues.firstIndex(where: { $0.id == activeIssueID }) ?? 0
        let nextIdx = (currentIdx + delta + issues.count) % issues.count
        let nextID = issues[nextIdx].id
        if activeIssueID != nextID {
            activeIssueID = nextID
        }
        if !isPinnedByPill {
            isPinnedByPill = true
        }
        if !isPopoverVisible {
            isPopoverVisible = true
        }
        updatePopoverPosition()
    }

    func refreshOverlay() {
        guard let uPanel = underlinePanel else { return }
        let issues = SpellCheckerViewModel.shared.result.issues

        guard isInlineHighlightEnabled,
              SettingsManager.shared.showFloatingPill,
              MailIntegrationService.shared.isMailFrontmost,
              MailIntegrationService.shared.mailWindowFrame != nil,
              !issues.isEmpty else {
            if snapshot != nil {
                snapshot = nil
            }
            uPanel.orderOut(nil)
            isUnderlineOrderedFront = false
            hidePopover()
            return
        }

        if let newSnapshot = MailIntegrationService.shared.locateIssueRectsInActiveComposeWindow(for: issues),
           !newSnapshot.locatedIssues.isEmpty {
            if self.snapshot != newSnapshot {
                self.snapshot = newSnapshot
            }
            if uPanel.frame != newSnapshot.webAreaFrame {
                uPanel.setFrame(newSnapshot.webAreaFrame, display: true)
            }
            if !isUnderlineOrderedFront {
                uPanel.orderFrontRegardless()
                isUnderlineOrderedFront = true
            }
            uPanel.ignoresMouseEvents = true

            // Keep activeIssueID valid
            if let currentID = activeIssueID,
               !issues.contains(where: { $0.id == currentID }) {
                activeIssueID = newSnapshot.locatedIssues.first?.issue.id ?? issues.first?.id
                if issues.isEmpty {
                    hidePopover()
                }
            }

            if isPopoverVisible {
                updatePopoverPosition()
            }
        } else {
            if snapshot != nil {
                snapshot = nil
            }
            uPanel.orderOut(nil)
            isUnderlineOrderedFront = false
            if !isPinnedByPill {
                hidePopover()
            } else {
                updatePopoverPosition()
            }
        }
    }

    private func tickTracking() {
        guard isInlineHighlightEnabled,
              SettingsManager.shared.showFloatingPill,
              MailIntegrationService.shared.isMailFrontmost,
              MailIntegrationService.shared.mailWindowFrame != nil,
              !SpellCheckerViewModel.shared.result.issues.isEmpty else {
            if isUnderlineOrderedFront || isPopoverOrderedFront || snapshot != nil {
                refreshOverlay()
            }
            return
        }

        // Re-query Accessibility word bounds once every 1.6s to follow scrolling
        if Date().timeIntervalSince(lastAXSnapshotTimestamp) > 1.6 {
            lastAXSnapshotTimestamp = Date()
            refreshOverlay()
        }
        checkMouseHover()
    }

    private func checkMouseHover() {
        guard let snap = snapshot, !snap.locatedIssues.isEmpty else { return }
        let mouseLoc = NSEvent.mouseLocation

        // Check if mouse is currently inside an underlined word's hit box
        for located in snap.locatedIssues {
            for rect in located.rects {
                let hitBox = rect.insetBy(dx: -6, dy: -5)
                if hitBox.contains(mouseLoc) {
                    lastHoverTimestamp = Date()
                    if activeIssueID != located.issue.id || !isPopoverVisible {
                        activeIssueID = located.issue.id
                        isPopoverVisible = true
                        updatePopoverPosition()
                    }
                    return
                }
            }
        }

        // If popover is open and not pinned by pill, keep it open while mouse is inside the popover
        // or within a short 350ms grace period while moving from the word to the popover card
        if isPopoverVisible && !isPinnedByPill {
            if let pPanel = popoverPanel, isPopoverOrderedFront {
                let expandedPopoverFrame = pPanel.frame.insetBy(dx: -14, dy: -14)
                if expandedPopoverFrame.contains(mouseLoc) {
                    lastHoverTimestamp = Date()
                    return
                }
            }
            if Date().timeIntervalSince(lastHoverTimestamp) > 0.38 {
                hidePopover()
            }
        }
    }

    func updatePopoverPosition() {
        guard let pPanel = popoverPanel else { return }
        let issues = SpellCheckerViewModel.shared.result.issues
        guard isInlineHighlightEnabled,
              isPopoverVisible,
              MailIntegrationService.shared.isMailFrontmost,
              let mailRect = MailIntegrationService.shared.mailWindowFrame,
              !issues.isEmpty else {
            pPanel.orderOut(nil)
            isPopoverOrderedFront = false
            return
        }

        let popoverSize = NSSize(width: 336, height: 158)
        let targetID = activeIssueID ?? issues.first?.id

        if let snap = snapshot,
           let located = snap.locatedIssues.first(where: { $0.issue.id == targetID }),
           located.primaryRect.width > 0 {
            let wordRect = located.primaryRect
            let minX = snap.composeWindowFrame.minX + 12
            let maxX = max(minX, snap.composeWindowFrame.maxX - popoverSize.width - 12)
            let originX = min(max(minX, wordRect.minX - 8), maxX)

            // Prefer placing popover right below the underlined word; if too close to bottom of screen, place above
            // but NEVER let it go into the top 250pt toolbar/header zone of the compose window!
            var originY = wordRect.minY - popoverSize.height - 6
            let screenMinY = NSScreen.main?.visibleFrame.minY ?? 40
            let maxAllowedTopY = snap.composeWindowFrame.maxY - 250 - popoverSize.height
            if originY < screenMinY + 20 {
                originY = min(wordRect.maxY + 6, maxAllowedTopY)
            }

            let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: popoverSize)
            if pPanel.frame != targetFrame {
                pPanel.setFrame(targetFrame, display: true)
            }
            if !isPopoverOrderedFront {
                pPanel.orderFrontRegardless()
                isPopoverOrderedFront = true
            }
        } else {
            // Fallback anchor right above the Floating Pill in the bottom-right corner of the compose window
            let originX = max(20, mailRect.maxX - popoverSize.width - 24)
            let originY = max(90, mailRect.minY + 80)
            let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: popoverSize)
            if pPanel.frame != targetFrame {
                pPanel.setFrame(targetFrame, display: true)
            }
            if !isPopoverOrderedFront {
                pPanel.orderFrontRegardless()
                isPopoverOrderedFront = true
            }
        }
    }
}

// MARK: - Transparent Click-Through Underline Canvas Over Apple Mail's AXWebArea

struct MailUnderlineOverlayView: View {
    @ObservedObject var controller: MailInlineOverlayController

    var body: some View {
        GeometryReader { _ in
            if let snap = controller.snapshot {
                Canvas { context, _ in
                    let webFrame = snap.webAreaFrame
                    for located in snap.locatedIssues {
                        let isSelected = (controller.activeIssueID == located.issue.id && controller.isPopoverVisible)
                        let baseColor = located.issue.type.color

                        for screenRect in located.rects {
                            // Convert Cocoa screen coordinates to top-left Canvas coordinates inside webFrame
                            let localX = screenRect.minX - webFrame.minX
                            let localY = webFrame.maxY - screenRect.maxY
                            let width = max(8, screenRect.width)
                            let height = max(12, screenRect.height)

                            guard localX + width >= 0,
                                  localY + height >= 0,
                                  localX <= webFrame.width,
                                  localY <= webFrame.height else {
                                continue
                            }

                            if isSelected {
                                let highlightRect = CGRect(
                                    x: localX - 2,
                                    y: localY,
                                    width: width + 4,
                                    height: height + 1
                                )
                                let bgPath = Path(roundedRect: highlightRect, cornerRadius: 4)
                                context.fill(bgPath, with: .color(baseColor.opacity(0.16)))
                            }

                            let underlineHeight: CGFloat = isSelected ? 3.0 : 2.4
                            let underlineRect = CGRect(
                                x: localX,
                                y: localY + height - 1.5,
                                width: width,
                                height: underlineHeight
                            )
                            let underlinePath = Path(roundedRect: underlineRect, cornerRadius: underlineHeight / 2)
                            context.fill(underlinePath, with: .color(baseColor.opacity(isSelected ? 1.0 : 0.88)))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Interactive Inline Suggestion Popover Card Over Apple Mail

struct MailInlinePopoverView: View {
    @ObservedObject var controller: MailInlineOverlayController
    @ObservedObject var viewModel: SpellCheckerViewModel
    @ObservedObject var settings: SettingsManager

    @State private var isEditingCustom: Bool = false
    @State private var customSuggestion: String = ""

    private var l10n: L10n { settings.l10n }
    private var isFr: Bool { settings.appLanguage == .french }

    private var currentIssue: SpellIssue? {
        let issues = viewModel.result.issues
        guard !issues.isEmpty else { return nil }
        if let id = controller.activeIssueID,
           let match = issues.first(where: { $0.id == id }) {
            return match
        }
        return issues.first
    }

    private var currentIndex: Int {
        guard let issue = currentIssue,
              let idx = viewModel.result.issues.firstIndex(where: { $0.id == issue.id }) else {
            return 0
        }
        return idx
    }

    var body: some View {
        if let issue = currentIssue {
            VStack(alignment: .leading, spacing: 8) {
                // Header: Category Badge + Issue Stepper + Open Editor + Close
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(issue.type.color)
                            .frame(width: 7, height: 7)
                        Text(l10n.categoryName(issue.type))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(issue.type.color)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(issue.type.color.opacity(0.12))
                    .clipShape(Capsule())

                    if viewModel.result.issues.count > 1 {
                        HStack(spacing: 3) {
                            Button {
                                isEditingCustom = false
                                controller.selectOffsetIssue(delta: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.plain)

                            Text("\(currentIndex + 1)/\(viewModel.result.issues.count)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)

                            Button {
                                isEditingCustom = false
                                controller.selectOffsetIssue(delta: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                    }

                    Spacer()

                    Button {
                        controller.hidePopover()
                        controller.onOpenMainEditor?()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.menuOpenEditor)

                    Button {
                        controller.hidePopover()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Original -> Suggestion (or custom inline editor)
                if isEditingCustom {
                    HStack(spacing: 6) {
                        TextField("", text: $customSuggestion)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .medium))

                        Button(isFr ? "OK" : "Save") {
                            let trimmed = customSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                viewModel.updateIssueSuggestion(issue, newSuggestion: trimmed)
                            }
                            isEditingCustom = false
                            controller.setPopoverKeyFocusAllowed(false)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(isFr ? "Annuler" : "Cancel") {
                            isEditingCustom = false
                            controller.setPopoverKeyFocusAllowed(false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(issue.original)
                            .font(.system(size: 12, weight: .medium))
                            .strikethrough(true, color: .red.opacity(0.8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)

                        Button {
                            applySingleIssueInMail(issue)
                        } label: {
                            Text(issue.suggestion)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(red: 0.14, green: 0.62, blue: 0.42))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Button {
                            customSuggestion = issue.suggestion
                            isEditingCustom = true
                            controller.setPopoverKeyFocusAllowed(true)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.customizeReplacementTooltip)
                    }
                }

                // Explanation
                Text(issue.explanation)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                // Bottom Action Buttons
                HStack(spacing: 8) {
                    Button {
                        applySingleIssueInMail(issue)
                    } label: {
                        Label(l10n.acceptAndUpdateMailButton, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.14, green: 0.62, blue: 0.42))
                    .controlSize(.small)

                    if viewModel.result.issues.count > 1 {
                        Button {
                            viewModel.acceptAll(syncToMail: true)
                            controller.hidePopover()
                        } label: {
                            Text(l10n.pillFixAllButton)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button {
                        viewModel.dismissIssue(issue)
                        if viewModel.result.issues.isEmpty {
                            controller.hidePopover()
                        } else {
                            controller.refreshOverlay()
                        }
                    } label: {
                        Text(l10n.ignoreButton)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(width: 336, height: 158)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }

    private func applySingleIssueInMail(_ issue: SpellIssue) {
        viewModel.acceptIssue(issue, syncToMail: true)
        if viewModel.result.issues.isEmpty {
            controller.hidePopover()
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                controller.refreshOverlay()
            }
        }
    }
}
