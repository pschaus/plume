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

// MARK: - Rich HTML, Quote & Formatting Preserver for Apple Mail

struct MailHTMLPreserver {
    struct CharMap {
        let visibleChar: Character
        let htmlRange: Range<String.Index>
    }

    static func isAttributionLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(">") { return true }
        if trimmed.hasPrefix("-----Original Message-----") || trimmed.hasPrefix("-------- Message transféré") {
            return true
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("début du message réexpédié") || lower.hasPrefix("begin forwarded message") {
            return true
        }
        if trimmed.hasSuffix(":") {
            let prefixes = ["le ", "on ", "am ", "el ", "op ", "il "]
            let suffixes = ["a écrit :", "a écrit:", "wrote:", "schrieb:", "escribió:", "schreef:", "ha scritto:"]
            if prefixes.contains(where: { lower.hasPrefix($0) }) && suffixes.contains(where: { lower.hasSuffix($0) }) {
                return true
            }
        }
        return false
    }

    /// Splits a plain-text email draft into `(replyText, quotedSuffix)`, leaving out signatures and quoted replies.
    static func splitMailPlainText(_ fullText: String) -> (replyText: String, quotedSuffix: String) {
        let lines = fullText.components(separatedBy: "\n")
        var splitLineIdx: Int? = nil
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isAttributionLine(trimmed) || trimmed == "--" || line == "-- " {
                splitLineIdx = i
                break
            }
            if i + 1 < lines.count {
                let combined = trimmed + " " + lines[i + 1].trimmingCharacters(in: .whitespaces)
                if isAttributionLine(combined) {
                    splitLineIdx = i
                    break
                }
            }
            i += 1
        }
        guard let idx = splitLineIdx else {
            return (fullText.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let reply = lines[..<idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = lines[idx...].joined(separator: "\n")
        return (reply, quoted)
    }

    /// Splits Apple Mail's compose HTML into `(replyHTML, quotedHTML)` so that signatures,
    /// attribution headers ("On ... wrote:" / "Le ... a écrit :"), and `<blockquote type="cite">`
    /// remain 100% untouched.
    static func splitMailHTML(_ html: String) -> (replyHTML: String, quotedHTML: String) {
        let markers = [
            "id=\"AppleMailSignature\"",
            "id='AppleMailSignature'",
            "class=\"AppleMailSignature\"",
            "class='AppleMailSignature'",
            "class=\"AppleOriginalContents\"",
            "class='AppleOriginalContents'",
            "id=\"AppleOriginalContents\"",
            "id='AppleOriginalContents'",
            "<blockquote"
        ]

        var earliestTagStart: String.Index? = nil
        let lowerHTML = html.lowercased()

        for marker in markers {
            let lowerMarker = marker.lowercased()
            if let range = lowerHTML.range(of: lowerMarker) {
                var tagStart = range.lowerBound
                if !lowerMarker.hasPrefix("<") {
                    if let openBracket = lowerHTML[..<tagStart].lastIndex(of: "<") {
                        tagStart = openBracket
                    }
                }
                if earliestTagStart == nil || tagStart < earliestTagStart! {
                    earliestTagStart = tagStart
                }
            }
        }

        guard var splitIndex = earliestTagStart else {
            return (html, "")
        }

        // If splitting at <blockquote, check if the preceding visible line(s) in HTML are the attribution header
        // ("Le ... a écrit :" / "On ... wrote:") and include them in `quotedHTML` so they aren't spell-checked or lost.
        if lowerHTML[splitIndex...].hasPrefix("<blockquote") {
            let prefixHTML = String(html[..<splitIndex])
            let (visiblePrefix, mapPrefix) = buildVisibleMap(html: prefixHTML)
            let (_, quotedPlainSuffix) = splitMailPlainText(visiblePrefix)
            if !quotedPlainSuffix.isEmpty,
               let attrRange = visiblePrefix.range(of: quotedPlainSuffix, options: .backwards) {
                let charStartOffset = visiblePrefix.distance(from: visiblePrefix.startIndex, to: attrRange.lowerBound)
                if charStartOffset < mapPrefix.count {
                    var attrHTMLStart = mapPrefix[charStartOffset].htmlRange.lowerBound
                    // Walk back across any immediately enclosing inline/block opening tag (e.g. <div>)
                    let lookbehindStart = html.index(attrHTMLStart, offsetBy: -120, limitedBy: html.startIndex) ?? html.startIndex
                    let beforeAttr = html[lookbehindStart..<attrHTMLStart]
                    if let lastOpenTag = beforeAttr.range(of: "<div", options: [.caseInsensitive, .backwards]) {
                        let between = beforeAttr[lastOpenTag.lowerBound...]
                        if !between.contains("</div>") {
                            attrHTMLStart = lastOpenTag.lowerBound
                        }
                    }
                    splitIndex = attrHTMLStart
                }
            }
        }

        return (String(html[..<splitIndex]), String(html[splitIndex...]))
    }

    static func bodyContentStartIndex(in html: String) -> String.Index {
        if let bodyRange = html.range(of: "<body", options: .caseInsensitive),
           let closeBracket = html[bodyRange.lowerBound...].firstIndex(of: ">") {
            return html.index(after: closeBracket)
        }
        if let headEndRange = html.range(of: "</head>", options: .caseInsensitive) {
            return headEndRange.upperBound
        }
        return html.startIndex
    }

    static func buildVisibleMap(html: String) -> (visibleText: String, map: [CharMap]) {
        var visible = ""
        var map: [CharMap] = []
        var i = bodyContentStartIndex(in: html)
        var lastWasBR = false

        while i < html.endIndex {
            let c = html[i]
            if c == "<" {
                if let closeIdx = html[i...].firstIndex(of: ">") {
                    let tagContent = html[html.index(after: i)..<closeIdx].lowercased()
                    let tagName = tagContent.split(separator: " ").first ?? Substring(tagContent)
                    let nextIdx = html.index(after: closeIdx)
                    if tagName == "br" || tagName == "br/" {
                        visible.append("\n")
                        map.append(CharMap(visibleChar: "\n", htmlRange: i..<nextIdx))
                        lastWasBR = true
                    } else if tagName == "/div" || tagName == "/p" || tagName == "/li" {
                        if !lastWasBR && !visible.isEmpty {
                            visible.append("\n")
                            map.append(CharMap(visibleChar: "\n", htmlRange: i..<i))
                        }
                        lastWasBR = false
                    }
                    i = nextIdx
                    continue
                }
            } else if c == "&" {
                let maxEnd = html.index(i, offsetBy: 10, limitedBy: html.endIndex) ?? html.endIndex
                if let semiIdx = html[i..<maxEnd].firstIndex(of: ";") {
                    let entity = String(html[i...semiIdx])
                    let nextIdx = html.index(after: semiIdx)
                    let decoded: Character?
                    switch entity.lowercased() {
                    case "&nbsp;", "&#160;": decoded = " "
                    case "&amp;", "&#38;": decoded = "&"
                    case "&lt;", "&#60;": decoded = "<"
                    case "&gt;", "&#62;": decoded = ">"
                    case "&quot;", "&#34;": decoded = "\""
                    case "&apos;", "&#39;", "&rsquo;", "&lsquo;": decoded = "'"
                    default: decoded = nil
                    }
                    if let d = decoded {
                        visible.append(d)
                        map.append(CharMap(visibleChar: d, htmlRange: i..<nextIdx))
                        lastWasBR = false
                        i = nextIdx
                        continue
                    }
                }
            } else if c == "\r" || c == "\n" {
                i = html.index(after: i)
                continue
            }

            let nextIdx = html.index(after: i)
            visible.append(c)
            map.append(CharMap(visibleChar: c, htmlRange: i..<nextIdx))
            lastWasBR = false
            i = nextIdx
        }

        return (visible, map)
    }

    static func tokenize(_ text: String) -> [(token: String, charStart: Int, charEnd: Int)] {
        var result: [(String, Int, Int)] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let start = i
            let c = chars[i]
            if c.isLetter || c.isNumber {
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber) { i += 1 }
            } else if c.isWhitespace {
                while i < chars.count && chars[i].isWhitespace { i += 1 }
            } else {
                i += 1
            }
            result.append((String(chars[start..<i]), start, i))
        }
        return result
    }

