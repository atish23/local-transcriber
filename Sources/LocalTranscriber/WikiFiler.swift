import Foundation

public struct FilingResult {
    public let markdownURL: URL
    public let jsonURL: URL
    public let isWiki: Bool
}

public final class WikiFiler {
    public static func resolveTranscriptDirectory(customWikiRoot: String? = nil, forceNoWiki: Bool = false) -> (URL, Bool) {
        if forceNoWiki {
            let appSupport = getApplicationSupportDirectory()
            let transcriptsDir = appSupport.appendingPathComponent("transcripts")
            try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
            return (transcriptsDir, false)
        }

        // 1. Explicit CLI argument
        if let custom = customWikiRoot, !custom.isEmpty {
            let customURL = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            let miscDir = customURL.appendingPathComponent("raw").appendingPathComponent("misc")
            try? FileManager.default.createDirectory(at: miscDir, withIntermediateDirectories: true)
            return (miscDir, true)
        }

        // 2. Environment variables
        let envKeys = ["LOCAL_TRANSCRIBER_WIKI_ROOT", "LLM_WIKI_PATH"]
        for key in envKeys {
            if let envVal = ProcessInfo.processInfo.environment[key], !envVal.isEmpty {
                let envURL = URL(fileURLWithPath: (envVal as NSString).expandingTildeInPath)
                let miscDir = envURL.appendingPathComponent("raw").appendingPathComponent("misc")
                try? FileManager.default.createDirectory(at: miscDir, withIntermediateDirectories: true)
                return (miscDir, true)
            }
        }

        // 3. Known machine locations
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidatePaths = [
            home.appendingPathComponent("Documents").appendingPathComponent("LLM WIKI"),
            home.appendingPathComponent("Documents").appendingPathComponent("llm-wiki")
        ]

        for candidate in candidatePaths {
            if FileManager.default.fileExists(atPath: candidate.path) {
                let miscDir = candidate.appendingPathComponent("raw").appendingPathComponent("misc")
                try? FileManager.default.createDirectory(at: miscDir, withIntermediateDirectories: true)
                return (miscDir, true)
            }
        }

        // Fallback to Application Support
        let appSupport = getApplicationSupportDirectory()
        let transcriptsDir = appSupport.appendingPathComponent("transcripts")
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        return (transcriptsDir, false)
    }

    public static func getApplicationSupportDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_APP_SUPPORT"], !env.isEmpty {
            let dir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("LocalTranscriber")
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            return appDir
        } catch {
            // Fallback if ~/Library/Application Support is restricted by sandbox
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LocalTranscriber")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            return tmpDir
        }
    }

    public static func fileTranscript(
        stem: String,
        markdownContent: String,
        document: TranscriptDocument,
        customWikiRoot: String? = nil,
        forceNoWiki: Bool = false
    ) throws -> FilingResult {
        let (directory, isWiki) = resolveTranscriptDirectory(customWikiRoot: customWikiRoot, forceNoWiki: forceNoWiki)

        var finalStem = stem
        var mdURL = directory.appendingPathComponent("\(finalStem).md")
        var jsonURL = directory.appendingPathComponent("\(finalStem).json")

        // Refuse to overwrite on initial filing; find available suffix
        var counter = 1
        while FileManager.default.fileExists(atPath: mdURL.path) || FileManager.default.fileExists(atPath: jsonURL.path) {
            finalStem = "\(stem)-\(counter)"
            mdURL = directory.appendingPathComponent("\(finalStem).md")
            jsonURL = directory.appendingPathComponent("\(finalStem).json")
            counter += 1
        }

        // Atomic write for Markdown
        let mdData = markdownContent.data(using: .utf8)!
        try mdData.write(to: mdURL, options: .atomic)

        // Atomic write for JSON twin
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(document)
        try jsonData.write(to: jsonURL, options: .atomic)

        return FilingResult(markdownURL: mdURL, jsonURL: jsonURL, isWiki: isWiki)
    }
}
