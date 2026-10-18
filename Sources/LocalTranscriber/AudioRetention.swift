import Foundation

public final class AudioRetention {
    public static func cleanAudio(olderThanDays days: Int = 14) {
        let appSupport = WikiFiler.getApplicationSupportDirectory()
        let audioDir = appSupport.appendingPathComponent("audio")

        guard FileManager.default.fileExists(atPath: audioDir.path),
              let items = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            print("No preserved audio directory found.")
            return
        }

        let cutoffDate = Date().addingTimeInterval(-Double(days) * 86400.0)
        var deletedCount = 0

        for item in items {
            guard let resourceValues = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = resourceValues.contentModificationDate else {
                continue
            }

            if modDate < cutoffDate {
                try? FileManager.default.removeItem(at: item)
                deletedCount += 1
            }
        }

        print("Cleaned up \(deletedCount) preserved audio folder(s) older than \(days) day(s).")
    }
}
