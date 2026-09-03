import AVFoundation
import Foundation
import ImageIO

struct MetadataProbe {
    static func probe(_ pending: PendingFile) async -> ProbedResource {
        switch pending.type.mediaKind {
        case .image:
            return probeImage(pending)
        case .video:
            return await probeVideo(pending)
        case .sidecar:
            return makeResource(
                pending,
                captureTime: nil,
                rawIdentifier: nil,
                metadataProbeFailed: false
            )
        }
    }

    private static func probeImage(_ pending: PendingFile) -> ProbedResource {
        guard let source = CGImageSourceCreateWithURL(pending.url as CFURL, nil),
              let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        else {
            return makeResource(
                pending,
                captureTime: fallbackCaptureTime(createdAt: pending.createdAt),
                rawIdentifier: nil,
                metadataProbeFailed: true
            )
        }

        let properties = rawProperties as NSDictionary
        let captureTime = imageCaptureTime(properties: properties)
            ?? fallbackCaptureTime(createdAt: pending.createdAt)

        let identifier: String?
        if pending.type.isPotentialLivePhotoStill {
            identifier = livePhotoStillIdentifier(properties: properties)
        } else {
            identifier = nil
        }

        return makeResource(
            pending,
            captureTime: captureTime,
            rawIdentifier: identifier,
            metadataProbeFailed: false
        )
    }

    private static func probeVideo(_ pending: PendingFile) async -> ProbedResource {
        let asset = AVURLAsset(url: pending.url)

        do {
            let metadata = try await asset.loadMetadata(for: .quickTimeMetadata)
            let identifier = pending.type.isPotentialLivePhotoVideo
                ? await quickTimeString(
                    metadata.first(where: {
                        $0.identifier == .quickTimeMetadataContentIdentifier
                    })
                )
                : nil

            let creationItem = metadata.first(where: {
                $0.identifier == .quickTimeMetadataCreationDate
            })
            let creationString = await quickTimeString(creationItem)
            let creationDate = await quickTimeDate(creationItem)
            let captureTime = quickTimeCaptureTime(
                originalString: creationString,
                dateValue: creationDate
            ) ?? fallbackCaptureTime(createdAt: pending.createdAt)

            return makeResource(
                pending,
                captureTime: captureTime,
                rawIdentifier: identifier,
                metadataProbeFailed: false
            )
        } catch {
            return makeResource(
                pending,
                captureTime: fallbackCaptureTime(createdAt: pending.createdAt),
                rawIdentifier: nil,
                metadataProbeFailed: true
            )
        }
    }

    private static func makeResource(
        _ pending: PendingFile,
        captureTime: CaptureTime?,
        rawIdentifier: String?,
        metadataProbeFailed: Bool
    ) -> ProbedResource {
        ProbedResource(
            root: pending.root,
            url: pending.url,
            relativePath: pending.relativePath,
            fileName: pending.url.lastPathComponent,
            fileExtension: pending.url.pathExtension.lowercased(),
            mediaKind: pending.type.mediaKind,
            byteSize: pending.byteSize,
            modifiedAt: pending.modifiedAt,
            captureTime: captureTime,
            rawLivePhotoIdentifier: normalizedIdentifier(rawIdentifier),
            metadataProbeFailed: metadataProbeFailed,
            exactHash: nil,
            persistentResourceID: nil,
            persistentAssetID: nil,
            identifierFingerprint: nil
        )
    }

    /// Apple publicly documents that the still-image content identifier lives in
    /// the Exif MakerNote. Current iPhone HEIC/JPEG files expose that identifier
    /// through ImageIO's MakerApple dictionary entry 17. This implementation is
    /// deliberately isolated so future format changes do not affect the scanner.
    private static func livePhotoStillIdentifier(properties: NSDictionary) -> String? {
        guard let maker = properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary else {
            return nil
        }

        for (key, value) in maker {
            guard String(describing: key) == "17" else { continue }
            if let string = value as? String {
                return string
            }
            if let string = value as? NSString {
                return string as String
            }
        }

        return nil
    }

    private static func imageCaptureTime(properties: NSDictionary) -> CaptureTime? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary,
              let dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else {
            return nil
        }

