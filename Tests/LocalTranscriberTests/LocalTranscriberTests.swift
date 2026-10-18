import Testing
import Foundation
@testable import LocalTranscriber

@Suite("LocalTranscriber Test Suite")
struct LocalTranscriberTests {

    // MARK: - SessionNames Tests
    @Test func testSlugify() {
        #expect(SessionNames.slugify("Sprint Architecture Review") == "sprint-architecture-review")
        #expect(SessionNames.slugify("Special #@$ Characters!!!") == "special-characters")
        #expect(SessionNames.slugify("---Already---Dashed---") == "already-dashed")
        #expect(SessionNames.slugify("") == "session")
    }

    @Test func testMakeStem() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let stem = SessionNames.makeStem(title: "Architecture Sync", date: date)
        #expect(stem.hasPrefix("local-transcript-"))
        #expect(stem.hasSuffix("-architecture-sync"))
    }

    // MARK: - CLI Parsing Tests
    @Test func testCLIParseRecordDefaults() {
        let cmd = CLI.parse(arguments: ["LocalTranscriber", "record"])
        switch cmd {
        case .record(let config):
            #expect(config.title == "Call Session")
            #expect(config.language == "auto")
            #expect(config.task == "transcribe")
            #expect(!config.includeSpeakerLabels)
            #expect(!config.keepAudio)
            #expect(!config.forceNoWiki)
        default:
            Issue.record("Expected .record command")
        }
    }

    @Test func testCLIParseRecordCustomOptions() {
        let args = [
            "LocalTranscriber", "record",
            "--title", "Sprint Sync",
            "--language", "hi",
            "--task", "translate",
            "--speaker-labels",
            "--keep-audio",
            "--live-only",
            "--auto-ingest",
            "--display", "2"
        ]
        let cmd = CLI.parse(arguments: args)
        switch cmd {
        case .record(let config):
            #expect(config.title == "Sprint Sync")
            #expect(config.language == "hi")
            #expect(config.task == "translate")
            #expect(config.includeSpeakerLabels)
            #expect(config.keepAudio)
            #expect(config.liveOnly)
            #expect(config.autoIngest)
            #expect(config.displayIndex == 2)
        default:
            Issue.record("Expected .record command")
        }
    }

    @Test func testCLIParseSessionsAndCleanAudio() {
        let sessionsCmd = CLI.parse(arguments: ["LocalTranscriber", "sessions", "--query", "sprint"])
        switch sessionsCmd {
        case .sessions(let query, _):
            #expect(query == "sprint")
        default:
            Issue.record("Expected .sessions command")
        }

        let cleanCmd = CLI.parse(arguments: ["LocalTranscriber", "clean-audio", "--days", "7"])
        switch cleanCmd {
        case .cleanAudio(let days):
            #expect(days == 7)
        default:
            Issue.record("Expected .cleanAudio command")
        }
    }

    // MARK: - AudioAligner Tests
    @Test func testAudioAlignerPaddingOnLag() {
        let aligner = AudioAligner()
        var receivedMicSamples = [Float]()
        var receivedDeviceSamples = [Float]()

        aligner.onMicAligned = { receivedMicSamples.append(contentsOf: $0) }
        aligner.onDeviceAligned = { receivedDeviceSamples.append(contentsOf: $0) }

        // Send 16,000 samples (1.0s) to device first
        let deviceFirstBurst = [Float](repeating: 0.1, count: 16000)
        aligner.pushDeviceSamples(deviceFirstBurst)
        #expect(receivedDeviceSamples.count == 16000)

        // Now mic arrives with 1600 samples (0.1s).
        // Lag is 16,000 samples (> 8000 threshold = 0.5s), so it should prepend 16,000 silence samples!
        let micBurst = [Float](repeating: 0.2, count: 1600)
        aligner.pushMicSamples(micBurst)

        #expect(receivedMicSamples.count == 16000 + 1600)
        #expect(receivedMicSamples[0] == 0.0)
        #expect(receivedMicSamples[15999] == 0.0)
        #expect(receivedMicSamples[16000] == 0.2)
    }

    // MARK: - AudioChunker Tests
    @Test func testAudioChunkerWindowAndOverlap() {
        let chunker = AudioChunker(sourceName: "microphone")
        var emittedChunks = [AudioChunk]()
        chunker.onChunkReady = { emittedChunks.append($0) }

        // Generate 30 seconds of high-energy voice samples (16000 * 30 = 480,000 samples)
        let sampleCount = 16000 * 30
        var voiceSamples = [Float](repeating: 0.05, count: sampleCount)
        // Add alternating sign to simulate sound wave
        for i in 0..<sampleCount {
            if i % 2 == 0 { voiceSamples[i] = -0.05 }
        }

        chunker.push(samples: voiceSamples)
        chunker.flush()

        // 30 seconds should trigger max window chunk (28s) plus remaining flush
        #expect(emittedChunks.count >= 1)
        let firstChunk = emittedChunks[0]
        #expect(firstChunk.duration >= 27.9)
        #expect(firstChunk.discardBefore == 0.0) // first chunk has 0 discardBefore
    }

    // MARK: - WavFile Tests
    @Test func testWavFileHeaderCreation() {
        let header = WavFile.createHeader(dataSize: 32000, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        #expect(header.count == 44)

        // Check RIFF magic
        let riffMagic = String(data: header.subdata(in: 0..<4), encoding: .ascii)
        #expect(riffMagic == "RIFF")

        // Check WAVE magic
        let waveMagic = String(data: header.subdata(in: 8..<12), encoding: .ascii)
        #expect(waveMagic == "WAVE")
    }

    @Test func testStreamingWavWriter() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_stream_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let writer = try StreamingWavWriter(fileURL: tempURL)
        let samples: [Float] = [0.0, 0.5, -0.5, 0.25]
        writer.append(samples: samples)
        writer.close()

        let fileData = try Data(contentsOf: tempURL)
        #expect(fileData.count == 44 + (samples.count * 2))
    }

    // MARK: - Echo Removal & Merge Tests
    @Test func testEchoRemovalDropsAcousticSpeakerEcho() {
        // System audio segment: "we are reviewing the cloud deployment architecture"
        let deviceSeg = TranscriptSegment(
            start: 2.0,
            end: 6.0,
            text: "we are reviewing the cloud deployment architecture",
            source: "device"
        )

        // Mic segment echoing identical words at same time
        let echoMicSeg = TranscriptSegment(
            start: 2.5,
            end: 5.5,
            text: "we are reviewing the cloud deployment",
            source: "microphone"
        )

        // Genuine independent mic speech
        let genuineMicSeg = TranscriptSegment(
            start: 7.0,
            end: 9.0,
            text: "yes that sounds completely reasonable",
            source: "microphone"
        )

        let merged = TranscriptSegment.merged(
            micSegments: [echoMicSeg, genuineMicSeg],
            deviceSegments: [deviceSeg]
        )

        // The echo segment should be dropped (>= 80% word overlap), while genuine segment is retained
        #expect(merged.count == 2)
        #expect(merged[0].source == "device")
        #expect(merged[1].source == "microphone")
        #expect(merged[1].text == "yes that sounds completely reasonable")
    }

    @Test func testMarkdownFormattingWithSpeakerLabels() {
        let segs = [
            TranscriptSegment(start: 0.0, end: 2.0, text: "Hello everyone", source: "microphone"),
            TranscriptSegment(start: 2.5, end: 5.0, text: "Hi Atish", source: "device")
        ]

        let mdWithLabels = TranscriptSegment.formatAsMarkdown(
            segments: segs,
            title: "Test Call",
            date: Date(timeIntervalSince1970: 1700000000),
            duration: 5.0,
            includeSpeakerLabels: true
        )

        #expect(mdWithLabels.contains("**[You]** Hello everyone"))
        #expect(mdWithLabels.contains("**[Remote / System]** Hi Atish"))
    }

    // MARK: - WikiFiler Tests
    @Test func testWikiFilerCollisionAvoidance() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_wiki_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let doc = TranscriptDocument(
            title: "Collision Test",
            createdAt: "2026-10-18T10:00:00Z",
            durationSeconds: 10.0,
            language: "auto",
            segments: []
        )

        let result1 = try WikiFiler.fileTranscript(
            stem: "session-abc",
            markdownContent: "# First",
            document: doc,
            customWikiRoot: tempDir.path
        )
        #expect(result1.markdownURL.lastPathComponent == "session-abc.md")

        // Second file with identical stem should get -1 suffix
        let result2 = try WikiFiler.fileTranscript(
            stem: "session-abc",
            markdownContent: "# Second",
            document: doc,
            customWikiRoot: tempDir.path
        )
        #expect(result2.markdownURL.lastPathComponent == "session-abc-1.md")
    }

    // MARK: - PendingQueues Tests
    @Test func testPendingIngestQueue() {
        let tempAppSupport = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_app_support_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempAppSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempAppSupport) }
        setenv("LOCAL_TRANSCRIBER_APP_SUPPORT", tempAppSupport.path, 1)
        defer { unsetenv("LOCAL_TRANSCRIBER_APP_SUPPORT") }

        let path = "/test/path/transcript.md"
        PendingIngestQueue.enqueue(transcriptPath: path)
        let list = PendingIngestQueue.list()
        #expect(list.contains(path))

        let dequeued = PendingIngestQueue.dequeueAll()
        #expect(dequeued.contains(path))
        #expect(PendingIngestQueue.list().isEmpty)
    }

    // MARK: - WorkerClient Fake Mode Tests
    @Test func testWorkerClientFakeMode() async throws {
        // Set fake mode env var for test
        setenv("LOCAL_TRANSCRIBER_FAKE", "1", 1)
        defer { unsetenv("LOCAL_TRANSCRIBER_FAKE") }

        let client = try await WorkerClient()
        defer { client.terminate() }

        try await client.ping()

        // Test fake chunk transcription
        let tempAudio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_audio_\(UUID().uuidString).wav")
        try "dummy wav data".data(using: .utf8)!.write(to: tempAudio)
        defer { try? FileManager.default.removeItem(at: tempAudio) }

        let segments = try await client.transcribeChunk(
            audioURL: tempAudio,
            source: "microphone",
            language: "auto",
            task: "transcribe",
            discardBefore: 0.0
        )

        #expect(!segments.isEmpty)
        #expect(segments[0].source == "microphone")
    }

    @Test func testFinalPassRunnerFakeMode() async throws {
        setenv("LOCAL_TRANSCRIBER_FAKE", "1", 1)
        defer { unsetenv("LOCAL_TRANSCRIBER_FAKE") }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_final_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let micWav = tempDir.appendingPathComponent("mic.wav")
        let devWav = tempDir.appendingPathComponent("device.wav")
        try "dummy mic wav".data(using: .utf8)!.write(to: micWav)
        try "dummy dev wav".data(using: .utf8)!.write(to: devWav)

        let merged = try await FinalPassRunner.run(
            micWavURL: micWav,
            deviceWavURL: devWav,
            language: "auto",
            task: "transcribe",
            includeSpeakerLabels: true
        )

        #expect(!merged.isEmpty)
    }
}

