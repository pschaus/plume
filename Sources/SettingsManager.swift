import Foundation
import Combine

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
        }
    }

    var l10n: L10n {
        L10n(lang: appLanguage)
    }

    @Published var selectedProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider")
            if selectedModel.isEmpty || !currentSuggestedModels.contains(selectedModel) {
                selectedModel = selectedProvider.defaultModel
            }
        }
    }

    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "selectedModel_\(selectedProvider.rawValue)")
        }
    }

    @Published var ollamaEndpoint: String {
        didSet {
            UserDefaults.standard.set(ollamaEndpoint, forKey: "ollamaEndpoint")
        }
    }

    @Published var autoCheckInMail: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckInMail, forKey: "autoCheckInMail")
        }
    }

    @Published var showFloatingPill: Bool {
        didSet {
            UserDefaults.standard.set(showFloatingPill, forKey: "showFloatingPill")
        }
    }

    @Published var installedOllamaModels: [String] = []
    @Published private var apiKeys: [LLMProvider: String] = [:]

    private init() {
        let savedLangRaw = UserDefaults.standard.string(forKey: "appLanguage")
        self.appLanguage = AppLanguage(rawValue: savedLangRaw ?? "") ?? .french

        let savedProviderRaw = UserDefaults.standard.string(forKey: "selectedProvider")
        let initialProvider = LLMProvider(rawValue: savedProviderRaw ?? "") ?? .ollama
        self.selectedProvider = initialProvider

        let savedModel = UserDefaults.standard.string(forKey: "selectedModel_\(initialProvider.rawValue)")
        self.selectedModel = savedModel ?? initialProvider.defaultModel

        self.ollamaEndpoint = UserDefaults.standard.string(forKey: "ollamaEndpoint") ?? "http://localhost:11434"
        self.autoCheckInMail = UserDefaults.standard.object(forKey: "autoCheckInMail") as? Bool ?? true
        self.showFloatingPill = UserDefaults.standard.object(forKey: "showFloatingPill") as? Bool ?? true

        // Load API keys from UserDefaults + environment variables fallback
        for provider in LLMProvider.allCases {
            var key = UserDefaults.standard.string(forKey: "apiKey_\(provider.rawValue)") ?? ""
            if key.isEmpty {
                switch provider {
                case .gemini:
                    key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
                        ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"] ?? ""
                case .anthropic:
                    key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
                case .openai:
                    key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
                case .openrouter:
                    key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
                case .ollama:
                    key = ""
                }
            }
            apiKeys[provider] = key
        }

        Task {
            await refreshOllamaModels()
        }
    }

    var currentSuggestedModels: [String] {
        if selectedProvider == .ollama && !installedOllamaModels.isEmpty {
            return installedOllamaModels
        }
        return selectedProvider.suggestedModels
    }

    func apiKey(for provider: LLMProvider) -> String {
        apiKeys[provider] ?? ""
    }

    func setAPIKey(_ key: String, for provider: LLMProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeys[provider] = trimmed
        UserDefaults.standard.set(trimmed, forKey: "apiKey_\(provider.rawValue)")
        objectWillChange.send()
    }

    func selectProvider(_ provider: LLMProvider) {
        selectedProvider = provider
        let savedModel = UserDefaults.standard.string(forKey: "selectedModel_\(provider.rawValue)")
        if let savedModel, !savedModel.isEmpty {
            selectedModel = savedModel
        } else if provider == .ollama, let first = installedOllamaModels.first {
            selectedModel = first
        } else {
            selectedModel = provider.defaultModel
        }
    }

    func refreshOllamaModels() async {
        guard let url = URL(string: "\(ollamaEndpoint)/api/tags") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }
                if !names.isEmpty {
                    self.installedOllamaModels = names
                    if self.selectedProvider == .ollama && !names.contains(self.selectedModel) {
                        self.selectedModel = names.first(where: { $0.contains("gemma") }) ?? names[0]
                    }
                }
            }
        } catch {
            // Keep default suggestions if Ollama is offline
        }
    }
}