        let subsecond = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let normalizedLocal = normalizedExifLocalTimestamp(
            dateTimeOriginal,
            subsecond: subsecond
        )
        let instant = parseExifInstant(
            dateTimeOriginal,
            subsecond: subsecond,
            offset: offset
        )

        return CaptureTime(
            localTimestamp: normalizedLocal,
            utcOffset: normalizedOffset(offset),
            instant: instant,
            source: .exifDateTimeOriginal,
            confidence: offset == nil ? .incompleteTimezone : .trusted
        )
    }

    private static func quickTimeCaptureTime(
        originalString: String?,
        dateValue: Date?
    ) -> CaptureTime? {
        guard originalString != nil || dateValue != nil else { return nil }

        let parsed = originalString.flatMap(parseISO8601Date)
        let instant = parsed ?? dateValue
        let offset = originalString.flatMap(extractISO8601Offset)

        return CaptureTime(
            localTimestamp: originalString,
            utcOffset: offset,
            instant: instant,
            source: .quickTimeCreationDate,
            confidence: (offset != nil || originalString?.hasSuffix("Z") == true)
                ? .trusted
                : .incompleteTimezone
        )
    }

    private static func fallbackCaptureTime(createdAt: Date?) -> CaptureTime? {
        guard let createdAt else { return nil }
        return CaptureTime(
            localTimestamp: nil,
            utcOffset: nil,
            instant: createdAt,
            source: .fileCreationDate,
            confidence: .fallback
        )
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedExifLocalTimestamp(
        _ base: String,
        subsecond: String?
    ) -> String {
        let normalizedBase = base.replacingOccurrences(of: ":", with: "-", options: [], range: base.startIndex..<base.index(base.startIndex, offsetBy: min(10, base.count)))
            .replacingOccurrences(of: " ", with: "T")
        guard let subsecond, !subsecond.isEmpty else { return normalizedBase }
        return "\(normalizedBase).\(subsecond)"
    }

    private static func parseExifInstant(
        _ base: String,
        subsecond: String?,
        offset: String?
    ) -> Date? {
        guard let secondsFromGMT = parseOffsetSeconds(offset),
              let timeZone = TimeZone(secondsFromGMT: secondsFromGMT)
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        guard let baseDate = formatter.date(from: base) else { return nil }
        guard let subsecond,
              let fraction = Double("0.\(subsecond.filter(\.isNumber))")
        else {
            return baseDate
        }
        return baseDate.addingTimeInterval(fraction)
    }

    private static func normalizedOffset(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parseOffsetSeconds(trimmed) != nil else { return nil }

        if trimmed.count == 5, !trimmed.contains(":") {
            let index = trimmed.index(trimmed.startIndex, offsetBy: 3)
            return String(trimmed[..<index]) + ":" + String(trimmed[index...])
        }
        return trimmed
    }

    private static func parseOffsetSeconds(_ value: String?) -> Int? {
        guard let value = normalizedOffsetWithoutRecursion(value) else { return nil }
        let sign = value.first == "-" ? -1 : 1
        let digits = value.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 23,
              minutes <= 59
        else {
            return nil
        }
        return sign * ((hours * 60 + minutes) * 60)
    }

    private static func normalizedOffsetWithoutRecursion(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "+" || trimmed.first == "-" else { return nil }
        return trimmed
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) {
            return date
        }

        let compactOffset = value.replacingOccurrences(
            of: "([+-][0-9]{2})([0-9]{2})$",
            with: "$1:$2",
            options: .regularExpression
        )
        return withFractional.date(from: compactOffset)
            ?? standard.date(from: compactOffset)
    }

    private static func extractISO8601Offset(_ value: String) -> String? {
        if value.hasSuffix("Z") { return "+00:00" }

        let pattern = "([+-][0-9]{2}:?[0-9]{2})$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return normalizedOffset(String(value[range]))
    }

    private static func quickTimeString(_ item: AVMetadataItem?) async -> String? {
        guard let item else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func quickTimeDate(_ item: AVMetadataItem?) async -> Date? {
        guard let item else { return nil }
        return try? await item.load(.dateValue)
    }
}
