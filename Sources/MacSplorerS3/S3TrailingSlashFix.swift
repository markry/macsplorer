import Foundation
import AWSS3
import ClientRuntime
import SmithyHTTPAPI

/// Works around the AWS SDK for Swift dropping a trailing "/" from object keys.
///
/// S3 has no folders: a "folder" is a zero-byte object whose key ends in "/",
/// the convention the AWS console uses. The SDK loses that final "/" while it
/// builds the request path, so `PutObject(key: "Archive/")` stored an object named
/// "Archive" — every New Folder since 0.10 made a plain empty file instead.
/// (Found 2026-10-06 with a probe: the path is already stripped when it reaches
/// the signing step; restoring it there, before the signature is computed, makes
/// S3 store "Archive/".)
///
/// This interceptor puts the "/" back, just before signing, on any request whose
/// input has a `key` ending in "/" and whose path no longer does. Requests without
/// such a key pass through untouched.
struct TrailingSlashKeyInterceptorProvider: HttpInterceptorProvider {
    func create<I, O>() -> any Interceptor<I, O, HTTPRequest, HTTPResponse> {
        TrailingSlashKeyInterceptor<I, O>()
    }
}

private final class TrailingSlashKeyInterceptor<I, O>: Interceptor {
    typealias InputType = I
    typealias OutputType = O
    typealias RequestType = HTTPRequest
    typealias ResponseType = HTTPResponse

    func modifyBeforeSigning(context: some MutableRequest<I, HTTPRequest>) async throws {
        guard let key = Self.key(of: context.getInput()), key.hasSuffix("/") else { return }
        let request = context.getRequest()
        let path = request.destination.path
        guard !path.hasSuffix("/") else { return }
        context.updateRequest(updated: request.toBuilder().withPath(path + "/").build())
    }

    /// The `key` of an S3 operation's input (PutObject, HeadObject, GetObject,
    /// DeleteObject, CopyObject…), read generically so every key-based operation is
    /// covered without listing each input type.
    private static func key(of input: Any) -> String? {
        for child in Mirror(reflecting: input).children where child.label == "key" {
            if let key = child.value as? String { return key }
            if let key = child.value as? String?, let key { return key }
        }
        return nil
    }
}