    static func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Projects updated plain text onto `replyHTML` using token-level LCS diffing,
    /// preserving inline formatting (`<b>`, `<i>`, `<u>`, `<a href>`, `<span style>`, lists, etc.).
    static func applyUpdatedText(to replyHTML: String, newPlainText: String) -> String {
        let (oldVisibleRaw, map) = buildVisibleMap(html: replyHTML)
        let oldTrimmed = oldVisibleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldTrimmed == newTrimmed {
            return replyHTML
        }

        if map.isEmpty || oldTrimmed.isEmpty {
            let escaped = "<div>" + escapeHTML(newTrimmed) + "</div>"
            let insertPos = bodyContentStartIndex(in: replyHTML)
            var res = replyHTML
            res.insert(contentsOf: escaped, at: insertPos)
            return res
        }

        let oldTokens = tokenize(oldVisibleRaw)
        let newTokens = tokenize(newTrimmed)

        let n = oldTokens.count
        let m = newTokens.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if oldTokens[i].token == newTokens[j].token {
                    dp[i][j] = 1 + dp[i + 1][j + 1]
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var matches: [(oldIdx: Int, newIdx: Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if oldTokens[i].token == newTokens[j].token {
                matches.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var ops: [(oldRange: Range<Int>, newRange: Range<Int>)] = []
        var prevOld = 0
        var prevNew = 0
        for match in matches {
            if match.oldIdx > prevOld || match.newIdx > prevNew {
                ops.append((prevOld..<match.oldIdx, prevNew..<match.newIdx))
            }
            prevOld = match.oldIdx + 1
            prevNew = match.newIdx + 1
        }
        if prevOld < n || prevNew < m {
            ops.append((prevOld..<n, prevNew..<m))
        }

        var resultHTML = replyHTML
        for op in ops.reversed() {
            let oldSlice = op.oldRange.map { oldTokens[$0].token }.joined()
            let newReplacement = op.newRange.map { newTokens[$0].token }.joined()

            // Preserve leading/trailing whitespace & linebreaks in HTML structure
            if (op.oldRange.lowerBound == 0 || op.oldRange.upperBound == n)
                && oldSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            // Preserve internal whitespace if both are pure whitespace with same newline count
            if !oldSlice.isEmpty && !newReplacement.isEmpty
                && oldSlice.allSatisfy(\.isWhitespace) && newReplacement.allSatisfy(\.isWhitespace)
                && oldSlice.filter({ $0 == "\n" }).count == newReplacement.filter({ $0 == "\n" }).count {
                continue
            }

            let htmlReplaceRange: Range<String.Index>
            if op.oldRange.isEmpty {
                if op.oldRange.lowerBound < n {
                    let charIdx = oldTokens[op.oldRange.lowerBound].charStart
                    let pos = map[charIdx].htmlRange.lowerBound
                    htmlReplaceRange = pos..<pos
                } else if let lastNonWS = oldTokens.last(where: { !$0.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    let pos = map[lastNonWS.charEnd - 1].htmlRange.upperBound
                    htmlReplaceRange = pos..<pos
                } else if let lastMap = map.last {
                    let pos = lastMap.htmlRange.upperBound
                    htmlReplaceRange = pos..<pos
                } else {
                    htmlReplaceRange = resultHTML.endIndex..<resultHTML.endIndex
                }
            } else {
                let firstCharIdx = oldTokens[op.oldRange.lowerBound].charStart
                let lastCharIdx = oldTokens[op.oldRange.upperBound - 1].charEnd - 1
                let startPos = map[firstCharIdx].htmlRange.lowerBound
                let endPos = map[lastCharIdx].htmlRange.upperBound
                htmlReplaceRange = startPos..<endPos
            }

            resultHTML.replaceSubrange(htmlReplaceRange, with: escapeHTML(newReplacement))
        }

        return resultHTML
    }

    static func extractHTMLFromWebArchive(_ archiveData: Data?) -> String? {
        guard let archiveData,
              let plist = try? PropertyListSerialization.propertyList(from: archiveData, options: [], format: nil) as? [String: Any],
              let mainResource = plist["WebMainResource"] as? [String: Any],
              let htmlData = mainResource["WebResourceData"] as? Data,
              let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }
        return html
    }

    static func updateHTMLInWebArchive(_ archiveData: Data, newHTML: String) -> Data? {
        guard var plist = try? PropertyListSerialization.propertyList(from: archiveData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any],
              var mainResource = plist["WebMainResource"] as? [String: Any],
              let newHTMLData = newHTML.data(using: .utf8) else {
            return nil
        }
        mainResource["WebResourceData"] = newHTMLData
        plist["WebMainResource"] = mainResource
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
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

    private var lastCapturedFullHTML: String? = nil
    private var lastCapturedWebArchiveData: Data? = nil
    private var lastCapturedFullPlainText: String? = nil

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

    private func findComposeWindowAndWebArea(in appElem: AXUIElement) -> (window: AXUIElement, webArea: AXUIElement)? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        for win in windows {
            let hasMailboxOutline = containsRole(in: win, role: "AXOutline", maxDepth: 6)
            if !hasMailboxOutline,
               let webArea = findEditableWebArea(in: win, maxDepth: 14) {
                return (win, webArea)
            }
        }

        for win in windows {
            if let webArea = findEditableWebArea(in: win, requireExplicitEditableAttr: true, maxDepth: 14) {
                return (win, webArea)
            }
        }

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

    // MARK: - Pasteboard Snapshot Helpers

    private func savePasteboardSnapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        let pb = NSPasteboard.general
        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var itemDict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemDict[type] = data
                }
            }
            if !itemDict.isEmpty {
                snapshot.append(itemDict)
            }
        }
        return snapshot
    }

    private func restorePasteboardSnapshot(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: - 1. Pull Text from Active Apple Mail Compose Window (Excluding Quoted Thread)

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

        // Save user's clipboard before copying rich HTML/WebArchive from Mail
        let savedClipboard = savePasteboardSnapshot()
        let initialChangeCount = NSPasteboard.general.changeCount

        mailApp.activate()
        _ = AXUIElementPerformAction(composeWin, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(composeWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 140_000_000)

        _ = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 90_000_000)

        // Select All (⌘A) and Copy (⌘C) to capture both HTML/WebArchive and Plain Text
        if !pressMenuItem(in: appElem, cmdChar: "A") {
            sendKeystroke(keyCode: 0, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 90_000_000)

        if !pressMenuItem(in: appElem, cmdChar: "C") {
            sendKeystroke(keyCode: 8, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 140_000_000)

        // Deselect by pressing Left Arrow (keyCode 123) so cursor stays at the top of the reply
        sendKeystroke(keyCode: 123, flags: [])

        NSApp.activate(ignoringOtherApps: true)

        if NSPasteboard.general.changeCount != initialChangeCount {
            let pb = NSPasteboard.general
            let webArchiveType1 = NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")
            let webArchiveType2 = NSPasteboard.PasteboardType("com.apple.webarchive")
            let appleHTMLType = NSPasteboard.PasteboardType("Apple HTML pasteboard type")

            let archiveData = pb.data(forType: webArchiveType1) ?? pb.data(forType: webArchiveType2)
            let htmlString = pb.string(forType: .html)
                ?? pb.string(forType: appleHTMLType)
                ?? MailHTMLPreserver.extractHTMLFromWebArchive(archiveData)
            let plainString = pb.string(forType: .string)

            restorePasteboardSnapshot(savedClipboard)

            self.lastCapturedWebArchiveData = archiveData
            self.lastCapturedFullHTML = htmlString
            self.lastCapturedFullPlainText = plainString

            // Extract ONLY the user's new reply (excluding quoted thread & signature)
            if let htmlString, !htmlString.isEmpty {
                let (replyHTML, _) = MailHTMLPreserver.splitMailHTML(htmlString)
                let visibleFromReplyHTML = MailHTMLPreserver.buildVisibleMap(html: replyHTML).visibleText
                let (cleanReply, _) = MailHTMLPreserver.splitMailPlainText(visibleFromReplyHTML)
                if !cleanReply.isEmpty {
                    self.lastCapturedMailText = cleanReply
                    return .success(cleanReply)
                }
            }

            if let plainString, !plainString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (cleanReply, _) = MailHTMLPreserver.splitMailPlainText(plainString)
                let resultText = cleanReply.isEmpty ? plainString.trimmingCharacters(in: .whitespacesAndNewlines) : cleanReply
                self.lastCapturedMailText = resultText
                return .success(resultText)
            }
        } else {
            restorePasteboardSnapshot(savedClipboard)
        }

        // Fallback to fast AX tree extraction (also excluding blockquotes & attribution)
        if let treeText = extractStructuredTextFromWebArea(webArea),
           !treeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.lastCapturedMailText = treeText
            return .success(treeText)
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

    /// Reconstructs multi-paragraph reply text from WebKit's `AXWebArea`, stopping before any quoted block or signature.
    private func extractStructuredTextFromWebArea(_ webArea: AXUIElement) -> String? {
        let topChildren = axChildren(of: webArea)
        if !topChildren.isEmpty {
            var paragraphs: [String] = []
            for child in topChildren {
                if isQuotedOrSignatureAXElement(child) {
                    break
                }
                var inlineFragments: [String] = []
                var hitQuote = false
                collectLeafText(from: child, into: &inlineFragments, hitQuote: &hitQuote, maxDepth: 12)
                let line = inlineFragments.joined()
                if MailHTMLPreserver.isAttributionLine(line) {
                    break
                }
                paragraphs.append(line)
                if hitQuote {
                    break
                }
            }
            let rawJoined = paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let (replyOnly, _) = MailHTMLPreserver.splitMailPlainText(rawJoined)
            if !replyOnly.isEmpty {
                return replyOnly
            }
        }

        if let directVal = axStringAttribute(webArea, kAXValueAttribute),
           !directVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (replyOnly, _) = MailHTMLPreserver.splitMailPlainText(directVal)
            if !replyOnly.isEmpty {
                return replyOnly
            }
        }

        return nil
    }

    private func isQuotedOrSignatureAXElement(_ element: AXUIElement) -> Bool {
        if let quoteLevel = axIntAttribute(element, "AXBlockQuoteLevel"), quoteLevel > 0 {
            return true
        }
        if let domId = axStringAttribute(element, "AXDOMIdentifier")?.lowercased(),
           domId.contains("applemailsignature") || domId.contains("appleoriginalcontents") {
            return true
        }
        var classListRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classListRef) == .success,
           let classes = classListRef as? [String] {
            for c in classes {
                let lower = c.lowercased()
                if lower.contains("appleoriginalcontents") || lower.contains("applemailsignature") {
                    return true
                }
            }
        }
        return false
    }

    private func collectLeafText(from element: AXUIElement, into fragments: inout [String], hitQuote: inout Bool, maxDepth: Int) {
        guard maxDepth >= 0 else { return }
        if isQuotedOrSignatureAXElement(element) {
            hitQuote = true
            return
        }
        let role = axStringAttribute(element, kAXRoleAttribute) ?? ""

        if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
            if let val = axStringAttribute(element, kAXValueAttribute), !val.isEmpty {
                if MailHTMLPreserver.isAttributionLine(val) {
                    hitQuote = true
                    return
                }
                fragments.append(val)
                return
            }
        }

        for child in axChildren(of: element) {
            collectLeafText(from: child, into: &fragments, hitQuote: &hitQuote, maxDepth: maxDepth - 1)
            if hitQuote { return }
        }
    }

