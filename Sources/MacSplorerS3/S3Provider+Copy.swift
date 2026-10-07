import Foundation
import AWSS3
import MacSplorerCore

/// Server-side copy: S3 copies the object itself, so moving a 1.5 GB video between
/// folders takes seconds instead of a download and an upload through this Mac.
///
/// Before this, any drop into S3 was treated as an upload — even from the same
/// bucket — so the bytes made a round trip, a move was silently a copy, and the
/// only sign of a multi-minute transfer was a line in the status bar.
extension S3Provider {

    /// S3's limit for a single CopyObject; larger objects are copied in parts.
    static let maxSingleCopyBytes: Int64 = 5 * 1024 * 1024 * 1024
    /// Part size for multipart copies: large enough to keep the part count low
    /// (S3 allows 10,000), small enough that Stop is noticed within a few seconds.
    static let copyPartBytes: Int64 = 512 * 1024 * 1024

    /// Same profile is the test: one set of credentials can read the source and
    /// write the destination, across buckets and regions. Different profiles may
    /// be different accounts, which need the bytes to pass through this Mac.
    public func canCopyDirectly(_ source: URL, to destination: URL) async -> Bool {
        guard case .prefix(let p1, _, let k1) = S3Location.parse(source),
              case .prefix(let p2, _, let k2) = S3Location.parse(destination) else { return false }
        return p1 == p2 && !k1.isEmpty && !k1.hasSuffix("/") && !k2.isEmpty && !k2.hasSuffix("/")
    }

    public func copyDirectly(_ source: URL, to destination: URL,
                             progress: ProviderProgress?) async throws {
        guard case .prefix(let profile, let srcBucket, let srcKey) = S3Location.parse(source),
              case .prefix(_, let dstBucket, let dstKey) = S3Location.parse(destination) else {
            throw S3Error.notS3(source)
        }
        try await copyKey(profile: profile, srcBucket: srcBucket, srcKey: srcKey,
                          dstBucket: dstBucket, dstKey: dstKey,
                          name: destination.lastPathComponent, progress: progress)
    }

    /// Copy one object server-side, by key — the unit both a single copy and a
    /// folder rename are built from. Advances `progress` by one item and its bytes.
    func copyKey(profile: String, srcBucket: String, srcKey: String,
                 dstBucket: String, dstKey: String, name: String,
                 progress: ProviderProgress?) async throws {
        // The copy request goes to the DESTINATION bucket's region.
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: dstBucket)
        let srcClient = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: srcBucket)
        // x-amz-copy-source is "bucket/key", URL-encoded by the caller.
        let copySource = "\(srcBucket)/\(S3PublicLink.encodeKey(srcKey))"
        do {
            let head = try await srcClient.headObject(input: HeadObjectInput(bucket: srcBucket, key: srcKey))
            let size = Int64(head.contentLength ?? 0)
            // Keep the object's storage class; CopyObject would otherwise reset it
            // to STANDARD. (Its type, metadata and tags are copied by default.)
            let storageClass = head.storageClass.flatMap { S3ClientTypes.StorageClass(rawValue: $0.rawValue) }
            if size <= Self.maxSingleCopyBytes {
                try Task.checkCancellation()
                _ = try await client.copyObject(input: CopyObjectInput(
                    bucket: dstBucket,
                    copySource: copySource,
                    key: dstKey,
                    metadataDirective: .copy,
                    storageClass: storageClass,
                    taggingDirective: .copy))
                progress?.advance(items: 1, bytes: size, detail: name)
            } else {
                try await multipartCopy(client: client, srcClient: srcClient, head: head, size: size,
                                        copySource: copySource, srcBucket: srcBucket, srcKey: srcKey,
                                        dstBucket: dstBucket, dstKey: dstKey,
                                        storageClass: storageClass, name: name, progress: progress)
            }
        } catch {
            if error is CancellationError || error is S3Error { throw error }
            if Self.isAccessDenied(error) { throw S3Error.writeDenied(name: name, profile: profile) }
            throw Self.clarify(error, listing: "\u{201C}\(name)\u{201D}", profile: profile)
        }
    }

    /// Copy a >5 GB object in parts. Multipart copy doesn't carry the source's
    /// metadata or tags across by itself, so they're set on the new upload. Any
    /// failure or Stop aborts the upload, so no half-made object is left behind
    /// (and no orphaned parts are billed).
    func multipartCopy(client: S3Client, srcClient: S3Client, head: HeadObjectOutput,
                               size: Int64, copySource: String, srcBucket: String, srcKey: String,
                               dstBucket: String, dstKey: String,
                               storageClass: S3ClientTypes.StorageClass?, name: String,
                               progress: ProviderProgress?, contentType: String? = nil,
                               acl: S3ClientTypes.ObjectCannedACL? = nil) async throws {
        let tags = try? await srcClient.getObjectTagging(
            input: GetObjectTaggingInput(bucket: srcBucket, key: srcKey))
        let tagging = (tags?.tagSet ?? []).compactMap { tag -> String? in
            guard let k = tag.key, let v = tag.value else { return nil }
            return "\(S3PublicLink.encodeKey(k))=\(S3PublicLink.encodeKey(v))"
        }.joined(separator: "&")

        let created = try await client.createMultipartUpload(input: CreateMultipartUploadInput(
            acl: acl,
            bucket: dstBucket,
            cacheControl: head.cacheControl,
            contentDisposition: head.contentDisposition,
            contentEncoding: head.contentEncoding,
            contentLanguage: head.contentLanguage,
            contentType: contentType ?? head.contentType,
            key: dstKey,
            metadata: head.metadata,
            serverSideEncryption: head.serverSideEncryption,
            ssekmsKeyId: head.ssekmsKeyId,
            storageClass: storageClass,
            tagging: tagging.isEmpty ? nil : tagging))
        guard let uploadId = created.uploadId else { throw S3Error.notS3(URL(string: "s3:///")!) }

        do {
            var parts: [S3ClientTypes.CompletedPart] = []
            var offset: Int64 = 0
            var number = 1
            while offset < size {
                try Task.checkCancellation()
                if progress?.isCancelled == true { throw CancellationError() }
                let end = min(offset + Self.copyPartBytes, size) - 1
                let part = try await client.uploadPartCopy(input: UploadPartCopyInput(
                    bucket: dstBucket,
                    copySource: copySource,
                    copySourceRange: "bytes=\(offset)-\(end)",
                    key: dstKey,
                    partNumber: number,
                    uploadId: uploadId))
                parts.append(S3ClientTypes.CompletedPart(eTag: part.copyPartResult?.eTag,
                                                         partNumber: number))
                progress?.advance(items: 0, bytes: end - offset + 1, detail: name)
                offset = end + 1
                number += 1
            }
            _ = try await client.completeMultipartUpload(input: CompleteMultipartUploadInput(
                bucket: dstBucket,
                key: dstKey,
                multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: parts),
                uploadId: uploadId))
            progress?.advance(items: 1, bytes: 0, detail: name)
        } catch {
            _ = try? await client.abortMultipartUpload(input: AbortMultipartUploadInput(
                bucket: dstBucket, key: dstKey, uploadId: uploadId))
            throw error
        }
    }
}

