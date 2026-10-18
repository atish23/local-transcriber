import Foundation

public final class SessionsCommand {
    public static func run(query: String?, customWikiRoot: String?) {
        let (wikiDir, _) = WikiFiler.resolveTranscriptDirectory(customWikiRoot: customWikiRoot, forceNoWiki: false)
        let (appSupportDir, _) = WikiFiler.resolveTranscriptDirectory(customWikiRoot: nil, forceNoWiki: true)

        var directories = [wikiDir]
        if wikiDir.path != appSupportDir.path {
            directories.append(appSupportDir)
        }

        var foundDocuments = [(url: URL, doc: TranscriptDocument)]()

        for dir in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local-transcript-") {
                if let data = try? Data(contentsOf: file),
                   let doc = try? JSONDecoder().decode(TranscriptDocument.self, from: data) {

                    if let q = query?.lowercased(), !q.isEmpty {
                        let matchesTitle = doc.title.lowercased().contains(q)
                        let matchesPath = file.lastPathComponent.lowercased().contains(q)
                        let matchesText = doc.segments.contains { $0.text.lowercased().contains(q) }
                        if !matchesTitle && !matchesPath && !matchesText {
                            continue
                        }
                    }
                    foundDocuments.append((file, doc))
                }
            }
        }

        foundDocuments.sort { $0.doc.createdAt > $1.doc.createdAt }

        if foundDocuments.isEmpty {
            if let q = query {
                print("No transcription sessions found matching '\(q)'.")
            } else {
                print("No transcription sessions found.")
            }
            return
        }

        print("\nFound \(foundDocuments.count) transcription session(s):\n")
        print(String(format: "%-16@  %-6@  %-30@  %@", "Date", "Duration", "Title", "File"))
        print(String(repeating: "-", count: 85))

        for item in foundDocuments {
            let mdFile = item.url.deletingPathExtension().appendingPathExtension("md")
            let durationStr = String(format: "%.0fs", item.doc.durationSeconds)
            let dateStr = String(item.doc.createdAt.prefix(16))
            let titleSnippet = String(item.doc.title.prefix(28))
            print(String(format: "%-16@  %-8@  %-30@  %@", dateStr, durationStr, titleSnippet, mdFile.lastPathComponent))
        }
        print("")
    }
}
