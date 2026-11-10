import AppKit
import SwiftUI

@main
struct PlumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = SpellCheckerViewModel.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var mailService = MailIntegrationService.shared

    var body: some Scene {
        WindowGroup(settings.l10n.windowTitle) {
            MainEditorView(
                viewModel: viewModel,
                settings: settings,
                mailService: mailService
            )
            .onAppear {
                let openMain: () -> Void = {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                FloatingPillController.shared.onOpenMainEditor = openMain
                MailInlineOverlayController.shared.onOpenMainEditor = openMain
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu Bar Icon
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("Plume (\(settings.selectedProvider.rawValue))")
                    .font(.headline)
                Text(settings.l10n.detectedLanguageSubtitle(
                    flag: viewModel.result.displayFlag,
                    name: settings.l10n.localizedDetectedLanguage(viewModel.result.detectedLanguage)
                ))
                .font(.caption)

                Divider()

                Button(settings.l10n.menuOpenEditor) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .keyboardShortcut("o")

                Button(settings.l10n.menuPullAndCheck) {
                    Task {
                        await viewModel.pullFromMailAndCheck()
                    }
                }
                .keyboardShortcut("r")

                if !viewModel.result.issues.isEmpty {
                    Button(settings.l10n.menuAcceptAllAndApply(viewModel.result.issues.count)) {
                        viewModel.acceptAll(syncToMail: true)
                    }
                }

                Divider()

                Button(settings.l10n.menuSendTestEmail) {
                    viewModel.openOrSendInMail(sendImmediately: false)
                }

                Divider()

                Button(settings.l10n.menuQuit) {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "wand.and.stars")
                if !viewModel.result.issues.isEmpty {
                    Text("\(viewModel.result.issues.count)")
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set Dock & App Switcher Icon explicitly
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        } else if let logoURL = Bundle.main.url(forResource: "PlumeLogo", withExtension: "png"),
                  let logoImage = NSImage(contentsOf: logoURL) {
            NSApp.applicationIconImage = logoImage
        }

        // Register macOS System Service provider (Right-click -> Services in Apple Mail)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Prompt for Accessibility permission on launch if not yet granted
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        // Start monitoring Apple Mail window position & text
        MailIntegrationService.shared.startMonitoring { newMailText in
            if SettingsManager.shared.autoCheckInMail && !SpellCheckerViewModel.shared.isChecking {
                SpellCheckerViewModel.shared.text = newMailText
                SpellCheckerViewModel.shared.scheduleDebouncedCheck(delayNanoseconds: 2_200_000_000)
            }
        }

        // Trigger Floating Pill & In-Mail Inline Underline Overlay initialization
        _ = FloatingPillController.shared
        _ = MailInlineOverlayController.shared

        if CommandLine.arguments.contains("--mode=light") {
            SpellCheckerViewModel.shared.displayMode = .lightIndicator
        } else if CommandLine.arguments.contains("--mode=fine") {
            SpellCheckerViewModel.shared.displayMode = .fineGrained
        }
        SpellCheckerViewModel.shared.selectedIssueID = SpellCheckerViewModel.shared.result.issues.first?.id

        // Check for updates on launch (sample text is already pre-checked so we don't block Ollama at startup)
        Task {
            await UpdateCheckerService.shared.checkForUpdates(manual: false)
        }
    }

    // MARK: - macOS System Service Handler (`NSServices` in Info.plist)
    @objc func checkSelectionWithAI(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let selectedText = pboard.string(forType: .string),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        SpellCheckerViewModel.shared.text = selectedText
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }

        Task {
            await SpellCheckerViewModel.shared.runSpellCheck()
        }
    }
}