// MARK: - Rename (empty folders)

extension S3Provider {
    /// Rename an EMPTY folder: write the new marker, then delete the old one — two
    /// tiny requests, which is what lets S3's New Folder name itself in place like
    /// a local one. A file, or a folder with contents, is refused: S3 has no rename,
    /// so those would mean copying everything and deleting the originals.
    public func renameAsync(_ url: URL, to newName: String) async throws -> URL {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url),
              !key.isEmpty else { throw S3Error.notS3(url) }
        let oldName = url.lastPathComponent
        guard key.hasSuffix("/") || url.hasDirectoryPath else {
            throw S3Error.renameUnsupported(name: oldName)
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw S3Error.invalidFolderName(name: name) }
        let oldKey = Self.folderKey(key)
        let parentKey = String(oldKey.dropLast().split(separator: "/", omittingEmptySubsequences: false)
                                    .dropLast().joined(separator: "/"))
        let newKey = (parentKey.isEmpty ? "" : parentKey + "/") + name + "/"
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)
        do {
            // Empty means nothing under the prefix but the marker itself.
            let inside = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket, maxKeys: 2, prefix: oldKey))
            guard (inside.contents ?? []).allSatisfy({ $0.key == oldKey }) else {
                throw S3Error.renameUnsupported(name: oldName)
            }
            let taken = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket, maxKeys: 1, prefix: newKey))
            guard (taken.contents ?? []).isEmpty else { throw CocoaError(.fileWriteFileExists) }
            _ = try await client.putObject(input: PutObjectInput(body: .data(Data()), bucket: bucket, key: newKey))
            _ = try await client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: oldKey))
        } catch {
            if error is S3Error || error is CocoaError { throw error }
            if Self.isAccessDenied(error) { throw S3Error.writeDenied(name: name, profile: profile) }
            throw Self.clarify(error, listing: "\u{201C}\(name)\u{201D}", profile: profile)
        }
        return S3Location.childFolderURL(under: url.deletingLastPathComponent(), name: name)
    }
}

// MARK: - Rename (files and folders with contents)

