import AppKit
import UniformTypeIdentifiers
import MacSplorerS3

/// Copy Public Link and Set Public Address… — plain links to S3 objects in buckets
/// served publicly (typically through CloudFront at the user's own domain).
///
/// The bucket's public address is asked for once, remembered per bucket, and
/// changed from the bucket's right-click menu or by holding Option while copying.
/// A remembered address can go stale, so every copy is followed by an anonymous
/// request for the link: if it fails, or would download something a browser should
/// play, the user is told right away rather than finding out from whoever they
/// sent it to.
@MainActor
enum S3PublicLinkCommand {

    /// Copy public links for the S3 objects among `urls` (one per line). Folders
    /// and non-S3 items are skipped. With `forcePrompt` (Option held), the bucket's
    /// address is asked for again first.
    static func copy(_ urls: [URL], forcePrompt: Bool) {
        let objects: [(profile: String, bucket: String, key: String)] = urls.compactMap { url in
            guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url),
                  !key.isEmpty, !key.hasSuffix("/") else { return nil }
            return (profile, bucket, key)
        }
        guard let first = objects.first,
              let firstURL = urls.first(where: {
                  if case .prefix(_, _, let k) = S3Location.parse($0) { return !k.isEmpty && !k.hasSuffix("/") }
                  return false
              }) else { return }
        Task { @MainActor in
            var bases: [String: String] = [:]
            for object in objects where bases[object.bucket] == nil {
                let saved = Preferences.shared.s3PublicAddresses[object.bucket]
                if let saved, !forcePrompt {
                    bases[object.bucket] = saved
                } else {
                    guard let chosen = await askForAddress(profile: object.profile,
                                                           bucket: object.bucket,
                                                           current: saved) else { return }
                    bases[object.bucket] = chosen
                }
            }
            let links = objects.compactMap { o in bases[o.bucket].flatMap { S3PublicLink.link(base: $0, key: o.key) } }
            guard !links.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.map(\.absoluteString).joined(separator: "\n"),
                                           forType: .string)
            // Check the first link: one request answers "is this address right?"
            // for the whole bucket.
            if let link = links.first {
                await verify(link: link, source: firstURL, key: first.key, profile: first.profile,
                             bucket: first.bucket, others: links.count - 1,
                             retry: { copy(urls, forcePrompt: false) })
            }
        }
    }

    /// Set Public Address… on a bucket: ask for (or change) its public address.
    static func setAddress(forBucketURL url: URL) {
        guard case .prefix(let profile, let bucket, _) = S3Location.parse(url) else { return }
        Task { @MainActor in
            _ = await askForAddress(profile: profile, bucket: bucket,
                                    current: Preferences.shared.s3PublicAddresses[bucket])
        }
    }

    /// Whether `url` is an S3 bucket itself (where Set Public Address… is offered).
    nonisolated static func isBucket(_ url: URL) -> Bool {
        if case .prefix(_, _, let key) = S3Location.parse(url) { return key.isEmpty }
        return false
    }

    // MARK: - Prompt

    /// Ask for the bucket's public address, pre-filled with the current one or the
    /// bucket's own S3 address. Saves and returns the normalized address, or nil
    /// if cancelled.
    private static func askForAddress(profile: String, bucket: String,
                                      current: String?) async -> String? {
        let fallback: String
        if let current {
            fallback = current
        } else {
            let region = await S3PublicLink.region(profile: profile, bucket: bucket)
            fallback = S3PublicLink.defaultBase(bucket: bucket, region: region)
        }
        var text = fallback
        while true {
            let alert = NSAlert()
            alert.messageText = "Public address for “\(bucket)”"
            alert.informativeText =
                "Where people reach this bucket’s files on the web. If it’s served through "
                + "CloudFront or another CDN, enter that address (for example "
                + "https://example.com/). Otherwise keep the bucket’s own S3 address.\n\n"
                + "MacSplorer remembers this for every file in the bucket. To change it later, "
                + "right-click the bucket ▸ Set Public Address…, or hold Option while choosing "
                + "Copy Public Link."
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            text = field.stringValue
            if let base = S3PublicLink.normalizedBase(text) {
                Preferences.shared.s3PublicAddresses[bucket] = base
                return base
            }
            let bad = NSAlert()
            bad.messageText = "That isn’t a web address MacSplorer can use."
            bad.informativeText = "Enter something like https://example.com/ — an http or https "
                + "address with a host name, and no ? or # part."
            bad.addButton(withTitle: "OK")
            bad.runModal()
        }
    }

    // MARK: - Check

    /// Request the link anonymously, as a browser would, and speak up if it won't
    /// work as intended. Silent when all is well.
    private static func verify(link: URL, source: URL, key: String, profile: String, bucket: String,
                               others: Int, retry: @escaping @MainActor () -> Void) async {
        var request = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let status: Int
        let mime: String?
        do {
            let (_, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            mime = http?.mimeType?.lowercased()
        } catch {
            report(failure: "couldn’t be reached (\(error.localizedDescription))",
                   link: link, profile: profile, bucket: bucket, others: others, retry: retry)
            return
        }
        guard (200..<400).contains(status) else {
            let reason: String
            switch status {
            case 403: reason = "was refused (403 Forbidden) — the file isn’t public at this address"
            case 404: reason = "wasn’t found there (404 Not Found)"
            default: reason = "failed (HTTP \(status))"
            }
            report(failure: reason, link: link, profile: profile, bucket: bucket, others: others,
                   retry: retry)
            return
        }
        // Works — but will a browser play/show it, or download it?
        let ext = (key as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext),
              type.conforms(to: .audiovisualContent) || type.conforms(to: .html)
                || type.conforms(to: .image) || type.conforms(to: .pdf) else { return }
        let generic = mime == nil || mime == "application/octet-stream"
            || mime == "binary/octet-stream" || mime == "application/x-download"
        guard generic else { return }
        let alert = NSAlert()
        alert.messageText = "Link copied — but browsers will download this file, not show it."
        alert.informativeText =
            "S3 is serving it as “\(mime ?? "no type")”, so a browser saves it instead of playing "
            + "or displaying it. Fixing that means changing the file’s stored content type "
            + "(\(type.preferredMIMEType ?? "the right type for ."+ext)) in S3. Until then, "
            + "Copy Temporary Link… can produce a link that plays."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Fix Content Type Now")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            await S3ContentTypeCommand.fix([source])
        }
    }

    /// The link didn't work: say so, and offer to change the bucket's address.
    private static func report(failure: String, link: URL, profile: String, bucket: String,
                               others: Int, retry: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "The link was copied, but it doesn’t work."
        alert.informativeText =
            "\(link.absoluteString)\n\(failure).\n\n"
            + (others > 0 ? "The other \(others) link\(others == 1 ? "" : "s") use the same address. " : "")
            + "If “\(bucket)” is served from a different address, change it and the links "
            + "will be copied again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Change Address…")
        alert.addButton(withTitle: "Keep")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor in
                let changed = await askForAddress(profile: profile, bucket: bucket,
                                                  current: Preferences.shared.s3PublicAddresses[bucket])
                if changed != nil { retry() }
            }
        }
    }
}
