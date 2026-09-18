import AppKit
import UniformTypeIdentifiers
import MacSplorerCore
import MacSplorerS3

/// A small panel for generating a presigned S3 **download link** for one object:
/// pick how long it lasts (hours or days) and whether it streams in a browser or
/// forces a download, then copy the URL. When the profile uses temporary
/// credentials (SSO / assumed role), it warns that the link can't outlive the
/// session and caps the duration accordingly. See `S3Presign`.
final class S3DownloadLinkWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    let objectURL: URL
    private let profile: String

    private let durationField = NSTextField()
    private let unitPopUp = NSPopUpButton()
    private let modeControl = NSSegmentedControl()
    private let contentTypeCombo = NSComboBox()
    private let noteLabel = NSTextField(labelWithString: "")

    /// Combo sentinel meaning "don't override — serve the type S3 stores for it".
    private static let automaticContentType = "Stored type"
    private let resultView = NSTextView()
    private let resultScroll = NSScrollView()
    private let expiryLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()

    /// Resolved credential kind for this profile; caps the offered duration.
    private var credentialKind: S3Presign.CredentialKind = .longTerm
    /// Guards against overlapping generate requests.
    private var isGenerating = false
    /// Whether the link on screen (and on the clipboard) matches the current settings.
    /// While it does, Copy Link has nothing new to do and stays disabled; any change to
    /// a setting makes it stale and enables the button again.
    private var linkIsCurrent = false

    var onClose: (() -> Void)?

    init(objectURL: URL, profile: String) {
        self.objectURL = objectURL
        self.profile = profile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Copy Download Link"
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
        Task { await self.resolveCredentialKind() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var objectName: String { objectURL.lastPathComponent }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let pad: CGFloat = 16

        let heading = NSTextField(labelWithString: "Download link for “\(objectName)”")
        heading.font = .boldSystemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingMiddle

        let durationLabel = NSTextField(labelWithString: "Expires in:")
        durationField.stringValue = "24"
        durationField.alignment = .right
        durationField.formatter = positiveIntFormatter()
        durationField.delegate = self
        NSLayoutConstraint.activate([durationField.widthAnchor.constraint(equalToConstant: 56)])
        unitPopUp.addItems(withTitles: ["Hours", "Days"])
        unitPopUp.target = self
        unitPopUp.action = #selector(settingsChanged)

        let modeLabel = NSTextField(labelWithString: "When opened:")
        modeControl.segmentCount = 2
        modeControl.setLabel("Stream in browser", forSegment: 0)
        modeControl.setLabel("Download file", forSegment: 1)
        modeControl.selectedSegment = 1
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let contentTypeLabel = NSTextField(labelWithString: "Content type:")
        contentTypeCombo.usesDataSource = false
        contentTypeCombo.completes = true
        contentTypeCombo.addItems(withObjectValues: contentTypeChoices())
        // Start from the extension's usual type rather than "Automatic": objects are
        // often stored with a generic type, and then a video won't stream until the
        // right one is sent — which is easy to miss.
        contentTypeCombo.stringValue = guessedContentType ?? Self.automaticContentType
        contentTypeCombo.delegate = self
        contentTypeCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([contentTypeCombo.widthAnchor.constraint(equalToConstant: 260)])

        let modeHint = NSTextField(wrappingLabelWithString:
            "Stream lets audio/video play in place (Content-Disposition: inline); "
            + "Download forces a “Save As” with the file’s name (attachment). "
            + "The content type starts as the usual one for the file’s extension, which "
            + "lets media stream even when it was stored with a generic type; choose "
            + "“Stored type” to serve the type S3 holds for the object instead.")
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = .secondaryLabelColor

        noteLabel.maximumNumberOfLines = 3
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.stringValue = "Checking credentials…"

        // Result: a read-only, selectable URL and its expiry — hidden until generated.
        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.drawsBackground = false
        resultView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultView.textContainerInset = NSSize(width: 4, height: 4)
        resultScroll.documentView = resultView
        resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .bezelBorder
        resultScroll.isHidden = true
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([resultScroll.heightAnchor.constraint(equalToConstant: 66)])

        expiryLabel.font = .systemFont(ofSize: 11)
        expiryLabel.textColor = .secondaryLabelColor
        expiryLabel.isHidden = true

        copyButton.title = "Copy Link"
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.target = self
        copyButton.action = #selector(copyLink)

        let close = NSButton()
        close.title = "Close"
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"   // Esc
        close.target = self
        close.action = #selector(closeWindow)

        let durationRow = NSStackView(views: [durationLabel, durationField, unitPopUp])
        durationRow.orientation = .horizontal
        durationRow.spacing = 8
        let modeRow = NSStackView(views: [modeLabel, modeControl])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        let contentTypeRow = NSStackView(views: [contentTypeLabel, contentTypeCombo])
        contentTypeRow.orientation = .horizontal
        contentTypeRow.spacing = 8
        let buttonRow = NSStackView(views: [close, copyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [
            heading, durationRow, modeRow, contentTypeRow, modeHint, noteLabel,
            resultScroll, expiryLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(4, after: contentTypeRow)     // hint hugs the controls
        stack.setCustomSpacing(16, after: noteLabel)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -pad),
            resultScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            resultScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    /// Combo entries: "Automatic", the object's own guessed type (from its
    /// extension, if recognized), then common streamable/downloadable presets.
    private func contentTypeChoices() -> [String] {
        var choices = [Self.automaticContentType]
        let presets = ["video/mp4", "audio/mpeg", "audio/mp4", "application/pdf",
                       "image/jpeg", "image/png", "text/plain", "application/octet-stream"]
        if let guessed = guessedContentType {
            choices.append(guessed)   // the likely-correct type, one click away
        }
        for preset in presets where !choices.contains(preset) { choices.append(preset) }
        return choices
    }

    /// The usual MIME type for the object's extension, if the system recognizes it.
    private var guessedContentType: String? {
        guard let type = UTType(filenameExtension: objectURL.pathExtension.lowercased())?
            .preferredMIMEType, !type.isEmpty else { return nil }
        return type
    }

    /// The Content-Type override to send, or nil for "Automatic" (keep stored type).
    private func overrideContentType() -> String? {
        let value = contentTypeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != Self.automaticContentType else { return nil }
        return value
    }

    private func positiveIntFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 3650
        f.allowsFloats = false
        return f
    }

    // MARK: - Credentials

    private func resolveCredentialKind() async {
        let kind = (try? await S3Presign.credentialKind(profile: profile)) ?? .longTerm
        await MainActor.run {
            self.credentialKind = kind
            self.updateNote()
        }
    }

    private func updateNote() {
        switch credentialKind {
        case .longTerm:
            noteLabel.stringValue =
                "Anyone with this link can download the object until it expires "
                + "(no AWS sign-in needed). Maximum lifetime is 7 days."
            noteLabel.textColor = .secondaryLabelColor
        case .temporary(let expiry):
            var msg = "Profile “\(profile)” uses temporary credentials (SSO or a role), "
                    + "so the link can’t outlive your session"
            if let expiry {
                msg += " — which ends \(Self.relative(expiry)). Longer durations are capped."
            } else {
                msg += ". Longer durations may be capped."
            }
            noteLabel.stringValue = msg
            noteLabel.textColor = .systemOrange
        }
    }

    // MARK: - Generate

    @objc private func copyLink() {
        guard !isGenerating else { return }
        let requested = requestedSeconds()
        let effective = S3Presign.effectiveExpiration(
            requested: requested, kind: credentialKind, now: Date())
        guard effective >= 1 else {
            presentError("Your session has expired. Log in again "
                       + "(e.g. aws sso login --profile \(profile)) and retry.")
            return
        }
        let disposition: S3Presign.Disposition =
            modeControl.selectedSegment == 0 ? .inline : .attachment
        let contentType = overrideContentType()
        let name = objectName
        isGenerating = true
        copyButton.isEnabled = false
        copyButton.title = "Generating…"
        let url = objectURL
        let expiryDate = Date().addingTimeInterval(effective)
        let capped = effective < requested - 0.5
        Task { @MainActor in
            defer {
                self.isGenerating = false
                self.copyButton.title = "Copy Link"
                self.updateCopyButton()
            }
            do {
                let link = try await S3Presign.downloadURL(
                    for: url, expiration: effective, disposition: disposition,
                    filename: name, contentType: contentType)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                self.showResult(link.absoluteString, expiry: expiryDate, capped: capped)
                self.linkIsCurrent = true
            } catch {
                self.linkIsCurrent = false
                self.presentError((error as? LocalizedError)?.errorDescription
                                  ?? error.localizedDescription)
            }
        }
    }

    /// Copy Link is useful only when there's no link yet, or the settings have changed
    /// since the one on screen was made.
    private func updateCopyButton() {
        copyButton.isEnabled = !isGenerating && !linkIsCurrent
    }

    /// Streaming needs the right content type to play in place, so switching to Stream
    /// fills in the extension's usual type if the choice was left at "Automatic".
    @objc private func modeChanged() {
        if modeControl.selectedSegment == 0,
           contentTypeCombo.stringValue == Self.automaticContentType,
           let guessed = guessedContentType {
            contentTypeCombo.stringValue = guessed
        }
        settingsChanged()
    }

    /// A setting that feeds into the link changed: the link shown no longer matches
    /// them, so say so and let Copy Link make a new one.
    @objc private func settingsChanged() {
        guard linkIsCurrent || !resultScroll.isHidden else {
            updateCopyButton()
            return
        }
        linkIsCurrent = false
        resultView.textColor = .tertiaryLabelColor
        expiryLabel.stringValue = "Settings changed — Copy Link to make a new link."
        expiryLabel.textColor = .secondaryLabelColor
        updateCopyButton()
    }

    private func requestedSeconds() -> TimeInterval {
        let value = max(1, Double(durationField.integerValue))
        let perUnit: Double = unitPopUp.indexOfSelectedItem == 1 ? 86_400 : 3_600
        return value * perUnit
    }

    private func showResult(_ link: String, expiry: Date, capped: Bool) {
        resultView.string = link
        resultView.textColor = .labelColor
        resultScroll.isHidden = false
        var text = "Copied to clipboard · expires \(Self.absolute(expiry))"
        if capped { text += " (capped to your session)" }
        expiryLabel.stringValue = text
        expiryLabel.textColor = capped ? .systemOrange : .secondaryLabelColor
        expiryLabel.isHidden = false
        window?.setContentSize(NSSize(width: 520, height: 420))
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t create a download link"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func closeWindow() { window?.close() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: - Watching the settings

    /// Typing in the duration or content-type fields changes the link too.
    func controlTextDidChange(_ obj: Notification) { settingsChanged() }

    /// Picking a content type from the list. The combo box still holds the previous
    /// value at this point, but nothing here reads it — the link is regenerated from
    /// the controls only when Copy Link is clicked, by which time it's up to date.
    func comboBoxSelectionDidChange(_ notification: Notification) { settingsChanged() }

    // MARK: - Date formatting

    private static func absolute(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func relative(_ date: Date) -> String {
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
