import AppKit
import MacSplorerCore
import MacSplorerS3

/// Fix Content Type — the "Fix Content Type Now" button in Copy Public Link's
/// "browsers will download this" alert. Sets each file's type from its extension,
/// clears the fixed files from any CloudFront distribution serving the bucket, and
/// then says what happened, file by file in aggregate.
@MainActor
enum S3ContentTypeCommand {

    /// Fix `urls` (non-S3 items and folders are skipped). `begin`/`end` let a pane
    /// show progress with Stop; callers without one pass nothing.
    static func fix(_ urls: [URL],
                    begin: ((ProviderProgress) -> Void)? = nil,
                    end: (() -> Void)? = nil) async {
        let files = urls.filter {
            if case .prefix(_, _, let key) = S3Location.parse($0) { return !key.isEmpty && !key.hasSuffix("/") }
            return false
        }
        guard !files.isEmpty else { return }
        let progress = ProviderProgress()
        progress.setTotal(files.count, isPartial: false)
        begin?(progress)

        var outcomes: [S3ContentType.Outcome] = []
        var fixedKeys: [String: [String]] = [:]       // "profile|bucket" -> keys fixed
        var failure: (name: String, error: Error)?
        for url in files {
            if progress.isCancelled { break }
            do {
                let outcome = try await S3ContentType.fix(url, progress: progress)
                outcomes.append(outcome)
                if outcome.kind == .fixed, case .prefix(let profile, let bucket, let key) = S3Location.parse(url) {
                    fixedKeys["\(profile)|\(bucket)", default: []].append(key)
                }
            } catch is CancellationError {
                break
            } catch {
                if failure == nil { failure = (url.lastPathComponent, error) }
            }
        }

        var cdn = S3ContentType.CDNResult()
        for (place, keys) in fixedKeys {
            let parts = place.split(separator: "|", maxSplits: 1).map(String.init)
            progress.advance(items: 0, detail: "clearing CloudFront cache")
            let r = await S3ContentType.clearCDN(profile: parts[0], bucket: parts[1], keys: keys)
            cdn.invalidated += r.invalidated
            if cdn.problem == nil { cdn.problem = r.problem }
        }
        end?()
        report(outcomes, cdn: cdn, failure: failure, stopped: progress.isCancelled)
    }

    private static func report(_ outcomes: [S3ContentType.Outcome], cdn: S3ContentType.CDNResult,
                               failure: (name: String, error: Error)?, stopped: Bool) {
        let fixed = outcomes.filter { $0.kind == .fixed }
        let right = outcomes.filter { $0.kind == .alreadyRight }
        let unknown = outcomes.filter { $0.kind == .unknownType }

        var lines: [String] = []
        if fixed.count == 1, let f = fixed.first {
            lines.append("“\(f.name)” is now served as \(f.to ?? "?") (was \(f.from ?? "no type")).")
        } else if !fixed.isEmpty {
            lines.append("\(fixed.count) files now have the type their extension implies.")
        }
        if !right.isEmpty {
            lines.append("\(right.count) already had the right type and \(right.count == 1 ? "was" : "were") left alone.")
        }
        if !unknown.isEmpty {
            let names = unknown.prefix(3).map { "“\($0.name)”" }.joined(separator: ", ")
            lines.append("No known type for \(names)\(unknown.count > 3 ? " and \(unknown.count - 3) more" : ""), so "
                         + "\(unknown.count == 1 ? "it was" : "they were") left alone.")
        }
        if !fixed.isEmpty {
            if !cdn.invalidated.isEmpty {
                lines.append("Cleared from CloudFront’s cache (\(cdn.invalidated.count) distribution"
                             + "\(cdn.invalidated.count == 1 ? "" : "s")); the change shows within a few minutes.")
            } else if let problem = cdn.problem {
                lines.append("Couldn’t clear CloudFront’s cache: \(problem). If a CDN serves this bucket, "
                             + "it may keep serving the old type until its copy expires.")
            }
        }
        if stopped { lines.append("Stopped before every file was done.") }
        if let failure { lines.append("“\(failure.name)” couldn’t be fixed: \(failure.error.localizedDescription)") }

        let alert = NSAlert()
        alert.messageText = failure != nil ? "Some content types couldn’t be fixed."
            : fixed.isEmpty ? "Nothing needed fixing." : "Content type fixed."
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.alertStyle = failure != nil ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
