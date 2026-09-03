import Foundation

enum EventClusterer {
    static func cluster(
        assets: [InternalEventAsset],
        gap: TimeInterval
    ) -> [EventSuggestionReport] {
        let sorted = assets.sorted {
            ($0.captureInstant, $0.assetID) < ($1.captureInstant, $1.assetID)
        }
        guard let first = sorted.first else { return [] }

        var groups: [[InternalEventAsset]] = [[first]]
        for asset in sorted.dropFirst() {
            let previous = groups[groups.count - 1].last!
            if asset.captureInstant.timeIntervalSince(previous.captureInstant) > gap {
                groups.append([asset])
            } else {
                groups[groups.count - 1].append(asset)
            }
        }

        var folderNameUseCounts: [String: Int] = [:]
        return groups.enumerated().map { index, group in
            let start = group.first!.captureInstant
            let end = group.last!.captureInstant
            let baseName = suggestedFolderName(
                firstLocalDay: group.first?.localDay,
                lastLocalDay: group.last?.localDay,
                start: start,
                end: end
            )
            let useCount = folderNameUseCounts[baseName, default: 0]
            folderNameUseCounts[baseName] = useCount + 1
            let folderName = useCount == 0
                ? baseName
                : String(format: "%@_%02d", baseName, useCount + 1)

            return EventSuggestionReport(
                eventID: String(format: "E%06d", index + 1),
                suggestedFolderName: folderName,
                start: start,
                end: end,
                assetIDs: group.map(\.assetID)
            )
        }
    }

    private static func suggestedFolderName(
        firstLocalDay: String?,
        lastLocalDay: String?,
        start: Date,
        end: Date
    ) -> String {
        let startString = firstLocalDay ?? utcDay(start)
        let endString = lastLocalDay ?? utcDay(end)
        return startString == endString
            ? startString
            : "\(startString)--\(endString)"
    }

    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
