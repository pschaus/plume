import Foundation
import SwiftUI

// MARK: - LLM Provider Configuration

enum LLMProvider: String, CaseIterable, Codable, Identifiable {
    case gemini = "Google Gemini"
    case anthropic = "Anthropic Claude"
    case openai = "OpenAI"
    case openrouter = "OpenRouter"
    case ollama = "Ollama (Local)"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .gemini: return "sparkles"
        case .anthropic: return "brain.head.profile"
        case .openai: return "bolt.circle"
        case .openrouter: return "network"
        case .ollama: return "laptopcomputer"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.8-flash"
        case .anthropic: return "claude-3-5-haiku-latest"
        case .openai: return "gpt-4o-mini"
        case .openrouter: return "google/gemini-3.8-flash"
        case .ollama: return "gemma4:latest"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .gemini:
            return ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview"]
        case .anthropic:
            return ["claude-3-5-haiku-latest", "claude-3-7-sonnet-latest"]
        case .openai:
            return ["gpt-4o-mini", "gpt-4o"]
        case .openrouter:
            return [
                "google/gemini-3.8-flash",
                "anthropic/claude-3.5-haiku",
                "openai/gpt-4o-mini",
                "meta-llama/llama-3.3-70b-instruct"
            ]
        case .ollama:
            return ["gemma4:latest", "deepseek-r1:32b", "llama3.2:latest", "mistral:latest"]
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .gemini: return "AIzaSy..."
        case .anthropic: return "sk-ant-..."
        case .openai: return "sk-proj-..."
        case .openrouter: return "sk-or-v1-..."
        case .ollama: return "No API Key Required (Local)"
        }
    }
}

// MARK: - Spell & Grammar Issue Models

enum IssueCategory: String, Codable, CaseIterable, Identifiable {
    case spelling = "spelling"
    case grammar = "grammar"
    case style = "style"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .style: return "Style"
        }
    }

    var color: Color {
        switch self {
        case .spelling: return Color(red: 0.90, green: 0.22, blue: 0.27) // Red
        case .grammar: return Color(red: 0.16, green: 0.50, blue: 0.95)  // Blue
        case .style: return Color(red: 0.94, green: 0.58, blue: 0.10)    // Amber
        }
    }

    var nsColor: NSColor {
        switch self {
        case .spelling: return NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.27, alpha: 1.0)
        case .grammar: return NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.95, alpha: 1.0)
        case .style: return NSColor(calibratedRed: 0.94, green: 0.58, blue: 0.10, alpha: 1.0)
        }
    }

    var badgeIcon: String {
        switch self {
        case .spelling: return "textformat.abc.dottedunderline"
        case .grammar: return "Checkmark.bubble"
        case .style: return "wand.and.stars"
        }
    }
}

struct SpellIssue: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var original: String
    var suggestion: String
    var type: IssueCategory
    var explanation: String

    enum CodingKeys: String, CodingKey {
        case original, suggestion, type, explanation
    }

    init(id: UUID = UUID(), original: String, suggestion: String, type: IssueCategory, explanation: String) {
        self.id = id
        self.original = original
        self.suggestion = suggestion
        self.type = type
        self.explanation = explanation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.original = try container.decode(String.self, forKey: .original)
        self.suggestion = try container.decode(String.self, forKey: .suggestion)
        let rawType = (try? container.decode(String.self, forKey: .type))?.lowercased() ?? "spelling"
        self.type = IssueCategory(rawValue: rawType) ?? .spelling
        self.explanation = (try? container.decode(String.self, forKey: .explanation)) ?? ""
    }
}

struct SpellCheckResult: Codable, Equatable {
    var detectedLanguage: String
    var languageFlag: String
    var issues: [SpellIssue]

    static let empty = SpellCheckResult(detectedLanguage: "Ready", languageFlag: "🌐", issues: [])

    var displayFlag: String {
        let combined = "\(detectedLanguage) \(languageFlag)".lowercased()
        if combined.contains("french") || combined.contains("français") || languageFlag.lowercased() == "fr" || combined.contains("🇫🇷") { return "🇫🇷" }
        if combined.contains("english") || combined.contains("anglais") || languageFlag.lowercased() == "en" || combined.contains("🇬🇧") || combined.contains("🇺🇸") { return "🇬🇧" }
        if combined.contains("spanish") || combined.contains("español") || languageFlag.lowercased() == "es" || combined.contains("🇪🇸") { return "🇪🇸" }
        if combined.contains("german") || combined.contains("deutsch") || languageFlag.lowercased() == "de" || combined.contains("🇩🇪") { return "🇩🇪" }
        if combined.contains("dutch") || combined.contains("nederlands") || languageFlag.lowercased() == "nl" || combined.contains("🇳🇱") { return "🇳🇱" }
        if combined.contains("italian") || combined.contains("italiano") || languageFlag.lowercased() == "it" || combined.contains("🇮🇹") { return "🇮🇹" }
        if combined.contains("portuguese") || combined.contains("português") || languageFlag.lowercased() == "pt" || combined.contains("🇵🇹") { return "🇵🇹" }
        return "🌐"
    }
}

// MARK: - View Mode

enum EditorDisplayMode: String, CaseIterable, Identifiable {
    case lightIndicator = "Light Indicator"
    case fineGrained = "Fine-Grained Editor"

    var id: String { rawValue }
}
