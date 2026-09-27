import AVFoundation
import CoreMedia
import Foundation

public enum LivePhotoTimedMetadataValidator {
    private static let stillImageTimeIdentifier = AVMetadataIdentifier(
        rawValue: "mdta/com.apple.quicktime.still-image-time"
    )

    public static func validateVideo(at url: URL) async -> LivePhotoTimedMetadataStatus {
        await validate(asset: AVURLAsset(url: url))
    }

    static func validate(asset: AVAsset) async -> LivePhotoTimedMetadataStatus {
        let metadataTracks: [AVAssetTrack]
        do {
            metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        } catch {
            return .unreadable
        }

        guard !metadataTracks.isEmpty else {
            return .missing
        }

        let duration = try? await asset.load(.duration)
        var markerCount = 0
        var invalidMarker = false

        for track in metadataTracks {
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                return .unreadable
            }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else {
                return .unreadable
            }
            reader.add(output)

            // The deployment target remains macOS 14. The metadata adaptor is the
            // compatible timed-metadata reader there; newer SDKs deprecate it in
            // favor of AVAssetReader.outputMetadataProvider(for:).
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else {
                return .unreadable
            }

            while let group = adaptor.nextTimedMetadataGroup() {
                for item in group.items where isStillImageTime(item) {
                    markerCount += 1

                    // The payload is only a marker. Apple-origin files commonly
                    // carry -1 (0xFF), while generated compatible files may use 0;
                    // the sample presentation time is the actual still-image time.
                    guard item.dataType == (kCMMetadataBaseDataType_SInt8 as String),
                          isValidMarkerTime(group.timeRange.start, assetDuration: duration)
                    else {
                        invalidMarker = true
                        continue
                    }
                }
            }

            if reader.status == .failed || reader.status == .cancelled {
                return .unreadable
            }
        }

        guard markerCount > 0 else {
            return .missing
        }
        guard markerCount == 1, !invalidMarker else {
            return .invalid
        }
        return .valid
    }

    private static func isStillImageTime(_ item: AVMetadataItem) -> Bool {
        item.identifier == stillImageTimeIdentifier
    }

    private static func isValidMarkerTime(_ time: CMTime, assetDuration: CMTime?) -> Bool {
        guard time.isValid, time.isNumeric else { return false }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return false }

        guard let assetDuration,
              assetDuration.isValid,
              assetDuration.isNumeric
        else {
            return true
        }
        let durationSeconds = CMTimeGetSeconds(assetDuration)
        guard durationSeconds.isFinite, durationSeconds >= 0 else { return true }
        return seconds <= durationSeconds
    }
}