extension S3Provider {
    /// Rename a file, or a folder with contents. S3 has no rename, so it's a
    /// server-side copy of everything to the new name, then a delete of the
    /// originals — in that order, so nothing is lost:
    ///
    /// 1. Copy every object (the exact list taken up front).
    /// 2. Only once ALL copies have succeeded, delete exactly those originals —
    ///    never anything that appeared in the folder meanwhile.
    /// 3. On Stop or any failure during copying, remove the copies made so far and
    ///    leave the originals untouched.
    ///
    /// Empty folders take the cheap path (`renameAsync`).
    public func renameWithProgress(_ url: URL, to newName: String,
                                   progress: ProviderProgress?) async throws -> URL {
        guard case .prefix(let profile, let bucket, let key) = S3Location.parse(url),
              !key.isEmpty else { throw S3Error.notS3(url) }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { throw S3Error.invalidFolderName(name: name) }
        let isFolder = key.hasSuffix("/") || url.hasDirectoryPath
        let client = try await S3ClientPool.shared.clientForBucket(profile: profile, bucket: bucket)

        if !isFolder {
            let parent = key.contains("/") ? String(key[..<key.lastIndex(of: "/")!]) + "/" : ""
            let newKey = parent + name
            let newURL = S3Location.childFileURL(under: url.deletingLastPathComponent(), name: name)
            if await exists(newURL) { throw CocoaError(.fileWriteFileExists) }
            progress?.setTotal(1, isPartial: false)
            try await copyKey(profile: profile, srcBucket: bucket, srcKey: key,
                              dstBucket: bucket, dstKey: newKey, name: name, progress: progress)
            do {
                _ = try await client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
            } catch {
                // The copy is complete; only the original's removal failed.
                throw S3Error.cannotDelete(name: url.lastPathComponent,
                                           reason: "the file was copied to \u{201C}\(name)\u{201D}, "
                                               + "but the original couldn\u{2019}t be removed")
            }
            return newURL
        }

        let oldPrefix = Self.folderKey(key)
        let parentKey = String(oldPrefix.dropLast().split(separator: "/", omittingEmptySubsequences: false)
                                    .dropLast().joined(separator: "/"))
        let newPrefix = (parentKey.isEmpty ? "" : parentKey + "/") + name + "/"
        let newURL = S3Location.childFolderURL(under: url.deletingLastPathComponent(), name: name)

        // The exact list of what will be copied (and later deleted).
        var objects: [(key: String, size: Int64)] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket, continuationToken: token, maxKeys: 1000, prefix: oldPrefix))
            objects += (page.contents ?? []).compactMap { o in o.key.map { ($0, Int64(o.size ?? 0)) } }
            token = page.nextContinuationToken
        } while token != nil
        if objects.allSatisfy({ $0.key == oldPrefix }) {
            return try await renameAsync(url, to: name)     // empty: marker swap
        }
        let taken = try await client.listObjectsV2(input: ListObjectsV2Input(
            bucket: bucket, maxKeys: 1, prefix: newPrefix))
        guard (taken.contents ?? []).isEmpty else { throw CocoaError(.fileWriteFileExists) }

        progress?.setTotal(objects.count, isPartial: false)
        var created: [String] = []
        do {
            for object in objects {
                if progress?.isCancelled == true { throw CancellationError() }
                try Task.checkCancellation()
                let dstKey = newPrefix + object.key.dropFirst(oldPrefix.count)
                try await copyKey(profile: profile, srcBucket: bucket, srcKey: object.key,
                                  dstBucket: bucket, dstKey: dstKey,
                                  name: (object.key as NSString).lastPathComponent, progress: progress)
                created.append(dstKey)
            }
        } catch {
            // Undo: remove the partial copy; the originals were never touched.
            try? await deleteKeys(created, bucket: bucket, client: client)
            throw error
        }
        // Every copy landed: now remove exactly the originals that were copied.
        try await deleteKeys(objects.map(\.key), bucket: bucket, client: client)
        return newURL
    }

    /// Delete these exact keys, in batches of 1,000 (DeleteObjects' limit).
    private func deleteKeys(_ keys: [String], bucket: String, client: S3Client) async throws {
        var start = 0
        while start < keys.count {
            let batch = keys[start..<min(start + 1000, keys.count)]
            let result = try await client.deleteObjects(input: DeleteObjectsInput(
                bucket: bucket,
                delete: S3ClientTypes.Delete(objects: batch.map { S3ClientTypes.ObjectIdentifier(key: $0) },
                                             quiet: true)))
            if let failure = result.errors?.first {
                throw S3Error.cannotDelete(name: failure.key ?? "an object",
                                           reason: failure.message ?? "S3 refused the delete")
            }
            start += 1000
        }
    }
}
