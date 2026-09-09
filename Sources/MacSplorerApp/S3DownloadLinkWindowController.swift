import AppKit
import UniformTypeIdentifiers
import MacSplorerCore
import MacSplorerS3

/// A small panel for generating a presigned S3 **download link** for one object:
/// pick how long it lasts (hours or days) and whether it streams in a browser or
/// forces a download, then copy the URL. When the profile uses temporary
/// credentials (SSO / assumed role), it warns that the link can't outlive the
/// session and caps the duration accordingly. See `S3Presign`.
final class S3DownloadLinkWindowController: NSWindowController, NSWindowDelegate {
    let objectURL: URL
    private let profile: String

    private let durationField = NSTextField()
    private let unitPopUp = NSPopUpButton()
    private let modeControl = NSSegmentedControl()
    private let contentTypeCombo = NSComboBox()
    private let noteLabel = NSTextField(labelWithString: "")

    /// Combo sentinel meaning "don't override — serve the object's stored type".
    private static let automaticContentType = "Automatic (keep stored type)"
    private let resultView = NSTextView()
    private let resultScroll = NSScrollView()
    private let expiryLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()

    /// Resolved credential kind for this profile; caps the offered duration.
    private var credentialKind: S3Presign.CredentialKind = .longTerm
    /// Guards against overlapping generate requests.
    private var isGenerating = false

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
        NSLayoutConstraint.activate([durationField.widthAnchor.constraint(equalToConstant: 56)])
        unitPopUp.addItems(withTitles: ["Hours", "Days"])

        let modeLabel = NSTextField(labelWithString: "When opened:")
        modeControl.segmentCount = 2
        modeControl.setLabel("Stream in browser", forSegment: 0)
        modeControl.setLabel("Download file", forSegment: 1)
        modeControl.selectedSegment = 1
        modeControl.segmentStyle = .rounded
        modeControl.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let contentTypeLabel = NSTextField(labelWithString: "Content type:")
        contentTypeCombo.usesDataSource = false
        contentTypeCombo.completes = true
        contentTypeCombo.addItems(withObjectValues: contentTypeChoices())
        contentTypeCombo.stringValue = Self.automaticContentType
        contentTypeCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([contentTypeCombo.widthAnchor.constraint(equalToConstant: 260)])

        let modeHint = NSTextField(wrappingLabelWithString:
            "Stream lets audio/video play in place (Content-Disposition: inline); "
            + "Download forces a “Save As” with the file’s name (attachment). "
            + "Override the content type only if the object’s stored type is wrong and "
            + "keeps a media file from streaming; “Automatic” serves the stored type.")
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
        if let guessed = UTType(filenameExtension: objectURL.pathExtension.lowercased())?
            .preferredMIMEType, !guessed.isEmpty {
            choices.append(guessed)   // the likely-correct type, one click away
        }
        for preset in presets where !choices.contains(preset) { choices.append(preset) }
        return choices
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
                self.copyButton.isEnabled = true
                self.copyButton.title = "Copy Link"
            }
            do {
                let link = try await S3Presign.downloadURL(
                    for: url, expiration: effective, disposition: disposition,
                    filename: name, contentType: contentType)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                self.showResult(link.absoluteString, expiry: expiryDate, capped: capped)
            } catch {
                self.presentError((error as? LocalizedError)?.errorDescription
                                  ?? error.localizedDescription)
            }
        }
    }

    private func requestedSeconds() -> TimeInterval {
        let value = max(1, Double(durationField.integerValue))
        let perUnit: Double = unitPopUp.indexOfSelectedItem == 1 ? 86_400 : 3_600
        return value * perUnit
    }

    private func showResult(_ link: String, expiry: Date, capped: Bool) {
        resultView.string = link
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
