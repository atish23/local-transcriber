import Foundation

public final class PendingIngestQueue {
    public static var queueFileURL: URL {
        let appSupport = WikiFiler.getApplicationSupportDirectory()
        return appSupport.appendingPathComponent("pending-ingest.txt")
    }

    private static let lock = NSRecursiveLock()

    public static func enqueue(transcriptPath: String) {
        lock.lock()
        defer { lock.unlock() }

        let line = transcriptPath + "\n"
        if let data = line.data(using: .utf8) {
            let fileURL = queueFileURL
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    public static func list() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard let content = try? String(contentsOf: queueFileURL, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func dequeueAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let items = list()
        try? FileManager.default.removeItem(at: queueFileURL)
        return items
    }
}

public final class IngestLauncher {
    public static func launch(transcriptPath: String) {
        let command = "claude \"/ingest \(transcriptPath)\""
        print("\n==> Ingest command: \(command)")

        // Launch in Terminal via osascript
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let err = error {
                print("Note: Could not automatically open Terminal: \(err)")
                print("Run manually in your terminal: \(command)")
            } else {
                print("Opened Terminal with claude ingest command.")
            }
        }
    }

    public static func processPending() {
        let items = PendingIngestQueue.dequeueAll()
        if items.isEmpty {
            print("No pending ingest items found.")
            return
        }

        print("Processing \(items.count) pending ingest commands:")
        for item in items {
            launch(transcriptPath: item)
        }
    }
}
