import AppKit
import ApplicationServices
import Foundation

enum MailIntegrationError: LocalizedError {
    case accessibilityNotGranted
    case mailNotRunning
    case noComposeWindowFound
    case emptyComposeBody

    var errorDescription: String? {
        let isFr = (UserDefaults.standard.string(forKey: "appLanguage") ?? "fr") == "fr"
        switch self {
        case .accessibilityNotGranted:
            return isFr
                ? "La permission Accessibilité est requise pour lire/modifier Apple Mail directement. Activez « Plume » dans Réglages Système → Confidentialité et sécurité → Accessibilité."
                : "Accessibility permission is required to read/write Apple Mail directly. Please enable 'Plume' in System Settings → Privacy & Security → Accessibility."
        case .mailNotRunning:
            return isFr
                ? "Apple Mail n'est pas ouvert actuellement."
                : "Apple Mail is not currently running."
        case .noComposeWindowFound:
            return isFr
                ? "Aucune fenêtre de rédaction d'e-mail ouverte trouvée dans Apple Mail. Ouvrez un nouveau message ou une réponse dans Mail."
                : "No open email compose window found in Apple Mail. Please open a New Message or Reply window in Mail."
        case .emptyComposeBody:
            return isFr
                ? "Le corps du message dans la fenêtre de rédaction Apple Mail semble vide."
                : "The Apple Mail compose window body appears to be empty."
        }
    }
}

@MainActor
final class MailIntegrationService: ObservableObject {
    static let shared = MailIntegrationService()

    @Published var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published var isMailRunning: Bool = false
    @Published var isMailFrontmost: Bool = false
    @Published var mailWindowFrame: CGRect? = nil
    @Published var lastCapturedMailText: String = ""

    private var monitorTimer: Timer?

    private init() {
        refreshStatus()
    }

