import CryptoKit
import Foundation

struct FileHasher {
    static func sha256(url: URL, chunkSize: Int = 4 * 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
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
