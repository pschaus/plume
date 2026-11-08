import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class SpellCheckerViewModel: ObservableObject {
    static let shared = SpellCheckerViewModel()

    @Published var text: String = """
    Bonjour,

    Je vous envoyerai les document concernant le projet demain matin. J'ai vérifié tout les détails et tout semble fonctioner correctement.

    Merci beaucoups pour votre aide!
    """

    @Published var emailRecipient: String = ""
    @Published var emailSubject: String = ""

    @Published var result: SpellCheckResult = SpellCheckResult(
        detectedLanguage: "French",
        languageFlag: "🇫🇷",
        issues: [
            SpellIssue(
                original: "envoyerai",
                suggestion: "enverrai",
                type: .spelling,
                explanation: "Conjugaison irrégulière du verbe envoyer au futur simple : « j'enverrai »."
            ),
            SpellIssue(
                original: "les document",
                suggestion: "les documents",
                type: .grammar,
                explanation: "Accord au pluriel du nom « document » après l'article « les »."
            ),
            SpellIssue(
                original: "tout les détails",
                suggestion: "tous les détails",
                type: .grammar,
                explanation: "Devant un nom masculin pluriel, « tous » s'écrit avec un « s »."
            ),
            SpellIssue(
                original: "fonctioner",
                suggestion: "fonctionner",
                type: .spelling,
                explanation: "Le verbe « fonctionner » prend deux « n »."
            ),
            SpellIssue(
                original: "Merci beaucoups",
                suggestion: "Merci beaucoup",
                type: .spelling,
                explanation: "L'adverbe « beaucoup » est invariable et ne prend jamais de « s »."
            )
        ]
    )
    @Published var isChecking: Bool = false
    @Published var errorMessage: String? = nil
    @Published var statusBanner: String? = nil

    @Published var displayMode: EditorDisplayMode = .fineGrained
    @Published var selectedCategoryFilter: IssueCategory? = nil
    @Published var selectedIssueID: UUID? = nil

    private var debounceTask: Task<Void, Never>?

    var filteredIssues: [SpellIssue] {
        guard let filter = selectedCategoryFilter else {
            return result.issues
        }
        return result.issues.filter { $0.type == filter }
    }

    func scheduleDebouncedCheck(delayNanoseconds: UInt64 = 1_400_000_000) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await runSpellCheck()
        }
    }

    func runSpellCheck() async {
        let currentText = text
        guard !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result = .empty
            errorMessage = nil
            return
        }

        let settings = SettingsManager.shared
        let provider = settings.selectedProvider
        let model = settings.selectedModel
        let apiKey = settings.apiKey(for: provider)

        isChecking = true
        errorMessage = nil

        do {
            let checkResult = try await LLMService.shared.checkText(
                currentText,
                provider: provider,
                model: model,
                apiKey: apiKey,
                ollamaEndpoint: settings.ollamaEndpoint
            )
            self.result = checkResult
            if let first = checkResult.issues.first {
                self.selectedIssueID = first.id
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }

        isChecking = false
    }

    // MARK: - Fine-Grained Actions

    func acceptIssue(_ issue: SpellIssue, syncToMail: Bool = false) {
        if let range = text.range(of: issue.original) {
            text.replaceSubrange(range, with: issue.suggestion)
        }
        result.issues.removeAll { $0.id == issue.id }
        if selectedIssueID == issue.id {
            selectedIssueID = result.issues.first?.id
        }
        showTransientBanner(SettingsManager.shared.l10n.appliedSingleFix(original: issue.original, suggestion: issue.suggestion))

        if syncToMail {
            pushToMail()
        }
    }

    func dismissIssue(_ issue: SpellIssue) {
        result.issues.removeAll { $0.id == issue.id }
        if selectedIssueID == issue.id {
            selectedIssueID = result.issues.first?.id
        }
    }

    func updateIssueSuggestion(_ issue: SpellIssue, newSuggestion: String) {
        if let idx = result.issues.firstIndex(where: { $0.id == issue.id }) {
            result.issues[idx].suggestion = newSuggestion
        }
    }

    func acceptAll(category: IssueCategory? = nil, syncToMail: Bool = false) {
        let issuesToApply = category == nil
            ? result.issues
            : result.issues.filter { $0.type == category }

        var count = 0
        for issue in issuesToApply {
            if let range = text.range(of: issue.original) {
                text.replaceSubrange(range, with: issue.suggestion)
                count += 1
            }
        }

        if let category {
            result.issues.removeAll { $0.type == category }
        } else {
            result.issues.removeAll()
        }
        selectedIssueID = result.issues.first?.id

        showTransientBanner(SettingsManager.shared.l10n.appliedMultipleFixes(count))

        if syncToMail {
            pushToMail()
        }
    }

    // MARK: - Apple Mail Actions

    func pullFromMailAndCheck() async {
        errorMessage = nil
        let pullResult = await MailIntegrationService.shared.pullTextFromMail()
        switch pullResult {
        case .success(let mailText):
            self.text = mailText
            showTransientBanner(SettingsManager.shared.l10n.pulledFromMailToast(mailText.count))
            await runSpellCheck()
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    func pushToMail() {
        errorMessage = nil
        let currentText = text
        Task {
            let applyResult = await MailIntegrationService.shared.applyCorrectedTextToMail(currentText)
            switch applyResult {
            case .success:
                showTransientBanner(SettingsManager.shared.l10n.replacedInMailToast)
            case .failure(let err):
                errorMessage = SettingsManager.shared.l10n.copiedToClipboardFallback(err.localizedDescription)
            }
        }
    }

    func openOrSendInMail(sendImmediately: Bool) {
        MailIntegrationService.shared.openDraftInAppleMail(
            recipient: emailRecipient,
            subject: emailSubject,
            body: text,
            sendImmediately: sendImmediately
        )
        showTransientBanner(sendImmediately
            ? "Sent/Opened email to \(emailRecipient) in Apple Mail"
            : "Opened compose window to \(emailRecipient) in Apple Mail")
    }

    private func showTransientBanner(_ message: String) {
        statusBanner = message
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.statusBanner == message {
                self.statusBanner = nil
            }
        }
    }
}
