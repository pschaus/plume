import AppKit
import SwiftUI

struct MainEditorView: View {
    @ObservedObject var viewModel: SpellCheckerViewModel
    @ObservedObject var settings: SettingsManager
    @ObservedObject var mailService: MailIntegrationService
    @ObservedObject var updateService: UpdateCheckerService = .shared
    @State private var showingSettingsSheet = false
    @State private var showingChangelogSheet = false

    private var l10n: L10n { settings.l10n }

    var body: some View {
        VStack(spacing: 0) {
            headerToolbar

            Divider()

            if updateService.shouldShowBanner, let update = updateService.availableUpdate {
                updateAvailableBanner(update)
            }

            if !mailService.isAccessibilityTrusted {
                accessibilityOnboardingBanner
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            if let status = viewModel.statusBanner {
                statusToast(status)
            }

            // Main Content: Light Indicator Mode vs Fine-Grained Split Mode
            if viewModel.displayMode == .lightIndicator {
                lightIndicatorContent
            } else {
                fineGrainedSplitContent
            }

            Divider()

            mailComposeAndActionBar
        }
        .frame(minWidth: 820, minHeight: 540)
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView(settings: settings, mailService: mailService)
        }
        .sheet(isPresented: $showingChangelogSheet) {
            if let update = updateService.availableUpdate {
                UpdateChangelogSheet(
                    update: update,
                    currentVersion: updateService.currentVersion,
                    lang: settings.appLanguage
                )
            }
        }
    }

