import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

func writeSyntheticJPEGReplacing(
    _ url: URL,
    contentIdentifier: String? = nil,
    pixelValue: UInt8
) throws {
    try? FileManager.default.removeItem(at: url)
    try writeSyntheticJPEG(
        to: url,
        contentIdentifier: contentIdentifier,
        pixelValue: pixelValue
    )
}

func writeSyntheticJPEG(
    to url: URL,
    contentIdentifier: String? = nil,
    pixelValue: UInt8 = 128
) throws {
    let bytes: [UInt8] = [pixelValue, 255 &- pixelValue, pixelValue / 2, 255]
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
              width: 1,
              height: 1,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              "public.jpeg" as CFString,
              1,
              nil
          )
    else {
        throw BisyncSelfTestFailure("could not create synthetic JPEG")
    }

    var properties: [CFString: Any] = [:]
    if let contentIdentifier {
        properties[kCGImagePropertyMakerAppleDictionary] = [
            "17": syntheticLivePhotoIdentifier(contentIdentifier)
        ]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw BisyncSelfTestFailure("could not finalize synthetic JPEG")
    }
}

func writeSyntheticMovieReplacing(
    _ url: URL,
    markerValues: [Int8],
    contentIdentifier: String? = nil
) async throws {
    try? FileManager.default.removeItem(at: url)
    try await writeSyntheticTimedMetadataMovie(
        to: url,
        markerValues: markerValues,
        contentIdentifier: contentIdentifier
    )
}

func writeSyntheticTimedMetadataMovie(
    to url: URL,
    markerValues: [Int8],
    validDataType: Bool = true,
    contentIdentifier: String? = nil
) async throws {
    let stillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"
    let unrelatedIdentifier = "mdta/com.example.photoarchive.synthetic"
    let metadataIdentifiers = markerValues.isEmpty
        ? [unrelatedIdentifier]
        : [stillImageTimeIdentifier]
    let dataType = validDataType
        ? (kCMMetadataBaseDataType_SInt8 as String)
        : (kCMMetadataBaseDataType_UTF8 as String)
    let specifications = metadataIdentifiers.map { identifier -> CFDictionary in
        [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: dataType
        ] as CFDictionary
    }

    var formatDescription: CMMetadataFormatDescription?
    let formatStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specifications as CFArray,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, formatDescription != nil else {
        throw BisyncSelfTestFailure("could not create synthetic metadata format description")
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    if let contentIdentifier {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = NSString(string: syntheticLivePhotoIdentifier(contentIdentifier))
        writer.metadata = [item]
    }
    let input = AVAssetWriterInput(
        mediaType: .metadata,
        outputSettings: nil,
        sourceFormatHint: formatDescription
    )
    guard writer.canAdd(input) else {
        throw BisyncSelfTestFailure("could not add synthetic metadata input")
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)

    guard writer.startWriting() else {
        throw BisyncSelfTestFailure("synthetic metadata writer did not start")
    }
    writer.startSession(atSourceTime: .zero)

    let values = markerValues.isEmpty ? [Int8(0)] : markerValues
    for (index, value) in values.enumerated() {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(
            rawValue: markerValues.isEmpty ? unrelatedIdentifier : stillImageTimeIdentifier
        )
        item.dataType = dataType
        item.value = validDataType ? NSNumber(value: value) : NSString(string: "invalid")
        let start = CMTime(value: CMTimeValue(index), timescale: 30)
        let group = AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 30))
        )
        guard adaptor.append(group) else {
            throw BisyncSelfTestFailure("could not append synthetic timed metadata")
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw BisyncSelfTestFailure("synthetic metadata movie did not finish")
    }
}

private func syntheticLivePhotoIdentifier(_ value: String) -> String {
    guard value.count < 36 else { return value }
    return value.padding(toLength: 36, withPad: ".", startingAt: 0)
}
