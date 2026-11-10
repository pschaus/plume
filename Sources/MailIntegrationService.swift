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

    static func normalizeSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
         .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func isAttributionLine(_ line: String) -> Bool {
        let normalized = normalizeSpaces(line)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(">") { return true }
        if trimmed.hasPrefix("-----Original Message-----")
            || trimmed.hasPrefix("-------- Message transféré")
            || trimmed.hasPrefix("-------- Original Message") {
            return true
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("début du message réexpédié")
            || lower.hasPrefix("begin forwarded message")
            || lower.hasPrefix("message transféré")
            || lower.hasPrefix("forwarded message") {
            return true
        }
        if trimmed.hasSuffix(":") {
            let prefixes = ["le ", "on ", "am ", "el ", "op ", "il "]
            let suffixes = [
                "a écrit :", "a écrit:", "wrote:", "wrote :",
                "schrieb:", "escribió:", "schreef:", "ha scritto:"
            ]
            if prefixes.contains(where: { lower.hasPrefix($0) }) && suffixes.contains(where: { lower.hasSuffix($0) }) {
                return true
            }
            if suffixes.contains(where: { lower.hasSuffix($0) }) && (lower.contains("202") || lower.contains(" à ") || lower.contains(" at ") || lower.contains("@")) {
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
            let trimmed = normalizeSpaces(line).trimmingCharacters(in: .whitespaces)
            if isAttributionLine(trimmed) || trimmed == "--" || normalizeSpaces(line) == "-- " {
                splitLineIdx = i
                break
            }
            // Check Outlook/Exchange style header block ("De : ... \n Envoyé : ...")
            let lower = trimmed.lowercased()
            if (lower.hasPrefix("de :") || lower.hasPrefix("de:") || lower.hasPrefix("from:")),
               i + 1 < lines.count {
                let nextLower = normalizeSpaces(lines[i + 1]).trimmingCharacters(in: .whitespaces).lowercased()
                if nextLower.hasPrefix("envoyé") || nextLower.hasPrefix("date") || nextLower.hasPrefix("sent:") || nextLower.hasPrefix("à :") || nextLower.hasPrefix("to:") {
                    splitLineIdx = i
                    break
                }
            }
            if i + 1 < lines.count {
                let combined2 = trimmed + " " + normalizeSpaces(lines[i + 1]).trimmingCharacters(in: .whitespaces)
                if isAttributionLine(combined2) {
                    splitLineIdx = i
                    break
                }
            }
            if i + 2 < lines.count {
                let combined3 = trimmed + " " + normalizeSpaces(lines[i + 1]).trimmingCharacters(in: .whitespaces) + " " + normalizeSpaces(lines[i + 2]).trimmingCharacters(in: .whitespaces)
                if isAttributionLine(combined3) {
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
        let bodyStart = bodyContentStartIndex(in: html)
        let lowerHTML = html.lowercased()

        let quoteMarkers = [
            "class=\"appleoriginalcontents\"",
            "class='appleoriginalcontents'",
            "id=\"appleoriginalcontents\"",
            "id='appleoriginalcontents'",
            "<blockquote"
        ]

        var earliestQuoteStart: String.Index? = nil
        for marker in quoteMarkers {
            if let range = lowerHTML.range(of: marker, range: bodyStart..<lowerHTML.endIndex) {
                var tagStart = range.lowerBound
                if !marker.hasPrefix("<") {
                    if let openBracket = lowerHTML[bodyStart..<tagStart].lastIndex(of: "<") {
                        tagStart = openBracket
                    }
                }
                if earliestQuoteStart == nil || tagStart < earliestQuoteStart! {
                    earliestQuoteStart = tagStart
                }
            }
        }

        // Only split at AppleMailSignature if there is actual non-empty reply text BEFORE the signature
        // (because Apple Mail sometimes places the user's new text inside <div id="AppleMailSignature">!)
        let sigMarkers = [
            "id=\"applemailsignature\"",
            "id='applemailsignature'",
            "class=\"applemailsignature\"",
            "class='applemailsignature'"
        ]
        var earliestSigStart: String.Index? = nil
        for marker in sigMarkers {
            if let range = lowerHTML.range(of: marker, range: bodyStart..<lowerHTML.endIndex) {
                var tagStart = range.lowerBound
                if let openBracket = lowerHTML[bodyStart..<tagStart].lastIndex(of: "<") {
                    tagStart = openBracket
                }
                let textBeforeSig = buildVisibleMap(html: String(html[..<tagStart])).visibleText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !textBeforeSig.isEmpty {
                    if earliestSigStart == nil || tagStart < earliestSigStart! {
                        earliestSigStart = tagStart
                    }
                }
            }
        }

        var earliestTagStart: String.Index? = earliestQuoteStart
        if let sig = earliestSigStart {
            if earliestTagStart == nil || sig < earliestTagStart! {
                earliestTagStart = sig
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

    /// Normalizes smart typography (curly apostrophes, smart quotes, non-breaking spaces) 1-for-1 per character
    /// so that string indices in the normalized string correspond 1-to-1 with `source`.
    static func normalizeTypographyChar(_ c: Character) -> Character {
        switch c {
        case "\u{2019}", "\u{2018}", "\u{02BC}", "`", "´":
            return "'"
        case "\u{201C}", "\u{201D}", "«", "»":
            return "\""
        case "\u{00A0}", "\u{202F}":
            return " "
        default:
            return c
        }
    }

    static func normalizeTypography(_ s: String) -> String {
        String(s.map(normalizeTypographyChar))
    }

    /// Finds the best range of `target` inside `source`, preferring whole-word boundary matches
    /// and matching smart apostrophes / non-breaking spaces seamlessly.
    static func findBestMatchRange(of target: String, in source: String) -> Range<String.Index>? {
        guard !target.isEmpty, !source.isEmpty else { return nil }

        let startsWithWord = target.first.map { $0.isLetter || $0.isNumber } ?? false
        let endsWithWord = target.last.map { $0.isLetter || $0.isNumber } ?? false

        // Pass 1: Direct search on `source`, then Pass 2: Typography-normalized search
        for useNormalized in [false, true] {
            let haystack = useNormalized ? normalizeTypography(source) : source
            let needle = useNormalized ? normalizeTypography(target) : target

            for options: String.CompareOptions in [[], [.caseInsensitive]] {
                var searchStart = haystack.startIndex

                while searchStart < haystack.endIndex,
                      let range = haystack.range(of: needle, options: options, range: searchStart..<haystack.endIndex) {
                    var leftBoundaryOK = true
                    if startsWithWord && range.lowerBound > haystack.startIndex {
                        let prevChar = haystack[haystack.index(before: range.lowerBound)]
                        if prevChar.isLetter || prevChar.isNumber {
                            leftBoundaryOK = false
                        }
                    }

                    var rightBoundaryOK = true
                    if endsWithWord && range.upperBound < haystack.endIndex {
                        let nextChar = haystack[range.upperBound]
                        if nextChar.isLetter || nextChar.isNumber {
                            rightBoundaryOK = false
                        }
                    }

                    if leftBoundaryOK && rightBoundaryOK {
                        if !useNormalized {
                            return range
                        }
                        let startOffset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                        let lengthOffset = haystack.distance(from: range.lowerBound, to: range.upperBound)
                        let srcStart = source.index(source.startIndex, offsetBy: startOffset)
                        let srcEnd = source.index(srcStart, offsetBy: lengthOffset)
                        return srcStart..<srcEnd
                    }

                    searchStart = haystack.index(after: range.lowerBound)
                }
            }
        }

        // Fallback to non-boundary substring match (exact or typography-normalized)
        if let direct = source.range(of: target) ?? source.range(of: target, options: .caseInsensitive) {
            return direct
        }
        let normHaystack = normalizeTypography(source)
        let normNeedle = normalizeTypography(target)
        if let normRange = normHaystack.range(of: normNeedle) ?? normHaystack.range(of: normNeedle, options: .caseInsensitive) {
            let startOffset = normHaystack.distance(from: normHaystack.startIndex, to: normRange.lowerBound)
            let lengthOffset = normHaystack.distance(from: normRange.lowerBound, to: normRange.upperBound)
            let srcStart = source.index(source.startIndex, offsetBy: startOffset)
            let srcEnd = source.index(srcStart, offsetBy: lengthOffset)
            return srcStart..<srcEnd
        }
        return nil
    }

    /// Returns all non-overlapping match ranges of `target` inside `source`, preferring whole-word boundary matches.
    static func findAllMatchRanges(of target: String, in source: String) -> [Range<String.Index>] {
        guard !target.isEmpty, !source.isEmpty else { return [] }
        let startsWithWord = target.first.map { $0.isLetter || $0.isNumber } ?? false
        let endsWithWord = target.last.map { $0.isLetter || $0.isNumber } ?? false

        let haystack = normalizeTypography(source)
        let needle = normalizeTypography(target)
        var results: [Range<String.Index>] = []

        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, options: [.caseInsensitive], range: searchStart..<haystack.endIndex) {
            var leftBoundaryOK = true
            if startsWithWord && range.lowerBound > haystack.startIndex {
                let prevChar = haystack[haystack.index(before: range.lowerBound)]
                if prevChar.isLetter || prevChar.isNumber {
                    leftBoundaryOK = false
                }
            }
            var rightBoundaryOK = true
            if endsWithWord && range.upperBound < haystack.endIndex {
                let nextChar = haystack[range.upperBound]
                if nextChar.isLetter || nextChar.isNumber {
                    rightBoundaryOK = false
                }
            }
            if leftBoundaryOK && rightBoundaryOK {
                let startOffset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let lengthOffset = haystack.distance(from: range.lowerBound, to: range.upperBound)
                let srcStart = source.index(source.startIndex, offsetBy: startOffset)
                let srcEnd = source.index(srcStart, offsetBy: lengthOffset)
                results.append(srcStart..<srcEnd)
                searchStart = range.upperBound
            } else {
                searchStart = haystack.index(after: range.lowerBound)
            }
        }

        if results.isEmpty, let single = findBestMatchRange(of: target, in: source) {
            results.append(single)
        }
        return results
    }
}

struct MailIssueScreenLocation: Equatable {
    let issue: SpellIssue
    /// Screen bounding rects (in Cocoa global screen coordinates) inside the Apple Mail compose WebArea
    let rects: [CGRect]

    var primaryRect: CGRect {
        rects.first ?? .zero
    }
}

struct MailComposeOverlaySnapshot: Equatable {
    let composeWindowFrame: CGRect
    let webAreaFrame: CGRect
    let locatedIssues: [MailIssueScreenLocation]
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
    private var lastActiveComposeQuartzFrame: CGRect? = nil

    private init() {
        ensureMailAntiOupsDoesNotBlockSend()
        refreshStatus()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
    }

    /// Prevents `Antidote - Anti-Oups!.appex` (Apple Mail's `MEComposeSessionHandler` extension) from holding
    /// Mail's `allowMessageSendForSession:completionHandler:` callback without invoking it when the email was
    /// corrected by Plume rather than Antidote (`CorrectionADejaEteLance = 0`).
    /// Without this, `ComposeViewController.isPerformingSendChecks` stays `YES` indefinitely after clicking
    /// Mail's top-right Send button once, leaving the Send button permanently disabled.
    func ensureMailAntiOupsDoesNotBlockSend() {
        for suite in ["com.druide.Antidote", "com.druide.AgentAntidote"] {
            if let defaults = UserDefaults(suiteName: suite),
               var antiOups = defaults.dictionary(forKey: "antiOups") {
                let cAuto = (antiOups["correctionAutomatique"] as? Bool) ?? false
                let dPJ = (antiOups["detectionPiecesJointes"] as? Bool) ?? false
                let dTon = (antiOups["detectionTonVexant"] as? Bool) ?? false
                if cAuto || dPJ || dTon {
                    antiOups["correctionAutomatique"] = false
                    antiOups["detectionPiecesJointes"] = false
                    antiOups["detectionTonVexant"] = false
                    defaults.set(antiOups, forKey: "antiOups")
                    CFPreferencesAppSynchronize(suite as CFString)
                }
            }
        }

        let pbName = NSPasteboard.Name("druide_pbs_\(NSUserName())")
        let pb = NSPasteboard(name: pbName)
        let pbType = NSPasteboard.PasteboardType("com.druide.antidote.pbs")
        if let data = pb.data(forType: pbType),
           var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)) as? [String: Any] {
            let cAuto = (plist["correctionAutomatique"] as? Bool) ?? false
            let dPJ = (plist["detectionPiecesJointes"] as? Bool) ?? false
            if cAuto || dPJ {
                plist["correctionAutomatique"] = false
                plist["detectionPiecesJointes"] = false
                if let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    pb.clearContents()
                    pb.setData(newData, forType: pbType)
                }
            }
        }

        let antiOupsAppexPath = "/Applications/Antidote/Connectix 12.app/Contents/PlugIns/Antidote - Anti-Oups!.appex"
        let serviceAppPath = "/Applications/Antidote/Connectix 12.app/Contents/Library/LoginItems/ServiceConnectixAntidote.app"
        if FileManager.default.fileExists(atPath: antiOupsAppexPath),
           FileManager.default.fileExists(atPath: serviceAppPath) {
            let isServiceRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "com.druide.AgentConnectix"
            }
            if !isServiceRunning {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: serviceAppPath), configuration: config, completionHandler: nil)
            }
        }
    }

    func startMonitoring(onMailTextChanged: @escaping @MainActor @Sendable (String) -> Void) {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatus()
                if self.isMailFrontmost && self.isAccessibilityTrusted && self.mailWindowFrame != nil {
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
        let newTrusted = AXIsProcessTrusted()
        if isAccessibilityTrusted != newTrusted {
            isAccessibilityTrusted = newTrusted
        }

        let runningApps = NSWorkspace.shared.runningApplications
        let mailApp = runningApps.first(where: { $0.bundleIdentifier == "com.apple.mail" })
        let newRunning = (mailApp != nil)
        if isMailRunning != newRunning {
            isMailRunning = newRunning
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let anyMainEditorKey = NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible && $0.isKeyWindow }
        let isFloatingPlumePanel = (frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier && !anyMainEditorKey && mailApp != nil)
        let newFrontmost = (frontApp?.bundleIdentifier == "com.apple.mail") || isFloatingPlumePanel
        if isMailFrontmost != newFrontmost {
            isMailFrontmost = newFrontmost
        }

        let newFrame: CGRect?
        if newFrontmost, let pid = mailApp?.processIdentifier {
            newFrame = findFrontmostComposeWindowFrame(pid: pid)
        } else {
            newFrame = nil
        }
        if mailWindowFrame != newFrame {
            mailWindowFrame = newFrame
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

    // MARK: - Window Frame Detection (Only Active Frontmost Compose Window)

    private func findFrontmostComposeWindowFrame(pid: pid_t) -> CGRect? {
        guard isAccessibilityTrusted else { return nil }
        let appElem = AXUIElementCreateApplication(pid)

        var frontWinRef: CFTypeRef?
        var candidateWin: AXUIElement?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &frontWinRef) == .success,
           let w = frontWinRef {
            candidateWin = (w as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(appElem, kAXMainWindowAttribute as CFString, &frontWinRef) == .success,
                  let w = frontWinRef {
            candidateWin = (w as! AXUIElement)
        } else {
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                candidateWin = windows.first
            }
        }

        guard let win = candidateWin else { return nil }
        guard !isMailViewerWindow(win),
              findEditableWebArea(in: win, maxDepth: 7) != nil,
              let rect = axFrame(of: win),
              rect.width > 250, rect.height > 200 else {
            return nil
        }
        lastActiveComposeQuartzFrame = rect
        return convertQuartzToCocoaScreenRect(rect)
    }

    private func isMailViewerWindow(_ win: AXUIElement) -> Bool {
        let role = axStringAttribute(win, kAXRoleAttribute) ?? ""
        if role != "AXWindow" {
            return true
        }
        if let winId = axStringAttribute(win, "AXIdentifier"),
           winId.hasPrefix("Mail.messageViewer.window") || winId.contains("messageViewer") {
            return true
        }
        return containsRole(in: win, role: "AXOutline", maxDepth: 4)
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
        // 1. Always check the focused or main window first so multi-draft setups target the active compose window
        var focusedWinRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &focusedWinRef) == .success,
           let w = focusedWinRef {
            let win = w as! AXUIElement
            if !isMailViewerWindow(win),
               let webArea = findEditableWebArea(in: win, maxDepth: 7) {
                if let qRect = axFrame(of: win) {
                    lastActiveComposeQuartzFrame = qRect
                }
                return (win, webArea)
            }
        }

        var mainWinRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXMainWindowAttribute as CFString, &mainWinRef) == .success,
           let w = mainWinRef {
            let win = w as! AXUIElement
            if !isMailViewerWindow(win),
               let webArea = findEditableWebArea(in: win, maxDepth: 7) {
                if let qRect = axFrame(of: win) {
                    lastActiveComposeQuartzFrame = qRect
                }
                return (win, webArea)
            }
        }

        // 2. Fallback to windows list (preferring the last active compose window frame if multiple drafts exist)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        if let targetQRect = lastActiveComposeQuartzFrame {
            for win in windows {
                if !isMailViewerWindow(win),
                   let qRect = axFrame(of: win),
                   hypot(qRect.midX - targetQRect.midX, qRect.midY - targetQRect.midY) < 40,
                   let webArea = findEditableWebArea(in: win, maxDepth: 7) {
                    return (win, webArea)
                }
            }
        }

        for win in windows {
            if !isMailViewerWindow(win),
               let webArea = findEditableWebArea(in: win, maxDepth: 7) {
                return (win, webArea)
            }
        }

        for win in windows where !isMailViewerWindow(win) {
            if let webArea = findEditableWebArea(in: win, requireExplicitEditableAttr: true, maxDepth: 7) {
                return (win, webArea)
            }
        }

        return nil
    }

    private func containsRole(in root: AXUIElement, role targetRole: String, maxDepth: Int) -> Bool {
        guard maxDepth >= 0 else { return false }
        let currentRole = axStringAttribute(root, kAXRoleAttribute) ?? ""
        if currentRole == targetRole {
            return true
        }
        if currentRole == "AXTable" || currentRole == "AXToolbar" || currentRole == "AXWebArea" || currentRole == "AXList" {
            return false
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

        // Never recurse into large non-compose containers (message list tables, sidebar outlines, toolbars, sheets)
        if role == "AXTable" || role == "AXOutline" || role == "AXList" || role == "AXContentList" || role == "AXToolbar" || role == "AXSheet" {
            return nil
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

    // MARK: - 1. Pull Text from Active Apple Mail Compose Window (Excluding Quoted Thread)

    func pullTextFromMail(activatePlumeAfterPull: Bool = true) async -> Result<String, MailIntegrationError> {
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

        // Read directly from WebKit's AXWebArea tree in ~2ms without touching focus, cursor, or clipboard
        if let treeText = extractStructuredTextFromWebArea(webArea),
           !treeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.lastCapturedMailText = treeText
            if activatePlumeAfterPull {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                ensureMailActiveAndComposeKey(mailApp: mailApp, composeWin: composeWin)
            }
            return .success(treeText)
        }

        if !activatePlumeAfterPull {
            ensureMailActiveAndComposeKey(mailApp: mailApp, composeWin: composeWin)
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

    /// Reconstructs multi-paragraph reply text from WebKit's `AXWebArea`, stopping before any quoted block or trailing signature.
    private func extractStructuredTextFromWebArea(_ webArea: AXUIElement) -> String? {
        let topChildren = axChildren(of: webArea)
        if !topChildren.isEmpty {
            var paragraphs: [String] = []
            for child in topChildren {
                let hasNonEmptyBefore = paragraphs.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if isQuotedOrSignatureAXElement(child, allowSignatureStop: hasNonEmptyBefore) {
                    break
                }
                var inlineFragments: [String] = []
                var hitQuote = false
                collectLeafText(from: child, into: &inlineFragments, hitQuote: &hitQuote, allowSignatureStop: hasNonEmptyBefore, maxDepth: 12)
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

    private func isQuotedOrSignatureAXElement(_ element: AXUIElement, allowSignatureStop: Bool) -> Bool {
        if let quoteLevel = axIntAttribute(element, "AXBlockQuoteLevel"), quoteLevel > 0 {
            return true
        }
        if axStringAttribute(element, kAXRoleAttribute) == "AXBlockQuote" {
            return true
        }
        if let domId = axStringAttribute(element, "AXDOMIdentifier")?.lowercased() {
            if domId.contains("appleoriginalcontents") {
                return true
            }
            if allowSignatureStop && domId.contains("applemailsignature") {
                return true
            }
        }
        var classListRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classListRef) == .success,
           let classes = classListRef as? [String] {
            for c in classes {
                let lower = c.lowercased()
                if lower.contains("appleoriginalcontents") {
                    return true
                }
                if allowSignatureStop && lower.contains("applemailsignature") {
                    return true
                }
            }
        }
        return false
    }

    private func collectLeafText(
        from element: AXUIElement,
        into fragments: inout [String],
        hitQuote: inout Bool,
        allowSignatureStop: Bool,
        maxDepth: Int
    ) {
        guard maxDepth >= 0 else { return }
        let hasFragments = allowSignatureStop || fragments.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isQuotedOrSignatureAXElement(element, allowSignatureStop: hasFragments) {
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
            collectLeafText(from: child, into: &fragments, hitQuote: &hitQuote, allowSignatureStop: hasFragments, maxDepth: maxDepth - 1)
            if hitQuote { return }
        }
    }

    // MARK: - 1b. Locate Exact Screen Coordinates (`AXBoundsForRange`) of SpellIssues in Apple Mail Composer

    private struct AXLeafTextNode {
        let element: AXUIElement
        let text: String
    }

    private func collectReplyParagraphNodes(from webArea: AXUIElement) -> [[AXLeafTextNode]] {
        var paragraphs: [[AXLeafTextNode]] = []
        let topChildren = axChildren(of: webArea)
        for child in topChildren {
            let hasNonEmptyBefore = paragraphs.contains { para in
                para.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            if isQuotedOrSignatureAXElement(child, allowSignatureStop: hasNonEmptyBefore) {
                break
            }
            var nodesInPara: [AXLeafTextNode] = []
            var hitQuote = false
            collectLeafNodes(from: child, into: &nodesInPara, hitQuote: &hitQuote, allowSignatureStop: hasNonEmptyBefore, maxDepth: 12)
            let paraText = nodesInPara.map(\.text).joined()
            if MailHTMLPreserver.isAttributionLine(paraText) {
                break
            }
            let trimmedPara = paraText.trimmingCharacters(in: .whitespaces)
            if trimmedPara == "--" || paraText == "-- " {
                break
            }
            if !nodesInPara.isEmpty {
                paragraphs.append(nodesInPara)
            }
            if hitQuote {
                break
            }
        }
        return paragraphs
    }

    func locateIssueRectsInActiveComposeWindow(for issues: [SpellIssue]) -> MailComposeOverlaySnapshot? {
        guard isAccessibilityTrusted,
              isMailFrontmost,
              !issues.isEmpty,
              let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            return nil
        }

        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        guard let (composeWin, webArea) = findComposeWindowAndWebArea(in: appElem),
              let composeQuartzRect = axFrame(of: composeWin),
              composeQuartzRect.width > 250, composeQuartzRect.height > 200 else {
            return nil
        }

        let composeCocoaRect = convertQuartzToCocoaScreenRect(composeQuartzRect)
        // Exclude the top ~260pt of the compose window (toolbar + Send button + To/Cc/Bcc/Subject/From header fields)
        let safeBodyClipRect = CGRect(
            x: composeCocoaRect.origin.x + 4,
            y: composeCocoaRect.origin.y + 10,
            width: max(80, composeCocoaRect.width - 8),
            height: max(60, composeCocoaRect.height - 260)
        )

        var parentRef: CFTypeRef?
        let scrollAreaQuartz: CGRect?
        if AXUIElementCopyAttributeValue(webArea, kAXParentAttribute as CFString, &parentRef) == .success,
           let parentElem = parentRef {
            scrollAreaQuartz = axFrame(of: parentElem as! AXUIElement)
        } else {
            scrollAreaQuartz = nil
        }

        let webAreaCocoaRect: CGRect
        if let scrollQuartz = scrollAreaQuartz, scrollQuartz.width > 80, scrollQuartz.height > 40 {
            let rawScrollCocoa = convertQuartzToCocoaScreenRect(scrollQuartz)
            let clipped = rawScrollCocoa.intersection(composeCocoaRect.insetBy(dx: 4, dy: 8))
            webAreaCocoaRect = clipped.isNull ? safeBodyClipRect : clipped
        } else if let webQuartz = axFrame(of: webArea), webQuartz.width > 80, webQuartz.height > 40 {
            // Intersect with safe body clip rect in case webArea reports full scrollable content height
            let rawCocoa = convertQuartzToCocoaScreenRect(webQuartz)
            let clipped = rawCocoa.intersection(safeBodyClipRect)
            webAreaCocoaRect = clipped.isNull ? safeBodyClipRect : clipped
        } else {
            webAreaCocoaRect = safeBodyClipRect
        }

        let paragraphs = collectReplyParagraphNodes(from: webArea)
        let allLeafNodes = paragraphs.flatMap { $0 }
        guard !allLeafNodes.isEmpty else { return nil }

        var located: [MailIssueScreenLocation] = []
        var usedNodeRanges: [(nodeIndex: Int, nsRange: NSRange)] = []

        for issue in issues where !issue.original.isEmpty {
            var foundRects: [CGRect] = []

            // Pass 1: Match inside a single AXStaticText leaf node (skipping already-claimed ranges for duplicate words)
            for (nodeIdx, node) in allLeafNodes.enumerated() {
                let candidateRanges = MailHTMLPreserver.findAllMatchRanges(of: issue.original, in: node.text)
                var matchedInNode = false
                for matchRange in candidateRanges {
                    let nsRange = NSRange(matchRange, in: node.text)
                    let alreadyUsed = usedNodeRanges.contains {
                        $0.nodeIndex == nodeIdx && NSIntersectionRange($0.nsRange, nsRange).length > 0
                    }
                    guard !alreadyUsed else { continue }

                    let cfRange = CFRange(location: nsRange.location, length: nsRange.length)
                    if let rect = axBoundsForRange(element: node.element, range: cfRange, totalUTF16Len: node.text.utf16.count),
                       rect.intersects(webAreaCocoaRect) {
                        foundRects.append(rect)
                        usedNodeRanges.append((nodeIndex: nodeIdx, nsRange: nsRange))
                        matchedInNode = true
                        break
                    }
                }
                if matchedInNode {
                    break
                }
            }

            // Pass 2: Match across adjacent AXStaticText nodes in a paragraph (e.g. split by bold/italic tags)
            if foundRects.isEmpty {
                for paraNodes in paragraphs where paraNodes.count > 1 {
                    var combined = ""
                    var spans: [(node: AXLeafTextNode, range: Range<String.Index>)] = []
                    for n in paraNodes {
                        let start = combined.endIndex
                        combined.append(n.text)
                        let end = combined.endIndex
                        spans.append((n, start..<end))
                    }
                    if let matchRange = MailHTMLPreserver.findBestMatchRange(of: issue.original, in: combined) {
                        for span in spans where span.range.overlaps(matchRange) {
                            let overlapStart = max(span.range.lowerBound, matchRange.lowerBound)
                            let overlapEnd = min(span.range.upperBound, matchRange.upperBound)
                            let startOffset = combined.distance(from: span.range.lowerBound, to: overlapStart)
                            let lenOffset = combined.distance(from: overlapStart, to: overlapEnd)
                            let localStart = span.node.text.index(span.node.text.startIndex, offsetBy: startOffset)
                            let localEnd = span.node.text.index(localStart, offsetBy: lenOffset)
                            let nsRange = NSRange(localStart..<localEnd, in: span.node.text)
                            let cfRange = CFRange(location: nsRange.location, length: nsRange.length)
                            if let rect = axBoundsForRange(element: span.node.element, range: cfRange, totalUTF16Len: span.node.text.utf16.count),
                               rect.intersects(webAreaCocoaRect) {
                                foundRects.append(rect)
                            }
                        }
                        if !foundRects.isEmpty {
                            break
                        }
                    }
                }
            }

            if !foundRects.isEmpty {
                located.append(MailIssueScreenLocation(issue: issue, rects: foundRects))
            }
        }

        return MailComposeOverlaySnapshot(
            composeWindowFrame: composeCocoaRect,
            webAreaFrame: webAreaCocoaRect,
            locatedIssues: located
        )
    }

    private func collectLeafNodes(
        from element: AXUIElement,
        into nodes: inout [AXLeafTextNode],
        hitQuote: inout Bool,
        allowSignatureStop: Bool,
        maxDepth: Int
    ) {
        guard maxDepth >= 0 else { return }
        let hasNodes = allowSignatureStop || nodes.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isQuotedOrSignatureAXElement(element, allowSignatureStop: hasNodes) {
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
                nodes.append(AXLeafTextNode(element: element, text: val))
                return
            }
        }
        for child in axChildren(of: element) {
            collectLeafNodes(from: child, into: &nodes, hitQuote: &hitQuote, allowSignatureStop: hasNodes, maxDepth: maxDepth - 1)
            if hitQuote { return }
        }
    }

    private func axQuartzBoundsForCFRange(element: AXUIElement, range: CFRange, totalUTF16Len: Int) -> CGRect? {
        var cfRange = range
        if let rangeVal = AXValueCreate(.cfRange, &cfRange) {
            var boundsRef: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeVal,
                &boundsRef
            )
            if err == .success, let bVal = boundsRef {
                var quartzRect = CGRect.zero
                if AXValueGetValue(bVal as! AXValue, .cgRect, &quartzRect),
                   quartzRect.width > 1, quartzRect.height > 1 {
                    return quartzRect
                }
            }
        }

        if let elemQuartz = axFrame(of: element),
           elemQuartz.width > 2, elemQuartz.height > 2,
           totalUTF16Len > 0 {
            let startFrac = CGFloat(max(0, range.location)) / CGFloat(totalUTF16Len)
            let lenFrac = CGFloat(max(1, range.length)) / CGFloat(totalUTF16Len)
            return CGRect(
                x: elemQuartz.origin.x + elemQuartz.width * startFrac,
                y: elemQuartz.origin.y,
                width: max(10, elemQuartz.width * lenFrac),
                height: elemQuartz.height
            )
        }
        return nil
    }

    private func axBoundsForRange(element: AXUIElement, range: CFRange, totalUTF16Len: Int) -> CGRect? {
        guard let quartzRect = axQuartzBoundsForCFRange(element: element, range: range, totalUTF16Len: totalUTF16Len) else {
            return nil
        }
        return convertQuartzToCocoaScreenRect(quartzRect)
    }

    // MARK: - 2. Native In-Place Word & Paragraph Replacement in Apple Mail (`AXTextOperation`)
    // Replaces ONLY the targeted text ranges inside WebKit's `AXWebArea` DOM without ever using
    // ⌘A (Select All), ⌘C (Copy), or ⌘V (Paste), so it can never duplicate text or touch header fields.
    // Every `AXTextMarkerRange` is verified against BOTH `AXStringForTextMarkerRange` (exact word content)
    // and `AXBoundsForTextMarkerRange` (exact screen coordinates of the underlined word).

    private func axTextMarker(forUTF16Offset offset: Int, in element: AXUIElement) -> CFTypeRef? {
        var marker: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXTextMarkerForIndex" as CFString,
            max(0, offset) as CFNumber,
            &marker
        )
        return (err == .success) ? marker : nil
    }

    private func axTextMarkerRange(startMarker: CFTypeRef, endMarker: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var markerRange: CFTypeRef?
        let pair = [startMarker, endMarker] as CFArray
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
            pair,
            &markerRange
        )
        return (err == .success) ? markerRange : nil
    }

    private func axStringForTextMarkerRange(_ markerRange: CFTypeRef, in webArea: AXUIElement) -> String? {
        var strRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &strRef
        )
        return (err == .success) ? (strRef as? String) : nil
    }

    private func axQuartzBoundsForTextMarkerRange(_ markerRange: CFTypeRef, in webArea: AXUIElement) -> CGRect? {
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &boundsRef
        )
        if err == .success, let bVal = boundsRef {
            var rect = CGRect.zero
            if AXValueGetValue(bVal as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 {
                return rect
            }
        }
        return nil
    }

    private func axIndexForPoint(_ quartzPoint: CGPoint, in webArea: AXUIElement) -> Int? {
        var pt = quartzPoint
        guard let ptVal = AXValueCreate(.cgPoint, &pt) else { return nil }
        var markerRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXTextMarkerForPosition" as CFString,
            ptVal,
            &markerRef
        ) == .success, let marker = markerRef else {
            return nil
        }
        var idxRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXIndexForTextMarker" as CFString,
            marker,
            &idxRef
        ) == .success, let idx = idxRef as? Int else {
            return nil
        }
        return idx
    }

    private func readFullWebAreaString(_ webArea: AXUIElement) -> String {
        var webStart: CFTypeRef?
        var webEnd: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, "AXStartTextMarker" as CFString, &webStart) == .success,
              AXUIElementCopyAttributeValue(webArea, "AXEndTextMarker" as CFString, &webEnd) == .success,
              let ws = webStart,
              let we = webEnd,
              let fullRange = axTextMarkerRange(startMarker: ws, endMarker: we, in: webArea),
              let fullStr = axStringForTextMarkerRange(fullRange, in: webArea) else {
            return ""
        }
        return fullStr
    }

    private struct CandidateOccurrence {
        let matchedSubstring: String
        let utf16Length: Int
        let approxGlobalOffset: Int
        let expectedQuartzRect: CGRect?
        let expectedCocoaRect: CGRect?
    }

    /// Resolves the exact `AXTextMarkerRange` in `webArea` whose `AXStringForTextMarkerRange` equals `matchedText`
    /// AND whose `AXBoundsForTextMarkerRange` matches `expectedQuartzRect` (the screen rect of the underlined word).
    private func resolveVerifiedMarkerRange(
        for candidate: CandidateOccurrence,
        in webArea: AXUIElement,
        fullWebString: String
    ) -> CFTypeRef? {
        let targetNorm = MailHTMLPreserver.normalizeTypography(candidate.matchedSubstring)
        let utf16Len = candidate.utf16Length
        guard utf16Len > 0 else { return nil }

        var orderedOffsets: [Int] = []
        var seenOffsets = Set<Int>()
        func addOffset(_ off: Int) {
            guard off >= 0, !seenOffsets.contains(off) else { return }
            seenOffsets.insert(off)
            orderedOffsets.append(off)
        }

        // 1. Probe via screen coordinates (`AXTextMarkerForPosition` -> `AXIndexForTextMarker`)
        if let qRect = candidate.expectedQuartzRect {
            let probePoint = CGPoint(x: qRect.minX + min(4, qRect.width * 0.25), y: qRect.midY)
            if let hitIdx = axIndexForPoint(probePoint, in: webArea) {
                for delta in 0...10 {
                    addOffset(hitIdx - delta)
                    addOffset(hitIdx + delta)
                }
            }
        }

        // 2. Probe via occurrences of `matchedSubstring` inside `fullWebString`
        if !fullWebString.isEmpty {
            let ranges = MailHTMLPreserver.findAllMatchRanges(of: candidate.matchedSubstring, in: fullWebString)
            let nsOffsets = ranges.map { NSRange($0, in: fullWebString).location }
            let sortedByProximity = nsOffsets.sorted {
                abs($0 - candidate.approxGlobalOffset) < abs($1 - candidate.approxGlobalOffset)
            }
            for baseOff in sortedByProximity {
                for delta in 0...8 {
                    addOffset(baseOff + delta)
                    addOffset(baseOff - delta)
                }
            }
        }

        // 3. Probe around cumulative `approxGlobalOffset` across paragraphs
        for delta in 0...64 {
            addOffset(candidate.approxGlobalOffset + delta)
            addOffset(candidate.approxGlobalOffset - delta)
        }

        var firstStringVerifiedFallback: CFTypeRef? = nil

        for offset in orderedOffsets {
            guard let m0 = axTextMarker(forUTF16Offset: offset, in: webArea),
                  let m1 = axTextMarker(forUTF16Offset: offset + utf16Len, in: webArea),
                  let markerRange = axTextMarkerRange(startMarker: m0, endMarker: m1, in: webArea),
                  let actualStr = axStringForTextMarkerRange(markerRange, in: webArea) else {
                continue
            }

            let actualNorm = MailHTMLPreserver.normalizeTypography(actualStr)
            guard actualNorm.caseInsensitiveCompare(targetNorm) == .orderedSame else {
                continue
            }

            // Verify screen bounds match the underlined word's Quartz rect if available
            if let expectedQ = candidate.expectedQuartzRect {
                if let markerQ = axQuartzBoundsForTextMarkerRange(markerRange, in: webArea) {
                    let dy = abs(markerQ.midY - expectedQ.midY)
                    let dx = abs(markerQ.minX - expectedQ.minX)
                    if dy < 22 && dx < 48 {
                        return markerRange
                    }
                }
                if firstStringVerifiedFallback == nil {
                    firstStringVerifiedFallback = markerRange
                }
            } else {
                return markerRange
            }
        }

        return firstStringVerifiedFallback
    }

    private func findTextMarkerRange(
        for target: String,
        targetCocoaRect: CGRect? = nil,
        in webArea: AXUIElement,
        paragraphs: [[AXLeafTextNode]]
    ) -> (markerRange: CFTypeRef, matchedSubstring: String)? {
        guard !target.isEmpty else { return nil }

        var candidates: [CandidateOccurrence] = []
        var runningGlobalUTF16 = 0

        // Pass 1: Collect all candidate occurrences inside individual AXStaticText leaf nodes
        for paraNodes in paragraphs {
            for node in paraNodes {
                let nodeBaseOffset = runningGlobalUTF16
                let matchRanges = MailHTMLPreserver.findAllMatchRanges(of: target, in: node.text)
                for matchRange in matchRanges {
                    let nsRange = NSRange(matchRange, in: node.text)
                    let cfRange = CFRange(location: nsRange.location, length: nsRange.length)
                    let qRect = axQuartzBoundsForCFRange(
                        element: node.element,
                        range: cfRange,
                        totalUTF16Len: node.text.utf16.count
                    )
                    let cRect = qRect.map { convertQuartzToCocoaScreenRect($0) }
                    candidates.append(CandidateOccurrence(
                        matchedSubstring: String(node.text[matchRange]),
                        utf16Length: nsRange.length,
                        approxGlobalOffset: nodeBaseOffset + nsRange.location,
                        expectedQuartzRect: qRect,
                        expectedCocoaRect: cRect
                    ))
                }
                runningGlobalUTF16 += node.text.utf16.count
            }
            // Account for newline between paragraphs in WebKit's flat text representation
            runningGlobalUTF16 += 1
        }

        // Pass 2: If no single-node match, check across adjacent AXStaticText leaf nodes in the same paragraph
        if candidates.isEmpty {
            var paraBaseUTF16 = 0
            for paraNodes in paragraphs {
                let paraLen = paraNodes.reduce(0) { $0 + $1.text.utf16.count }
                if paraNodes.count > 1 {
                    var combined = ""
                    var spans: [(node: AXLeafTextNode, range: Range<String.Index>, nodeOffsetInPara: Int)] = []
                    var offsetInPara = 0
                    for n in paraNodes {
                        let start = combined.endIndex
                        combined.append(n.text)
                        let end = combined.endIndex
                        spans.append((n, start..<end, offsetInPara))
                        offsetInPara += n.text.utf16.count
                    }
                    let matchRanges = MailHTMLPreserver.findAllMatchRanges(of: target, in: combined)
                    for matchRange in matchRanges {
                        let overlapping = spans.filter { $0.range.overlaps(matchRange) }
                        guard let firstSpan = overlapping.first else { continue }
                        let overlapStart = max(firstSpan.range.lowerBound, matchRange.lowerBound)
                        let startCharOffset = combined.distance(from: firstSpan.range.lowerBound, to: overlapStart)
                        let localStartIdx = firstSpan.node.text.index(firstSpan.node.text.startIndex, offsetBy: startCharOffset)
                        let firstNS = NSRange(localStartIdx..<localStartIdx, in: firstSpan.node.text)

                        let matchedSub = String(combined[matchRange])
                        let cfRange = CFRange(location: firstNS.location, length: max(1, firstSpan.node.text.utf16.count - firstNS.location))
                        let qRect = axQuartzBoundsForCFRange(
                            element: firstSpan.node.element,
                            range: cfRange,
                            totalUTF16Len: firstSpan.node.text.utf16.count
                        )
                        let cRect = qRect.map { convertQuartzToCocoaScreenRect($0) }
                        candidates.append(CandidateOccurrence(
                            matchedSubstring: matchedSub,
                            utf16Length: matchedSub.utf16.count,
                            approxGlobalOffset: paraBaseUTF16 + firstSpan.nodeOffsetInPara + firstNS.location,
                            expectedQuartzRect: qRect,
                            expectedCocoaRect: cRect
                        ))
                    }
                }
                paraBaseUTF16 += paraLen + 1
            }
        }

        guard !candidates.isEmpty else { return nil }

        // If the caller provided `targetCocoaRect` (from the clicked underline), sort candidates by distance to that rect
        if let targetRect = targetCocoaRect, targetRect.width > 0 {
            candidates.sort { a, b in
                let distA: CGFloat
                if let ra = a.expectedCocoaRect {
                    distA = hypot(ra.midX - targetRect.midX, ra.midY - targetRect.midY)
                } else {
                    distA = .greatestFiniteMagnitude
                }
                let distB: CGFloat
                if let rb = b.expectedCocoaRect {
                    distB = hypot(rb.midX - targetRect.midX, rb.midY - targetRect.midY)
                } else {
                    distB = .greatestFiniteMagnitude
                }
                return distA < distB
            }
        }

        let fullWebString = readFullWebAreaString(webArea)
        for candidate in candidates {
            if let verifiedRange = resolveVerifiedMarkerRange(for: candidate, in: webArea, fullWebString: fullWebString) {
                return (verifiedRange, candidate.matchedSubstring)
            }
        }

        return nil
    }

    @discardableResult
    private func replaceMarkerRange(
        in webArea: AXUIElement,
        markerRange: CFTypeRef,
        expectedOriginal: String,
        with replacement: String
    ) -> Bool {
        // Final safety check: never execute AXTextOperation unless the markerRange currently contains `expectedOriginal`
        if let actual = axStringForTextMarkerRange(markerRange, in: webArea) {
            let normActual = MailHTMLPreserver.normalizeTypography(actual)
            let normExpected = MailHTMLPreserver.normalizeTypography(expectedOriginal)
            guard normActual.caseInsensitiveCompare(normExpected) == .orderedSame else {
                return false
            }
        } else {
            return false
        }

        // Step 1: Focus webArea and select the target markerRange (matches WebKit's ZoneWkWebView::SelectionneIntervalle)
        _ = AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let selectDict: [String: Any] = [
            "AXTextOperationType": "TextOperationSelect",
            "AXTextOperationMarkerRanges": [markerRange]
        ]
        var selectOut: CFTypeRef?
        _ = AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXTextOperation" as CFString,
            selectDict as CFDictionary,
            &selectOut
        )

        var selectedRangeRef: CFTypeRef?
        let selErr = AXUIElementCopyAttributeValue(
            webArea,
            "AXSelectedTextMarkerRange" as CFString,
            &selectedRangeRef
        )
        let targetRange: CFTypeRef = (selErr == .success && selectedRangeRef != nil) ? selectedRangeRef! : markerRange

        // Step 2: Replace using AXReplaceRangeWithText (triggers WebKit's Editor::replaceSelectionWithText & ComposeWebViewDidChange)
        let replaceDict: [String: Any] = [
            "AXReplacementRange": targetRange,
            "AXReplacementText": replacement
        ]
        var replaceOut: CFTypeRef?
        let repErr = AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXReplaceRangeWithText" as CFString,
            replaceDict as CFDictionary,
            &replaceOut
        )
        if repErr == .success, let boolRef = replaceOut, CFGetTypeID(boolRef) == CFBooleanGetTypeID(), CFBooleanGetValue((boolRef as! CFBoolean)) {
            return true
        }

        // Fallback: AXTextOperation TextOperationReplace
        let opDict: [String: Any] = [
            "AXTextOperationType": "TextOperationReplace",
            "AXTextOperationMarkerRanges": [markerRange],
            "AXTextOperationReplacementString": replacement,
            "AXTextOperationSmartReplace": false
        ]
        var opOut: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            webArea,
            "AXTextOperation" as CFString,
            opDict as CFDictionary,
            &opOut
        )
        if err == .success, let arr = opOut as? [Any], !arr.isEmpty {
            return true
        }
        return err == .success
    }

    func activateMailApplication(_ mailApp: NSRunningApplication, composeWin: AXUIElement? = nil) {
        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: mailApp)
        }
        _ = AXUIElementSetAttributeValue(appElem, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        mailApp.activate()
        if let mailURL = mailApp.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: mailURL, configuration: config, completionHandler: nil)
        }
        if let composeWin {
            _ = AXUIElementPerformAction(composeWin, kAXRaiseAction as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                _ = AXUIElementPerformAction(composeWin, kAXRaiseAction as CFString)
            }
        }
    }

    private func ensureMailActiveAndComposeKey(mailApp: NSRunningApplication, composeWin: AXUIElement) {
        activateMailApplication(mailApp, composeWin: composeWin)
    }

    /// Applies one or more `(original, suggestion, targetCocoaRect)` replacements directly in place inside Apple Mail's `AXWebArea`
    /// using WebKit's native `AXTextOperation` API (without ⌘A / ⌘C / ⌘V).
    func applyIssueReplacementsToMail(
        _ replacements: [(original: String, suggestion: String, targetCocoaRect: CGRect?)],
        fallbackText: String
    ) async -> Result<Void, MailIntegrationError> {
        ensureMailAntiOupsDoesNotBlockSend()
        refreshStatus()
        guard isAccessibilityTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fallbackText, forType: .string)
            requestAccessibilityPermission()
            return .failure(.accessibilityNotGranted)
        }

        guard let mailApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fallbackText, forType: .string)
            return .failure(.mailNotRunning)
        }

        let appElem = AXUIElementCreateApplication(mailApp.processIdentifier)
        guard let (composeWin, webArea) = findComposeWindowAndWebArea(in: appElem) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fallbackText, forType: .string)
            return .failure(.noComposeWindowFound)
        }

        for item in replacements where !item.original.isEmpty && item.original != item.suggestion {
            let paragraphs = collectReplyParagraphNodes(from: webArea)
            if let resolved = findTextMarkerRange(
                for: item.original,
                targetCocoaRect: item.targetCocoaRect,
                in: webArea,
                paragraphs: paragraphs
            ) {
                replaceMarkerRange(
                    in: webArea,
                    markerRange: resolved.markerRange,
                    expectedOriginal: resolved.matchedSubstring,
                    with: item.suggestion
                )
            }
        }

        if let updatedMailText = extractStructuredTextFromWebArea(webArea),
           !updatedMailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.lastCapturedMailText = updatedMailText
        } else {
            self.lastCapturedMailText = fallbackText
        }

        ensureMailActiveAndComposeKey(mailApp: mailApp, composeWin: composeWin)
        return .success(())
    }

    /// Applies free-form edits from Plume's Main Editor window to Apple Mail's `AXWebArea` in place via `AXTextOperation`
    /// (diffing tokens/paragraphs against the live reply in Mail so ⌘A / ⌘C / ⌘V is never used).
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

        let liveReply = extractStructuredTextFromWebArea(webArea) ?? ""
        let diffPairs = computeContextualDiffPairs(oldText: liveReply, newText: replyToApply)

        for pair in diffPairs where !pair.original.isEmpty && pair.original != pair.suggestion {
            let paragraphs = collectReplyParagraphNodes(from: webArea)
            if let resolved = findTextMarkerRange(
                for: pair.original,
                targetCocoaRect: nil,
                in: webArea,
                paragraphs: paragraphs
            ) {
                replaceMarkerRange(
                    in: webArea,
                    markerRange: resolved.markerRange,
                    expectedOriginal: resolved.matchedSubstring,
                    with: pair.suggestion
                )
            }
        }

        // Paragraph-level reconciliation if any paragraph still differs after token-diff replacements
        let targetParagraphs = replyToApply.components(separatedBy: "\n")
        let currentParaNodes = collectReplyParagraphNodes(from: webArea)
        if currentParaNodes.count == targetParagraphs.count {
            for idx in 0..<currentParaNodes.count {
                let freshParas = collectReplyParagraphNodes(from: webArea)
                guard idx < freshParas.count else { break }
                let paraNodes = freshParas[idx]
                let currentParaText = paraNodes.map(\.text).joined()
                let targetParaText = targetParagraphs[idx]
                if currentParaText.trimmingCharacters(in: .whitespaces) != targetParaText.trimmingCharacters(in: .whitespaces),
                   !currentParaText.isEmpty,
                   let resolved = findTextMarkerRange(
                       for: currentParaText,
                       targetCocoaRect: nil,
                       in: webArea,
                       paragraphs: freshParas
                   ) {
                    replaceMarkerRange(
                        in: webArea,
                        markerRange: resolved.markerRange,
                        expectedOriginal: resolved.matchedSubstring,
                        with: targetParaText
                    )
                }
            }
        }

        if let updatedMailText = extractStructuredTextFromWebArea(webArea),
           !updatedMailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.lastCapturedMailText = updatedMailText
        }

        ensureMailActiveAndComposeKey(mailApp: mailApp, composeWin: composeWin)
        return .success(())
    }

    private func computeContextualDiffPairs(
        oldText: String,
        newText: String
    ) -> [(original: String, suggestion: String)] {
        let oldTrimmed = oldText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty, oldTrimmed != newTrimmed else {
            return []
        }

        let oldTokens = MailHTMLPreserver.tokenize(oldTrimmed)
        let newTokens = MailHTMLPreserver.tokenize(newTrimmed)
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

        var pairs: [(original: String, suggestion: String)] = []
        for op in ops {
            // Expand by 1 token on left and right if oldRange is empty or short so the target span is unambiguous
            let expandLeft = (op.oldRange.isEmpty || op.oldRange.count == 1) ? min(2, op.oldRange.lowerBound) : 0
            let expandRight = (op.oldRange.isEmpty || op.oldRange.count == 1) ? min(2, n - op.oldRange.upperBound) : 0
            let oStart = max(0, op.oldRange.lowerBound - expandLeft)
            let oEnd = min(n, op.oldRange.upperBound + expandRight)
            let nStart = max(0, op.newRange.lowerBound - expandLeft)
            let nEnd = min(m, op.newRange.upperBound + expandRight)

            let oldSlice = (oStart..<oEnd).map { oldTokens[$0].token }.joined()
            let newSlice = (nStart..<nEnd).map { newTokens[$0].token }.joined()
            if !oldSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !oldSlice.contains("\n"),
               !newSlice.contains("\n"),
               oldSlice != newSlice {
                pairs.append((original: oldSlice, suggestion: newSlice))
            }
        }
        return pairs
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