    private func updateAvailableBanner(_ update: AppUpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .foregroundColor(.white)
            Text(settings.appLanguage == .french
                 ? "🎉 Nouvelle version disponible : Plume v\(update.version) (actuelle : v\(updateService.currentVersion))"
                 : "🎉 New version available: Plume v\(update.version) (current: v\(updateService.currentVersion))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            Button(settings.appLanguage == .french ? "Nouveautés (Changelog)" : "View Changelog") {
                showingChangelogSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(settings.appLanguage == .french ? "Télécharger (.dmg)" : "Download (.dmg)") {
                NSWorkspace.shared.open(update.dmgDownloadURL)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundColor(Color(red: 0.310, green: 0.275, blue: 0.898))
            .controlSize(.small)

            Button {
                updateService.dismissedVersion = update.version
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 0.310, green: 0.275, blue: 0.898))
    }

    private var accessibilityOnboardingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundColor(.orange)
            Text(l10n.accessibilityBannerText)
                .font(.system(size: 12))
            Spacer()
            Button(l10n.enableInSystemSettingsButton) {
                mailService.requestAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }

    // MARK: - Top Header Toolbar

    private var headerToolbar: some View {
        HStack(spacing: 12) {
            // App Title & Language Detection Badge
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    PlumeLogoView(size: 28)

                    Text("Plume")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }
                .fixedSize(horizontal: true, vertical: false)

                // Detected Language Pill
                HStack(spacing: 6) {
                    Text(viewModel.result.displayFlag)
                        .font(.system(size: 14))
                    Text(l10n.localizedDetectedLanguage(viewModel.result.detectedLanguage))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                )
                .fixedSize(horizontal: true, vertical: false)
                .help(l10n.detectedLanguageTooltip)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)

            Spacer(minLength: 6)

            // Mode Switcher: Light Indicator vs Fine-Grained Editor
            Picker("", selection: $viewModel.displayMode) {
                ForEach(EditorDisplayMode.allCases) { mode in
                    Text(l10n.modeName(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 6)

            // Provider, UI Language & Settings Controls
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { settings.selectedProvider },
                    set: { settings.selectProvider($0) }
                )) {
                    ForEach(LLMProvider.allCases) { provider in
                        Label(provider.rawValue, systemImage: provider.iconName)
                            .tag(provider)
                    }
                }
                .labelsHidden()
                .frame(width: 155)

                // UI Language Toggle (FR / EN)
                Picker("", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.shortBadge).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                .help(l10n.uiLanguageTooltip)

                Button {
                    showingSettingsSheet = true
                } label: {
                    Label(l10n.apiKeysAndModelsButton, systemImage: "key.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Mode 1: Light Indicator Mode (Compact Inline Highlights + Popover Bar)

    private var lightIndicatorContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                issueLegendDot(color: IssueCategory.spelling.color, label: "\(l10n.categoryName(.spelling)) (\(count(for: .spelling)))")
                issueLegendDot(color: IssueCategory.grammar.color, label: "\(l10n.categoryName(.grammar)) (\(count(for: .grammar)))")
                issueLegendDot(color: IssueCategory.style.color, label: "\(l10n.categoryName(.style)) (\(count(for: .style)))")

                Spacer()

                Text(l10n.clickUnderlinedWordHint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))

            Divider()

            HighlightedTextEditor(
                text: $viewModel.text,
                issues: viewModel.result.issues,
                selectedIssueID: $viewModel.selectedIssueID,
                onTextEdited: {
                    if settings.autoCheckInMail {
                        viewModel.scheduleDebouncedCheck()
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selectedID = viewModel.selectedIssueID,
               let issue = viewModel.result.issues.first(where: { $0.id == selectedID }) {
                Divider()
                inlineQuickFixBar(for: issue)
            }
        }
    }

    private func inlineQuickFixBar(for issue: SpellIssue) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(issue.type.color)
                .frame(width: 10, height: 10)

            Text(l10n.categoryName(issue.type).uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(issue.type.color)

            Text(issue.original)
                .strikethrough()
                .foregroundColor(.secondary)
                .font(.system(size: 13, weight: .medium))

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)

            Text(issue.suggestion)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 0.14, green: 0.62, blue: 0.42))

            Text("— \(issue.explanation)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            Button(l10n.acceptFixButton) {
                viewModel.acceptIssue(issue)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.14, green: 0.62, blue: 0.42))
            .controlSize(.small)

            Button(l10n.ignoreButton) {
                viewModel.dismissIssue(issue)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Mode 2: Fine-Grained Split Editor Mode

    private var fineGrainedSplitContent: some View {
        HSplitView {
            // Left: Full Editable Text Area with Live Underlines
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(l10n.editableBodyHeader, systemImage: "pencil.and.outline")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.text.count) \(l10n.charsLabel)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))

                Divider()

                HighlightedTextEditor(
                    text: $viewModel.text,
                    issues: viewModel.result.issues,
                    selectedIssueID: $viewModel.selectedIssueID,
                    onTextEdited: {
                        if settings.autoCheckInMail {
                            viewModel.scheduleDebouncedCheck()
                        }
                    }
                )
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            // Right: Granular Issue Cards & Category Filters
            VStack(alignment: .leading, spacing: 0) {
                categoryFilterHeader

                Divider()

                if viewModel.isChecking {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                            .controlSize(.regular)
                        Text(l10n.analyzingWith(provider: settings.selectedProvider.rawValue, model: settings.selectedModel))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredIssues.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 36))
                            .foregroundColor(Color(red: 0.14, green: 0.62, blue: 0.42))
                        Text(viewModel.result.issues.isEmpty ? l10n.noIssuesFoundTitle : l10n.noIssuesInCategoryTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(l10n.detectedLanguageSubtitle(
                            flag: viewModel.result.displayFlag,
                            name: l10n.localizedDetectedLanguage(viewModel.result.detectedLanguage)
                        ))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewModel.filteredIssues) { issue in
                                IssueGranularCard(
                                    issue: issue,
                                    l10n: l10n,
                                    isSelected: viewModel.selectedIssueID == issue.id,
                                    onSelect: {
                                        viewModel.selectedIssueID = issue.id
                                    },
                                    onAccept: {
                                        viewModel.acceptIssue(issue)
                                    },
                                    onAcceptAndSyncMail: {
                                        viewModel.acceptIssue(issue, syncToMail: true)
                                    },
                                    onDismiss: {
                                        viewModel.dismissIssue(issue)
                                    },
                                    onSuggestionChanged: { newSuggestion in
                                        viewModel.updateIssueSuggestion(issue, newSuggestion: newSuggestion)
                                    }
                                )
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 430, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
    }

    private var categoryFilterHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.suggestionsHeader(count: viewModel.result.issues.count))
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if !viewModel.result.issues.isEmpty {
                    Button(l10n.acceptAllButton(count: viewModel.filteredIssues.count)) {
                        viewModel.acceptAll(category: viewModel.selectedCategoryFilter)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.14, green: 0.62, blue: 0.42))
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                filterPill(title: l10n.allFilter(count: viewModel.result.issues.count), category: nil)
                ForEach(IssueCategory.allCases) { cat in
                    filterPill(title: "\(l10n.categoryName(cat)) (\(count(for: cat)))", category: cat)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func filterPill(title: String, category: IssueCategory?) -> some View {
        let isSelected = (viewModel.selectedCategoryFilter == category)
        return Button {
            viewModel.selectedCategoryFilter = category
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isSelected ? (category?.color ?? Color.accentColor).opacity(0.2) : Color.primary.opacity(0.06))
                )
                .foregroundColor(isSelected ? (category?.color ?? Color.accentColor) : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Bar: Apple Mail Live Sync & Compose

    private var mailComposeAndActionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.pullFromMailAndCheck()
                    }
                } label: {
                    Label(l10n.pullFromMailButton, systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help(l10n.pullFromMailTooltip)

                Button {
                    Task {
                        await viewModel.runSpellCheck()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if viewModel.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(viewModel.isChecking ? l10n.checkingButton : l10n.checkSpellingButton)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isChecking)
                .keyboardShortcut(.return, modifiers: [.command])

                Button {
                    viewModel.pushToMail()
                } label: {
                    Label(l10n.applyToMailButton, systemImage: "arrow.up.doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help(l10n.applyToMailTooltip)

                Spacer()

                Button {
                    if !mailService.isAccessibilityTrusted {
                        mailService.requestAccessibilityPermission()
                    } else {
                        showingSettingsSheet = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(mailService.isAccessibilityTrusted ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(mailService.isAccessibilityTrusted ? l10n.mailLiveHookActive : l10n.grantAccessibilityPrompt)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                Text(l10n.toLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                TextField(l10n.recipientPlaceholder, text: $viewModel.emailRecipient)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 185)

                Text(l10n.subjectLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                TextField(l10n.subjectPlaceholder, text: $viewModel.emailSubject)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)

                Button {
                    viewModel.openOrSendInMail(sendImmediately: false)
                } label: {
                    Label(l10n.openDraftInMailButton, systemImage: "envelope.open")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.openOrSendInMail(sendImmediately: true)
                } label: {
                    Label(l10n.sendInMailButton, systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    private func count(for category: IssueCategory) -> Int {
        viewModel.result.issues.filter { $0.type == category }.count
    }

    private func issueLegendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Button(l10n.settingsButton) {
                showingSettingsSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(l10n.dismissButton) {
                viewModel.errorMessage = nil
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.85))
    }

    private func statusToast(_ message: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(red: 0.14, green: 0.62, blue: 0.42))
    }
}

// MARK: - Fine-Grained Issue Card

struct IssueGranularCard: View {
    let issue: SpellIssue
    let l10n: L10n
    let isSelected: Bool
    let onSelect: () -> Void
    let onAccept: () -> Void
    let onAcceptAndSyncMail: () -> Void
    let onDismiss: () -> Void
    let onSuggestionChanged: (String) -> Void

    @State private var editableSuggestion: String = ""
    @State private var isEditingCustom: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(issue.type.color)
                        .frame(width: 8, height: 8)
                    Text(l10n.categoryName(issue.type).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(issue.type.color)
                }

                Spacer()

                Button {
                    isEditingCustom.toggle()
                    editableSuggestion = issue.suggestion
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.customizeReplacementTooltip)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.ignoreSuggestionTooltip)
            }

            HStack(spacing: 6) {
                Text(issue.original)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough()
                    .foregroundColor(.secondary)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                if isEditingCustom {
                    TextField(l10n.replacementPlaceholder, text: $editableSuggestion)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .bold))
                        .onSubmit {
                            onSuggestionChanged(editableSuggestion)
                            isEditingCustom = false
                        }
                } else {
                    Text(issue.suggestion)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 0.14, green: 0.62, blue: 0.42))
                }
            }

            if !issue.explanation.isEmpty {
                Text(issue.explanation)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    if isEditingCustom {
                        onSuggestionChanged(editableSuggestion)
                        isEditingCustom = false
                    }
                    onAccept()
                } label: {
                    Label(l10n.acceptButton, systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.14, green: 0.62, blue: 0.42))
                .controlSize(.small)

                Button {
                    if isEditingCustom {
                        onSuggestionChanged(editableSuggestion)
                        isEditingCustom = false
                    }
                    onAcceptAndSyncMail()
                } label: {
                    Label(l10n.acceptAndUpdateMailButton, systemImage: "envelope.badge.shield.half.filled")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? issue.type.color : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                )
        )
        .onTapGesture {
            onSelect()
        }
    }
}
