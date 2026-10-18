import Foundation

public final class FinalPassRunner {
    public static let defaultFinalModel = "mlx-community/whisper-large-v3"

    public static func run(
        micWavURL: URL,
        deviceWavURL: URL,
        language: String = "auto",
        task: String = "transcribe",
        includeSpeakerLabels: Bool = false
    ) async throws -> [TranscriptSegment] {
        let finalModel = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_FINAL_MODEL"] ?? defaultFinalModel

        // Run mic and device passes concurrently in two separate worker processes
        async let micWorkerTask: [TranscriptSegment] = {
            let client = try await WorkerClient(modelOverride: finalModel)
            defer { client.terminate() }
            return try await client.transcribeFile(
                audioURL: micWavURL,
                source: "microphone",
                language: language,
                task: task
            )
        }()

        async let deviceWorkerTask: [TranscriptSegment] = {
            let client = try await WorkerClient(modelOverride: finalModel)
            defer { client.terminate() }
            return try await client.transcribeFile(
                audioURL: deviceWavURL,
                source: "device",
                language: language,
                task: task
            )
        }()

        let (micSegments, deviceSegments) = try await (micWorkerTask, deviceWorkerTask)

        // Merge and remove speaker echo
        let merged = TranscriptSegment.merged(
            micSegments: micSegments,
            deviceSegments: deviceSegments,
            includeSpeakerLabels: includeSpeakerLabels
        )
        return merged
    }
}
