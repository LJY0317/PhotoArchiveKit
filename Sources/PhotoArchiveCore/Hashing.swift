import CryptoKit
import Foundation

struct FileHasher {
    static func sha256(url: URL, chunkSize: Int = 4 * 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            // Large archive plans may hash thousands of files back-to-back without
            // returning to an outer run loop. Drain Foundation's temporary read
            // objects per chunk so resident memory stays bounded by the chunk size
            // instead of accumulating across the whole planning pass.
            let reachedEOF = try autoreleasepool { () -> Bool in
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                guard !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if reachedEOF { break }
        }
        return Data(hasher.finalize())
    }
}

struct PrivacyFingerprint {
    static func livePhotoIdentifier(_ identifier: String, key: Data) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(identifier.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode)
    }
}

extension Data {
    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
