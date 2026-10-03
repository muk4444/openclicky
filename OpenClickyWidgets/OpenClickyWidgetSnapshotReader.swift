import Foundation

enum OpenClickyWidgetSnapshotReader {
    static let appGroupIdentifier = "group.com.nepomuk.openclicky"
    static let snapshotFileName = "widget-snapshot.json"

    static func readSnapshot(fileManager: FileManager = .default) -> OpenClickyWidgetSnapshot {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return .empty
        }

        let snapshotURL = containerURL.appendingPathComponent(snapshotFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: snapshotURL) else {
            return .empty
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OpenClickyWidgetSnapshot.self, from: data)) ?? .empty
    }
}
