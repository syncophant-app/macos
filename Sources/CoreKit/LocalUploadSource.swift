import Darwin

/// A regular file opened relative to a confined root; its path is never reopened during upload.
public final class LocalUploadSource: @unchecked Sendable {
    let descriptor: Int32
    public let version: String
    init(descriptor: Int32, version: String) { self.descriptor = descriptor; self.version = version }
    deinit { Darwin.close(descriptor) }
}
