import AppKit

@MainActor
enum UpdateUserChoice {
    case viewRelease
    case skipVersion
    case later
}

@MainActor
enum UpdateConsentChoice {
    case enable
    case decline
}

/// Every alert the update check can raise. Split out from the coordinator so the
/// coordinator's logic has a seam it can be driven through without a modal appearing.
@MainActor
struct UpdateAlertController {

    func presentConsentPrompt() -> UpdateConsentChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Check for Updates Automatically?"
        alert.informativeText = """
            Strata can check GitHub once a week and let you know when a new version is \
            available. Nothing about you or your storage accounts is sent — it is one \
            request for the repository's latest release.

            You can change this any time in Settings ▸ Updates.
            """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Not Now")

        return alert.runModal() == .alertFirstButtonReturn ? .enable : .decline
    }

    func presentUpdateAvailable(
        latest: SemanticVersion,
        current: SemanticVersion,
        release: GitHubRelease,
        offerSkip: Bool
    ) -> UpdateUserChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "A new version of Strata is available."
        alert.informativeText = "Strata \(latest) is available — you have \(current)."

        if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alert.accessoryView = Self.releaseNotesView(body: body)
        }

        alert.addButton(withTitle: "View Release on GitHub\u{2026}")
        alert.addButton(withTitle: "Later")
        // Only offered on a check the user didn't ask for. Someone who just chose
        // "Check for Updates…" wants this version's answer, not to mute it.
        if offerSkip {
            alert.addButton(withTitle: "Skip This Version")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .viewRelease
        case .alertThirdButtonReturn where offerSkip: return .skipVersion
        default: return .later
        }
    }

    func presentUpToDate(current: SemanticVersion) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're up to date."
        alert.informativeText = "Strata \(current) is the latest version available."
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    func presentNoReleaseFound() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No releases published yet."
        alert.informativeText = """
            Strata's repository has no published release to compare against, so there \
            is nothing to update to. This is also the answer you'll get while the \
            repository is private.
            """
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    func presentError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    /// Release notes are Markdown. Rendered inline-only and whitespace-preserving:
    /// enough to get bold, code, and links right without letting a heading in the
    /// notes shout over the alert's own message text.
    private static func releaseNotesView(body: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textStorage?.setAttributedString(renderedReleaseNotes(body: body))

        scroll.documentView = textView
        return scroll
    }

    private static func renderedReleaseNotes(body: String) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.textColor,
        ]
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: body, options: options) else {
            return NSAttributedString(string: body, attributes: attributes)
        }
        let rendered = NSMutableAttributedString(parsed)
        rendered.addAttributes(attributes, range: NSRange(location: 0, length: rendered.length))
        return rendered
    }
}
