import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var mailService: MailIntegrationService
    @ObservedObject var updateService: UpdateCheckerService = .shared
    @Environment(\.dismiss) private var dismiss

    @State private var geminiKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var openaiKey: String = ""
    @State private var openrouterKey: String = ""

    private var l10n: L10n { settings.l10n }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PlumeLogoView(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.settingsTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Plume v\(updateService.currentVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await updateService.checkForUpdates(manual: true)
                    }
                } label: {
                    if updateService.isCheckingForUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            settings.appLanguage == .french ? "Vérifier les mises à jour" : "Check for Updates",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(l10n.doneButton) {
                    saveAllKeys()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            if let upToDateMsg = updateService.lastCheckUpToDateMessage {
                Text(upToDateMsg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 0.14, green: 0.62, blue: 0.42))
            }

            Divider()

            // Interface Language Selection
            GroupBox(label: Label(l10n.interfaceLanguageSection, systemImage: "globe")) {
                HStack {
                    Text(l10n.interfaceLanguageLabel)
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text("\(lang.shortBadge) — \(lang.displayName)").tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Spacer()
                }
                .padding(8)
            }

            // Active Provider & Model Selection
            GroupBox(label: Label(l10n.activeProviderSection, systemImage: "cpu")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(l10n.activeProviderLabel)
                            .frame(width: 130, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { settings.selectedProvider },
                            set: { settings.selectProvider($0) }
                        )) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }

                    HStack {
                        Text(l10n.modelNameLabel)
                            .frame(width: 130, alignment: .leading)

                        TextField("Model ID", text: $settings.selectedModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)

                        Menu(l10n.presetsMenu) {
                            ForEach(settings.currentSuggestedModels, id: \.self) { m in
                                Button(m) {
                                    settings.selectedModel = m
                                }
                            }
                        }
                        .frame(width: 100)

                        if settings.selectedProvider == .ollama {
                            Button {
                                Task {
                                    await settings.refreshOllamaModels()
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh installed Ollama models")
                        }
                    }
                }
                .padding(8)
            }

            // Cloud API Keys
            GroupBox(label: Label(l10n.apiKeysSection, systemImage: "key.fill")) {
                VStack(alignment: .leading, spacing: 10) {
                    apiKeyRow(title: "Google Gemini:", placeholder: LLMProvider.gemini.apiKeyPlaceholder, text: $geminiKey)
                    apiKeyRow(title: "Anthropic Claude:", placeholder: LLMProvider.anthropic.apiKeyPlaceholder, text: $anthropicKey)
                    apiKeyRow(title: "OpenAI:", placeholder: LLMProvider.openai.apiKeyPlaceholder, text: $openaiKey)
                    apiKeyRow(title: "OpenRouter:", placeholder: LLMProvider.openrouter.apiKeyPlaceholder, text: $openrouterKey)

                    HStack {
                        Text(l10n.ollamaURLField)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 130, alignment: .leading)
                        TextField("http://localhost:11434", text: $settings.ollamaEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(8)
            }

            // Apple Mail Overlay & Accessibility Settings
            GroupBox(label: Label(l10n.mailBehaviorSection, systemImage: "envelope.badge")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(l10n.showFloatingPillToggle, isOn: $settings.showFloatingPill)
                    Toggle(l10n.autoCheckToggle, isOn: $settings.autoCheckInMail)

                    Divider()

                    HStack {
                        Circle()
                            .fill(mailService.isAccessibilityTrusted ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(mailService.isAccessibilityTrusted
                             ? l10n.accessibilityGrantedStatus
                             : l10n.accessibilityNotGrantedStatus)
                            .font(.system(size: 12))
                        Spacer()
                        if !mailService.isAccessibilityTrusted {
                            Button(l10n.grantPermissionButton) {
                                mailService.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(8)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            geminiKey = settings.apiKey(for: .gemini)
            anthropicKey = settings.apiKey(for: .anthropic)
            openaiKey = settings.apiKey(for: .openai)
            openrouterKey = settings.apiKey(for: .openrouter)
        }
    }

    private func apiKeyRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 130, alignment: .leading)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { _, _ in
                    saveAllKeys()
                }
        }
    }

    private func saveAllKeys() {
        settings.setAPIKey(geminiKey, for: .gemini)
        settings.setAPIKey(anthropicKey, for: .anthropic)
        settings.setAPIKey(openaiKey, for: .openai)
        settings.setAPIKey(openrouterKey, for: .openrouter)
    }
}