    func startMonitoring(onMailTextChanged: @escaping @MainActor @Sendable (String) -> Void) {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatus()
                if self.isMailFrontmost && self.isAccessibilityTrusted {
                    if let text = self.readComposeTextFastViaAXTree(),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       text != self.lastCapturedMailText {
                        self.lastCapturedMailText = text
                        onMailTextChanged(text)
                    }
                }
            }
        }
    }

    func refreshStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()

        let runningApps = NSWorkspace.shared.runningApplications
        let mailApp = runningApps.first(where: { $0.bundleIdentifier == "com.apple.mail" })
        isMailRunning = (mailApp != nil)

        let frontApp = NSWorkspace.shared.frontmostApplication
        let ourBundleID = Bundle.main.bundleIdentifier
        isMailFrontmost = (frontApp?.bundleIdentifier == "com.apple.mail")
            || (frontApp?.bundleIdentifier == ourBundleID && mailWindowFrame != nil)

        if let pid = mailApp?.processIdentifier {
            mailWindowFrame = findMailWindowFrame(pid: pid)
        } else {
            mailWindowFrame = nil
        }
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: - Window Frame Detection

    private func findMailWindowFrame(pid: pid_t) -> CGRect? {
        if isAccessibilityTrusted {
            let appElem = AXUIElementCreateApplication(pid)
            if let (composeWin, _) = findComposeWindowAndWebArea(in: appElem),
               let rect = axFrame(of: composeWin),
               rect.width > 250, rect.height > 200 {
                return convertQuartzToCocoaScreenRect(rect)
            }
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            if w > 300 && h > 220 {
                let quartzRect = CGRect(x: x, y: y, width: w, height: h)
                return convertQuartzToCocoaScreenRect(quartzRect)
            }
        }
        return nil
    }

    private func convertQuartzToCocoaScreenRect(_ quartzRect: CGRect) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let cocoaY = primaryScreenHeight - (quartzRect.origin.y + quartzRect.size.height)
        return CGRect(x: quartzRect.origin.x, y: cocoaY, width: quartzRect.size.width, height: quartzRect.size.height)
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pVal = posRef,
              let sVal = sizeRef else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sVal as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    // MARK: - Locate Apple Mail's Compose Window & Editable AXWebArea

    /// Finds the active Compose Window and its editable body (`AXWebArea` or `AXTextArea`) in Apple Mail,
    /// carefully ignoring the read-only Main Inbox Viewer window.
    private func findComposeWindowAndWebArea(in appElem: AXUIElement) -> (window: AXUIElement, webArea: AXUIElement)? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        // First pass: look for a dedicated Compose window (has an AXWebArea, and does NOT have a mailbox AXOutline)
        for win in windows {
            let hasMailboxOutline = containsRole(in: win, role: "AXOutline", maxDepth: 6)
            if !hasMailboxOutline,
               let webArea = findEditableWebArea(in: win, maxDepth: 14) {
                return (win, webArea)
            }
        }

        // Second pass: check any window for an explicitly editable AXWebArea
        for win in windows {
            if let webArea = findEditableWebArea(in: win, requireExplicitEditableAttr: true, maxDepth: 14) {
                return (win, webArea)
            }
        }

        // Third pass: fallback to any window that has a web area
        for win in windows {
            if let webArea = findEditableWebArea(in: win, maxDepth: 14) {
                return (win, webArea)
            }
        }

        return nil
    }

    private func containsRole(in root: AXUIElement, role targetRole: String, maxDepth: Int) -> Bool {
        guard maxDepth >= 0 else { return false }
        if axStringAttribute(root, kAXRoleAttribute) == targetRole {
            return true
        }
        for child in axChildren(of: root) {
            if containsRole(in: child, role: targetRole, maxDepth: maxDepth - 1) {
                return true
            }
        }
        return false
    }

    private func findEditableWebArea(
        in root: AXUIElement,
        requireExplicitEditableAttr: Bool = false,
        maxDepth: Int
    ) -> AXUIElement? {
        guard maxDepth >= 0 else { return nil }
        let role = axStringAttribute(root, kAXRoleAttribute) ?? ""

        if role == "AXWebArea" {
            if requireExplicitEditableAttr {
                if axBoolAttribute(root, "AXEditable") == true {
                    return root
                }
            } else {
                return root
            }
        }

        for child in axChildren(of: root) {
            if let found = findEditableWebArea(
                in: child,
                requireExplicitEditableAttr: requireExplicitEditableAttr,
                maxDepth: maxDepth - 1
            ) {
                return found
            }
        }
        return nil
    }

    // MARK: - 1. Pull Text from Active Apple Mail Compose Window

    func pullTextFromMail() async -> Result<String, MailIntegrationError> {
        refreshStatus()
        guard isAccessibilityTrusted else {
            requestAccessibilityPermission()
            return .failure(.accessibilityNotGranted)
        }

        guard let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            return .failure(.mailNotRunning)
        }

        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        guard let (composeWin, webArea) = findComposeWindowAndWebArea(in: appElem) else {
            return .failure(.noComposeWindowFound)
        }

        // Path A: Try fast non-intrusive AX tree extraction from the compose `AXWebArea`
        if let treeText = extractStructuredTextFromWebArea(webArea),
           !treeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.lastCapturedMailText = treeText
            return .success(treeText)
        }

        // Path B: Focus the compose `AXWebArea` in Mail and trigger Mail's native Select All (⌘A) + Copy (⌘C)
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        let initialChangeCount = NSPasteboard.general.changeCount

        mailApp.activate()
        _ = AXUIElementPerformAction(composeWin, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(composeWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Try reading again now that WebKit's AXWebArea is focused
        if let focusedTreeText = extractStructuredTextFromWebArea(webArea),
           !focusedTreeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            self.lastCapturedMailText = focusedTreeText
            return .success(focusedTreeText)
        }

        // Trigger Select All (⌘A) and Copy (⌘C) via Apple Mail's Menu Bar
        if !pressMenuItem(in: appElem, cmdChar: "A") {
            sendKeystroke(keyCode: 0, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        if !pressMenuItem(in: appElem, cmdChar: "C") {
            sendKeystroke(keyCode: 8, flags: .maskCommand) // Cmd+C
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Clear selection by pressing Right Arrow
        sendKeystroke(keyCode: 124, flags: [])

        NSApp.activate(ignoringOtherApps: true)

        if NSPasteboard.general.changeCount != initialChangeCount,
           let copied = NSPasteboard.general.string(forType: .string),
           !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Restore previous clipboard if needed
            self.lastCapturedMailText = copied
            return .success(copied)
        }

        if let previousClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previousClipboard, forType: .string)
        }

        return .failure(.emptyComposeBody)
    }

    func readComposeTextFastViaAXTree() -> String? {
        guard isAccessibilityTrusted,
              let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            return nil
        }
        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        guard let (_, webArea) = findComposeWindowAndWebArea(in: appElem) else {
            return nil
        }
        return extractStructuredTextFromWebArea(webArea)
    }

    /// Reconstructs multi-paragraph text from WebKit's `AXWebArea`.
    private func extractStructuredTextFromWebArea(_ webArea: AXUIElement) -> String? {
        // 1. Check direct kAXValueAttribute on webArea if non-empty
        if let directVal = axStringAttribute(webArea, kAXValueAttribute),
           !directVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directVal
        }

        // 2. Walk child groups/paragraphs of `AXWebArea`
        let topChildren = axChildren(of: webArea)
        if !topChildren.isEmpty {
            var paragraphs: [String] = []
            for child in topChildren {
                var inlineFragments: [String] = []
                collectLeafText(from: child, into: &inlineFragments, maxDepth: 12)
                let line = inlineFragments.joined()
                paragraphs.append(line)
            }
            let result = paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty {
                return result
            }
        }

        return nil
    }

    private func collectLeafText(from element: AXUIElement, into fragments: inout [String], maxDepth: Int) {
        guard maxDepth >= 0 else { return }
        let role = axStringAttribute(element, kAXRoleAttribute) ?? ""

        if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
            if let val = axStringAttribute(element, kAXValueAttribute), !val.isEmpty {
                fragments.append(val)
                return
            }
        }

        for child in axChildren(of: element) {
            collectLeafText(from: child, into: &fragments, maxDepth: maxDepth - 1)
        }
    }

    // MARK: - 2. Apply Corrected Text Directly to Active Apple Mail Compose Window

    func applyCorrectedTextToMail(_ correctedText: String) async -> Result<Void, MailIntegrationError> {
        refreshStatus()

        // Always copy to clipboard first
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(correctedText, forType: .string)
        self.lastCapturedMailText = correctedText

        guard isAccessibilityTrusted else {
            requestAccessibilityPermission()
            return .failure(.accessibilityNotGranted)
        }

        guard let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            return .failure(.mailNotRunning)
        }

        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        guard let (composeWin, webArea) = findComposeWindowAndWebArea(in: appElem) else {
            return .failure(.noComposeWindowFound)
        }

        // 1. Activate Apple Mail and raise the Compose Window
        mailApp.activate()
        _ = AXUIElementPerformAction(composeWin, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(composeWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(composeWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 180_000_000)

        // 2. Focus the editable `AXWebArea` (email body) explicitly so we NEVER paste into Subject/To!
        _ = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 120_000_000)

        // 3. Select All (⌘A) inside `webArea` using Mail's native Menu Bar item
        if !pressMenuItem(in: appElem, cmdChar: "A") {
            sendKeystroke(keyCode: 0, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 4. Paste (⌘V) the corrected text from NSPasteboard using Mail's native Menu Bar item
        if !pressMenuItem(in: appElem, cmdChar: "V") {
            sendKeystroke(keyCode: 9, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        return .success(())
    }

    // MARK: - Language-Independent Menu Item Invoker (`AXMenuItemCmdChar`)

    /// Finds a menu bar item in the target application by its keyboard shortcut character (e.g. "A", "C", "V")
    /// with default Command modifier (0) and triggers `kAXPressAction`. Works in French, English, and all locales!
    private func pressMenuItem(in appElem: AXUIElement, cmdChar: String) -> Bool {
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return false
        }
        let axMenuBar = menuBar as! AXUIElement
        guard let item = findMenuItem(in: axMenuBar, cmdChar: cmdChar.uppercased(), maxDepth: 5) else {
            return false
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func findMenuItem(in element: AXUIElement, cmdChar: String, maxDepth: Int) -> AXUIElement? {
        guard maxDepth >= 0 else { return nil }
        if axStringAttribute(element, kAXRoleAttribute) == "AXMenuItem" {
            if let char = axStringAttribute(element, "AXMenuItemCmdChar")?.uppercased(),
               char == cmdChar {
                // Ensure modifiers == 0 (pure Command key, not Cmd+Shift or Cmd+Option)
                let mods = axIntAttribute(element, "AXMenuItemCmdModifiers") ?? 0
                let enabled = axBoolAttribute(element, kAXEnabledAttribute) ?? true
                if mods == 0 && enabled {
                    return element
                }
            }
        }
        for child in axChildren(of: element) {
            if let found = findMenuItem(in: child, cmdChar: cmdChar, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - Low-Level AX Attribute Helpers

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else {
            return []
        }
        return arr
    }

    private func axStringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func axBoolAttribute(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? Bool
    }

    private func axIntAttribute(_ element: AXUIElement, _ attr: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? Int
    }

    private func sendKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Open / Send Draft in Apple Mail

    func openDraftInAppleMail(recipient: String, subject: String, body: String, sendImmediately: Bool = false) {
        if sendImmediately {
            let escapedRecipient = recipient.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedSubject = subject.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

            let scriptSource = """
            tell application "Mail"
                activate
                set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
                tell newMessage
                    make new to recipient at end of to recipients with properties {address:"\(escapedRecipient)"}
                    send
                end tell
            end tell
            """
            var errorDict: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&errorDict)
                if errorDict == nil {
                    return
                }
            }
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