    // MARK: - 2. Apply Corrected Text Directly to Active Apple Mail Compose Window (Preserving Quotes & Formatting)

    func applyCorrectedTextToMail(_ correctedText: String) async -> Result<Void, MailIntegrationError> {
        refreshStatus()
        let (cleanCorrectedReply, _) = MailHTMLPreserver.splitMailPlainText(correctedText)
        let replyToApply = cleanCorrectedReply.isEmpty
            ? correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            : cleanCorrectedReply
        self.lastCapturedMailText = replyToApply

        guard isAccessibilityTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replyToApply, forType: .string)
            requestAccessibilityPermission()
            return .failure(.accessibilityNotGranted)
        }

        guard let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replyToApply, forType: .string)
            return .failure(.mailNotRunning)
        }

        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        guard let (composeWin, webArea) = findComposeWindowAndWebArea(in: appElem) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replyToApply, forType: .string)
            return .failure(.noComposeWindowFound)
        }

        // 1. Activate Apple Mail and raise the Compose Window
        mailApp.activate()
        _ = AXUIElementPerformAction(composeWin, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(composeWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(composeWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 160_000_000)

        // 2. Focus the editable `AXWebArea` (email body) explicitly
        _ = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 3. Select All (⌘A) inside `webArea`
        if !pressMenuItem(in: appElem, cmdChar: "A") {
            sendKeystroke(keyCode: 0, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 90_000_000)

        // 4. Copy (⌘C) the current live content of the compose window so we have the exact latest
        //    HTML formatting, inline attachments (WebArchive), and `<blockquote type="cite">` quoted thread!
        let beforeCopyCount = NSPasteboard.general.changeCount
        if !pressMenuItem(in: appElem, cmdChar: "C") {
            sendKeystroke(keyCode: 8, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let pb = NSPasteboard.general
        let webArchiveType1 = NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")
        let webArchiveType2 = NSPasteboard.PasteboardType("com.apple.webarchive")
        let appleHTMLType = NSPasteboard.PasteboardType("Apple HTML pasteboard type")

        let liveArchiveData: Data?
        let liveHTML: String?
        let livePlainText: String?

        if pb.changeCount != beforeCopyCount {
            liveArchiveData = pb.data(forType: webArchiveType1) ?? pb.data(forType: webArchiveType2) ?? self.lastCapturedWebArchiveData
            liveHTML = pb.string(forType: .html)
                ?? pb.string(forType: appleHTMLType)
                ?? MailHTMLPreserver.extractHTMLFromWebArchive(liveArchiveData)
                ?? self.lastCapturedFullHTML
            livePlainText = pb.string(forType: .string) ?? self.lastCapturedFullPlainText
        } else {
            liveArchiveData = self.lastCapturedWebArchiveData
            liveHTML = self.lastCapturedFullHTML
            livePlainText = self.lastCapturedFullPlainText
        }

        // 5. Build the updated pasteboard preserving formatting in the reply AND keeping the quoted block untouched
        pb.clearContents()

        let (_, quotedPlainSuffix) = MailHTMLPreserver.splitMailPlainText(livePlainText ?? "")
        let finalPlainText = quotedPlainSuffix.isEmpty
            ? replyToApply
            : (replyToApply + "\n\n" + quotedPlainSuffix)

        if let liveHTML, !liveHTML.isEmpty {
            let (replyHTML, quotedHTML) = MailHTMLPreserver.splitMailHTML(liveHTML)
            let updatedReplyHTML = MailHTMLPreserver.applyUpdatedText(to: replyHTML, newPlainText: replyToApply)
            let finalHTML = updatedReplyHTML + quotedHTML

            self.lastCapturedFullHTML = finalHTML
            self.lastCapturedFullPlainText = finalPlainText

            if let liveArchiveData,
               let updatedArchive = MailHTMLPreserver.updateHTMLInWebArchive(liveArchiveData, newHTML: finalHTML) {
                self.lastCapturedWebArchiveData = updatedArchive
                pb.setData(updatedArchive, forType: webArchiveType1)
                pb.setData(updatedArchive, forType: webArchiveType2)
            }

            if let htmlData = finalHTML.data(using: .utf8) {
                pb.setData(htmlData, forType: .html)
                pb.setData(htmlData, forType: appleHTMLType)
            }
            pb.setString(finalPlainText, forType: .string)
        } else {
            pb.setString(finalPlainText, forType: .string)
        }

        // 6. Paste (⌘V) the rich HTML / WebArchive back into the selected `webArea`
        if !pressMenuItem(in: appElem, cmdChar: "V") {
            sendKeystroke(keyCode: 9, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)

        return .success(())
    }

    // MARK: - Language-Independent Menu Item Invoker (`AXMenuItemCmdChar`)

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
