import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case french = "fr"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .french: return "Français"
        case .english: return "English"
        }
    }

    var shortBadge: String {
        switch self {
        case .french: return "🇫🇷 FR"
        case .english: return "🇬🇧 EN"
        }
    }
}

struct L10n {
    let lang: AppLanguage

    // MARK: - Header & Modes
    var windowTitle: String {
        lang == .french
            ? "Plume — Correcteur IA & Assistant pour Apple Mail"
            : "Plume — AI Writing & Spell Assistant for Mail"
    }

    func modeName(_ mode: EditorDisplayMode) -> String {
        switch mode {
        case .lightIndicator:
            return lang == .french ? "Indicateur léger" : "Light Indicator"
        case .fineGrained:
            return lang == .french ? "Éditeur détaillé" : "Fine-Grained Editor"
        }
    }

    func categoryName(_ category: IssueCategory) -> String {
        switch category {
        case .spelling:
            return lang == .french ? "Orthographe" : "Spelling"
        case .grammar:
            return lang == .french ? "Grammaire" : "Grammar"
        case .style:
            return lang == .french ? "Style" : "Style"
        }
    }

    func localizedDetectedLanguage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "ready" {
            return lang == .french ? "Prêt" : "Ready"
        }
        if lang == .french {
            if lower.contains("french") || lower.contains("français") { return "Français" }
            if lower.contains("english") || lower.contains("anglais") { return "Anglais" }
            if lower.contains("spanish") || lower.contains("español") { return "Espagnol" }
            if lower.contains("german") || lower.contains("deutsch") { return "Allemand" }
            if lower.contains("dutch") || lower.contains("nederlands") { return "Néerlandais" }
            if lower.contains("italian") || lower.contains("italiano") { return "Italien" }
        } else {
            if lower.contains("français") || lower.contains("french") { return "French" }
            if lower.contains("anglais") || lower.contains("english") { return "English" }
            if lower.contains("espagnol") || lower.contains("spanish") { return "Spanish" }
            if lower.contains("allemand") || lower.contains("german") { return "German" }
            if lower.contains("néerlandais") || lower.contains("dutch") { return "Dutch" }
            if lower.contains("italien") || lower.contains("italian") { return "Italian" }
        }
        return raw
    }

    var detectedLanguageTooltip: String {
        lang == .french ? "Langue du texte détectée automatiquement" : "Automatically detected text language"
    }

    var uiLanguageTooltip: String {
        lang == .french ? "Changer la langue de l'interface (FR / EN)" : "Switch interface language (FR / EN)"
    }

    var apiKeysAndModelsButton: String {
        lang == .french ? "Clés API & Modèles" : "API Keys & Models"
    }

    // MARK: - Accessibility Banner
    var accessibilityBannerText: String {
        lang == .french
            ? "Pour activer « Lire depuis Mail » et « Appliquer dans Mail », autorisez Plume dans Réglages Système → Confidentialité et sécurité → Accessibilité."
            : "To enable 'Pull from Apple Mail' & 'Apply to Mail', enable Plume in System Settings → Privacy & Security → Accessibility."
    }

    var enableInSystemSettingsButton: String {
        lang == .french ? "Ouvrir Réglages Système..." : "Enable in System Settings..."
    }

    var settingsButton: String {
        lang == .french ? "Réglages" : "Settings"
    }

    var dismissButton: String {
        lang == .french ? "Fermer" : "Dismiss"
    }

    // MARK: - Light Indicator Mode
    var clickUnderlinedWordHint: String {
        lang == .french
            ? "Cliquez sur un mot souligné ci-dessous pour voir ou appliquer la correction"
            : "Click any underlined word below to inspect or apply its fix"
    }

    var acceptFixButton: String {
        lang == .french ? "Accepter" : "Accept Fix"
    }

    var ignoreButton: String {
        lang == .french ? "Ignorer" : "Ignore"
    }

    // MARK: - Fine-Grained Editor Mode
    var editableBodyHeader: String {
        lang == .french
            ? "Corps de l'e-mail éditable (cliquez sur un passage souligné ou modifiez librement)"
            : "Editable Email Body (Click any underlined span or edit freely)"
    }

    var charsLabel: String {
        lang == .french ? "caractères" : "chars"
    }

    func suggestionsHeader(count: Int) -> String {
        lang == .french ? "Suggestions détaillées (\(count))" : "Fine-Grained Suggestions (\(count))"
    }

    func acceptAllButton(count: Int) -> String {
        lang == .french ? "Tout accepter (\(count))" : "Accept All (\(count))"
    }

    func allFilter(count: Int) -> String {
        lang == .french ? "Tous (\(count))" : "All (\(count))"
    }

    func analyzingWith(provider: String, model: String) -> String {
        lang == .french
            ? "Analyse en cours avec \(provider) (\(model))..."
            : "Analyzing with \(provider) (\(model))..."
    }

    var noIssuesFoundTitle: String {
        lang == .french ? "Aucune faute d'orthographe ou de grammaire !" : "No spelling or grammar issues found!"
    }

    var noIssuesInCategoryTitle: String {
        lang == .french ? "Aucune faute dans cette catégorie" : "No issues in this category"
    }

    func detectedLanguageSubtitle(flag: String, name: String) -> String {
        lang == .french
            ? "Langue détectée : \(flag) \(name)"
            : "Detected language: \(flag) \(name)"
    }

    // MARK: - Issue Card
    var customizeReplacementTooltip: String {
        lang == .french ? "Modifier la suggestion avant de l'appliquer" : "Customize replacement text before applying"
    }

    var ignoreSuggestionTooltip: String {
        lang == .french ? "Ignorer cette suggestion" : "Ignore this suggestion"
    }

    var replacementPlaceholder: String {
        lang == .french ? "Remplacement" : "Replacement"
    }

    var acceptButton: String {
        lang == .french ? "Accepter" : "Accept"
    }

    var acceptAndUpdateMailButton: String {
        lang == .french ? "Accepter & Maj Mail" : "Accept & Update Mail"
    }

    // MARK: - Bottom Apple Mail Bar
    var pullFromMailButton: String {
        lang == .french ? "Lire depuis Apple Mail" : "Pull from Apple Mail"
    }

    var pullFromMailTooltip: String {
        lang == .french
            ? "Récupérer le texte du brouillon ouvert dans Apple Mail (⌘⇧R)"
            : "Read text from the active Apple Mail compose window (⌘⇧R)"
    }

    var checkingButton: String {
        lang == .french ? "Vérification..." : "Checking..."
    }

    var checkSpellingButton: String {
        lang == .french ? "Vérifier l'orthographe & grammaire" : "Check Spelling & Grammar"
    }

    var applyToMailButton: String {
        lang == .french ? "Appliquer dans Apple Mail" : "Apply to Active Mail Window"
    }

    var applyToMailTooltip: String {
        lang == .french
            ? "Remplacer directement le texte dans la fenêtre de rédaction Apple Mail (⌘⇧A)"
            : "Replace text directly in the active Apple Mail compose window (⌘⇧A)"
    }

    var mailLiveHookActive: String {
        lang == .french ? "Lien Apple Mail actif" : "Mail Live Hook Active"
    }

    var grantAccessibilityPrompt: String {
        lang == .french ? "Autoriser l'Accessibilité pour Mail" : "Grant Accessibility for Auto-Replace"
    }

    var toLabel: String {
        lang == .french ? "À :" : "To:"
    }

    var recipientPlaceholder: String {
        lang == .french ? "Destinataire" : "Recipient email"
    }

    var subjectLabel: String {
        lang == .french ? "Objet :" : "Subject:"
    }

    var subjectPlaceholder: String {
        lang == .french ? "Objet du message" : "Subject"
    }

    var openDraftInMailButton: String {
        lang == .french ? "Ouvrir brouillon Mail" : "Open Draft in Mail"
    }

    var sendInMailButton: String {
        lang == .french ? "Envoyer via Mail" : "Send in Mail"
    }

    // MARK: - Floating Pill & Menu Bar
    var pillCheckMailButton: String {
        lang == .french ? "Lire Mail" : "Check Mail"
    }

    var pillFixAllButton: String {
        lang == .french ? "Tout corriger" : "Fix All"
    }

    func pillCheckingStatus(provider: String) -> String {
        lang == .french ? "Analyse (\(provider))..." : "Checking with \(provider)..."
    }

    var pillNoIssuesStatus: String {
        lang == .french ? "Aucune faute détectée" : "No spelling or grammar issues"
    }

    func pillIssuesCountStatus(_ count: Int) -> String {
        if lang == .french {
            return "\(count) faute\(count == 1 ? "" : "s") · Cliquer pour réviser"
        } else {
            return "\(count) issue\(count == 1 ? "" : "s") · Click to review"
        }
    }

    var menuOpenEditor: String {
        lang == .french ? "Ouvrir l'éditeur Plume" : "Open Plume Editor"
    }

    var menuPullAndCheck: String {
        lang == .french ? "Lire & Vérifier le brouillon Mail actif" : "Pull & Check Active Mail Window"
    }

    func menuAcceptAllAndApply(_ count: Int) -> String {
        lang == .french
            ? "Tout accepter & Appliquer dans Mail (\(count))"
            : "Accept All & Apply to Mail (\(count))"
    }

    var menuSendTestEmail: String {
        lang == .french ? "Ouvrir un nouveau brouillon dans Apple Mail" : "Open New Draft in Apple Mail"
    }

    var menuQuit: String {
        lang == .french ? "Quitter Plume" : "Quit Plume"
    }

    // MARK: - Settings View
    var settingsTitle: String {
        lang == .french
            ? "Plume — Langue, Fournisseurs IA & Intégration Mail"
            : "Plume — Language, AI Providers & Mail Integration"
    }

    var doneButton: String {
        lang == .french ? "Terminé" : "Done"
    }

    var interfaceLanguageSection: String {
        lang == .french ? "Langue de l'interface" : "Interface Language"
    }

    var interfaceLanguageLabel: String {
        lang == .french ? "Langue :" : "Language:"
    }

    var activeProviderSection: String {
        lang == .french ? "Fournisseur LLM & Modèle actif" : "Active LLM Provider & Model"
    }

    var activeProviderLabel: String {
        lang == .french ? "Fournisseur :" : "Active Provider:"
    }

    var modelNameLabel: String {
        lang == .french ? "Modèle :" : "Model Name:"
    }

    var presetsMenu: String {
        lang == .french ? "Modèles" : "Presets"
    }

    var apiKeysSection: String {
        lang == .french ? "Clés API (sauvegardées localement)" : "API Keys (Saved Locally)"
    }

    var ollamaURLField: String {
        lang == .french ? "URL Ollama :" : "Ollama URL:"
    }

    var mailBehaviorSection: String {
        lang == .french ? "Comportement avec Apple Mail" : "Apple Mail Integration"
    }

    var showFloatingPillToggle: String {
        lang == .french
            ? "Afficher la pilule flottante sur les fenêtres Apple Mail"
            : "Show floating Plume pill on Apple Mail windows"
    }

    var autoCheckToggle: String {
        lang == .french
            ? "Vérifier automatiquement après une pause de frappe (1,4 s)"
            : "Automatically re-check after typing pause (1.4s debounce)"
    }

    var accessibilityGrantedStatus: String {
        lang == .french
            ? "Permission Accessibilité accordée (lecture/écriture directe dans Apple Mail active)"
            : "Accessibility Permission Granted (Direct Apple Mail read/write active)"
    }

    var accessibilityNotGrantedStatus: String {
        lang == .french
            ? "Permission Accessibilité non activée (requise pour lire/remplacer dans Mail en 1 clic)"
            : "Accessibility Permission Not Granted Yet (Required for 1-click in-place Mail replacement)"
    }

    var grantPermissionButton: String {
        lang == .french ? "Autoriser l'accès..." : "Grant Permission..."
    }

    // MARK: - Toasts & Status Messages
    func appliedSingleFix(original: String, suggestion: String) -> String {
        lang == .french
            ? "Correction appliquée : « \(original) » → « \(suggestion) »"
            : "Applied: \"\(original)\" → \"\(suggestion)\""
    }

    func appliedMultipleFixes(_ count: Int) -> String {
        if lang == .french {
            return "\(count) correction\(count <= 1 ? "" : "s") appliquée\(count <= 1 ? "" : "s")"
        } else {
            return "Applied \(count) correction\(count == 1 ? "" : "s")"
        }
    }

    func pulledFromMailToast(_ count: Int) -> String {
        lang == .french
            ? "Texte récupéré depuis Apple Mail (\(count) caractères)"
            : "Pulled compose text from Apple Mail (\(count) chars)"
    }

    var replacedInMailToast: String {
        lang == .french
            ? "Texte remplacé directement dans la fenêtre de rédaction Apple Mail !"
            : "Replaced text directly in active Apple Mail compose window!"
    }

    func copiedToClipboardFallback(_ errorDesc: String) -> String {
        lang == .french
            ? "\(errorDesc) (Le texte corrigé a aussi été copié dans le presse-papiers — faites ⌘V dans Mail)."
            : "\(errorDesc) (Text has also been copied to your Clipboard — press ⌘V in Mail)."
    }
}
