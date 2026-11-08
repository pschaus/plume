import AppKit
import SwiftUI

struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var issues: [SpellIssue]
    @Binding var selectedIssueID: UUID?
    var onTextEdited: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? ClickableSpellTextView else {
            let tv = ClickableSpellTextView(frame: scrollView.bounds)
            configureTextView(tv, coordinator: context.coordinator)
            scrollView.documentView = tv
            context.coordinator.textView = tv
            return scrollView
        }

        configureTextView(textView, coordinator: context.coordinator)
        context.coordinator.textView = textView
        return scrollView
    }

    private func configureTextView(_ textView: ClickableSpellTextView, coordinator: Coordinator) {
        textView.delegate = coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false // Use our AI highlights instead of macOS default red lines
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.onCharacterIndexClicked = { charIndex in
            coordinator.handleClick(atCharacterIndex: charIndex)
        }
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.isProgrammaticUpdate = false
        }

        context.coordinator.applyHighlights()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedTextEditor
        weak var textView: ClickableSpellTextView?
        var isProgrammaticUpdate = false
        private var issueRanges: [(range: NSRange, issue: SpellIssue)] = []

        init(_ parent: HighlightedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let tv = textView else { return }
            parent.text = tv.string
            parent.onTextEdited()
            applyHighlights()
        }

        func applyHighlights() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let fullString = tv.string
            let fullRange = NSRange(location: 0, length: (fullString as NSString).length)

            storage.beginEditing()

            // Reset base styling
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 5

            storage.setAttributes([
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ], range: fullRange)

            issueRanges.removeAll()
            let nsString = fullString as NSString

            for issue in parent.issues {
                guard !issue.original.isEmpty else { continue }
                var searchRange = NSRange(location: 0, length: nsString.length)
                while searchRange.location < nsString.length {
                    let foundRange = nsString.range(of: issue.original, options: [], range: searchRange)
                    if foundRange.location == NSNotFound {
                        break
                    }
                    issueRanges.append((foundRange, issue))

                    let isSelected = (parent.selectedIssueID == issue.id)
                    let baseColor = issue.type.nsColor
                    let bgAlpha: CGFloat = isSelected ? 0.28 : 0.13

                    storage.addAttributes([
                        .underlineStyle: NSUnderlineStyle.thick.rawValue,
                        .underlineColor: baseColor,
                        .backgroundColor: baseColor.withAlphaComponent(bgAlpha)
                    ], range: foundRange)

                    let nextLoc = foundRange.location + max(1, foundRange.length)
                    searchRange = NSRange(location: nextLoc, length: nsString.length - nextLoc)
                }
            }

            storage.endEditing()
        }

        func handleClick(atCharacterIndex charIndex: Int) {
            for item in issueRanges {
                if NSLocationInRange(charIndex, item.range) {
                    parent.selectedIssueID = item.issue.id
                    applyHighlights()
                    return
                }
            }
        }
    }
}

final class ClickableSpellTextView: NSTextView {
    var onCharacterIndexClicked: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        onCharacterIndexClicked?(charIndex)
    }
}
