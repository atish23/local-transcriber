import Foundation

public struct PendingFinalPassJob: Codable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let duration: Double
    public let language: String
    public let task: String
    public let micWavPath: String
    public let deviceWavPath: String
    public let includeSpeakerLabels: Bool
    public let customWikiRoot: String?
    public let forceNoWiki: Bool
}

public final class PendingFinalPassQueue {
    public static var queueDirectory: URL {
        let appSupport = WikiFiler.getApplicationSupportDirectory()
        let dir = appSupport.appendingPathComponent("pending-final")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func enqueue(
        title: String,
        duration: Double,
        language: String,
        task: String,
        micWavURL: URL,
        deviceWavURL: URL,
        includeSpeakerLabels: Bool,
        customWikiRoot: String?,
        forceNoWiki: Bool
    ) throws -> String {
        let jobId = UUID().uuidString
        let jobDir = queueDirectory.appendingPathComponent(jobId)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let destMic = jobDir.appendingPathComponent("session-microphone.wav")
        let destDevice = jobDir.appendingPathComponent("session-device.wav")

        try FileManager.default.copyItem(at: micWavURL, to: destMic)
        try FileManager.default.copyItem(at: deviceWavURL, to: destDevice)

        let job = PendingFinalPassJob(
            id: jobId,
            title: title,
            createdAt: Date(),
            duration: duration,
            language: language,
            task: task,
            micWavPath: destMic.path,
            deviceWavPath: destDevice.path,
            includeSpeakerLabels: includeSpeakerLabels,
            customWikiRoot: customWikiRoot,
            forceNoWiki: forceNoWiki
        )

        let jobJsonURL = jobDir.appendingPathComponent("job.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(job)
        try data.write(to: jobJsonURL, options: .atomic)

        return jobId
    }

    public static func listPending() -> [PendingFinalPassJob] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        var jobs = [PendingFinalPassJob]()
        for item in items {
            let jobJsonURL = item.appendingPathComponent("job.json")
            if let data = try? Data(contentsOf: jobJsonURL),
               let job = try? JSONDecoder().decode(PendingFinalPassJob.self, from: data) {
                jobs.append(job)
            }
        }
        return jobs.sorted { $0.createdAt < $1.createdAt }
    }

    public static func processAll() async throws {
        let jobs = listPending()
        if jobs.isEmpty {
            print("No pending final pass jobs found.")
            return
        }

        print("Processing \(jobs.count) pending final pass jobs...")
        for job in jobs {
            print("\n==> Processing job: \(job.title) (ID: \(job.id))")
            let micURL = URL(fileURLWithPath: job.micWavPath)
            let deviceURL = URL(fileURLWithPath: job.deviceWavPath)

            guard FileManager.default.fileExists(atPath: micURL.path),
                  FileManager.default.fileExists(atPath: deviceURL.path) else {
                print("Error: Audio files missing for job \(job.id), skipping.")
                continue
            }

            do {
                let segments = try await FinalPassRunner.run(
                    micWavURL: micURL,
                    deviceWavURL: deviceURL,
                    language: job.language,
                    task: job.task,
                    includeSpeakerLabels: job.includeSpeakerLabels
                )

                let stem = SessionNames.makeStem(title: job.title, date: job.createdAt)
                let markdown = TranscriptSegment.formatAsMarkdown(
                    segments: segments,
                    title: job.title,
                    date: job.createdAt,
                    duration: job.duration,
                    includeSpeakerLabels: job.includeSpeakerLabels
                )

                let doc = TranscriptDocument(
                    title: job.title,
                    createdAt: ISO8601DateFormatter().string(from: job.createdAt),
                    durationSeconds: job.duration,
                    language: job.language,
                    segments: segments
                )

                let result = try WikiFiler.fileTranscript(
                    stem: stem,
                    markdownContent: markdown,
                    document: doc,
                    customWikiRoot: job.customWikiRoot,
                    forceNoWiki: job.forceNoWiki
                )

                print("Successfully filed: \(result.markdownURL.path)")
                if result.isWiki {
                    PendingIngestQueue.enqueue(transcriptPath: result.markdownURL.path)
                }

                // Cleanup job directory
                let jobDir = queueDirectory.appendingPathComponent(job.id)
                try? FileManager.default.removeItem(at: jobDir)
            } catch {
                print("Failed to process job \(job.id): \(error.localizedDescription)")
            }
        }
    }
}
