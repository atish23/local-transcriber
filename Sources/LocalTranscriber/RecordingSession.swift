import Foundation
import CoreMedia

public final class RecordingSession: CaptureEngineDelegate {
    public struct Config {
        public let title: String
        public let language: String
        public let task: String
        public let includeSpeakerLabels: Bool
        public let customWikiRoot: String?
        public let forceNoWiki: Bool
        public let keepAudio: Bool
        public let liveOnly: Bool
        public let autoIngest: Bool
        public let displayIndex: Int

        public init(
            title: String,
            language: String = "auto",
            task: String = "transcribe",
            includeSpeakerLabels: Bool = false,
            customWikiRoot: String? = nil,
            forceNoWiki: Bool = false,
            keepAudio: Bool = false,
            liveOnly: Bool = false,
            autoIngest: Bool = false,
            displayIndex: Int = 0
        ) {
            self.title = title
            self.language = language
            self.task = task
            self.includeSpeakerLabels = includeSpeakerLabels
            self.customWikiRoot = customWikiRoot
            self.forceNoWiki = forceNoWiki
            self.keepAudio = keepAudio
            self.liveOnly = liveOnly
            self.autoIngest = autoIngest
            self.displayIndex = displayIndex
        }
    }

    public let config: Config
    private let sessionStartTime: Date
    private let sessionDir: URL
    private let micWavURL: URL
    private let deviceWavURL: URL

    private var micWavWriter: StreamingWavWriter?
    private var deviceWavWriter: StreamingWavWriter?

    private let micNormalizer = AudioNormalizer()
    private let deviceNormalizer = AudioNormalizer()
    private let aligner = AudioAligner()
    private let micChunker = AudioChunker(sourceName: "microphone")
    private let deviceChunker = AudioChunker(sourceName: "device")

    private var captureEngine: CaptureEngine?
    private var liveWorker: WorkerClient?

    private var liveMicSegments = [TranscriptSegment]()
    private var liveDeviceSegments = [TranscriptSegment]()
    private let liveQueue = DispatchQueue(label: "local.atish.LocalTranscriber.liveTranscription")
    private let liveLock = NSLock()

    private var sigintSource: DispatchSourceSignal?
    private var isStopping = false
    private var isRecording = false

    public init(config: Config) throws {
        self.config = config
        self.sessionStartTime = Date()

        let uuid = UUID().uuidString
        if config.keepAudio {
            let appSupport = WikiFiler.getApplicationSupportDirectory()
            let audioDir = appSupport.appendingPathComponent("audio").appendingPathComponent(uuid)
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            self.sessionDir = audioDir
        } else {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("local-transcriber-\(uuid)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            self.sessionDir = tempDir
        }

        self.micWavURL = sessionDir.appendingPathComponent("session-microphone.wav")
        self.deviceWavURL = sessionDir.appendingPathComponent("session-device.wav")
    }

    public func start() async throws {
        print("==> Initializing audio capture session: \"\(config.title)\"")
        print("==> Output mode: \(config.includeSpeakerLabels ? "With speaker labels" : "Verbatim transcript")")
        print("==> Language: \(config.language), Task: \(config.task)")

        // 1. Initialize streaming WAV writers
        self.micWavWriter = try StreamingWavWriter(fileURL: micWavURL)
        self.deviceWavWriter = try StreamingWavWriter(fileURL: deviceWavURL)

        // 2. Initialize live preview worker
        print("==> Starting live preview worker...")
        self.liveWorker = try await WorkerClient()

        // 3. Connect aligner outputs to streaming WAV writers and chunkers
        aligner.onMicAligned = { [weak self] samples in
            guard let self = self else { return }
            self.micWavWriter?.append(samples: samples)
            self.micChunker.push(samples: samples)
        }

        aligner.onDeviceAligned = { [weak self] samples in
            guard let self = self else { return }
            self.deviceWavWriter?.append(samples: samples)
            self.deviceChunker.push(samples: samples)
        }

        // 4. Connect chunkers to live transcription
        micChunker.onChunkReady = { [weak self] chunk in
            self?.processLiveChunk(chunk)
        }

        deviceChunker.onChunkReady = { [weak self] chunk in
            self?.processLiveChunk(chunk)
        }

        // 5. Setup signal handler for Ctrl-C
        setupSignalHandler()

        // 6. Start CaptureEngine
        let engine = CaptureEngine(displayIndex: config.displayIndex)
        engine.delegate = self
        self.captureEngine = engine
        self.isRecording = true

        try await engine.start()

        print("\n[REC] Recording microphone and system audio. Press Ctrl-C to finish.\n")
        print(String(repeating: "-", count: 60))

        // Keep running until stopped
        while isRecording {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    private func processLiveChunk(_ chunk: AudioChunk) {
        guard !isStopping else { return }
        Task { [weak self] in
            guard let self = self, !self.isStopping, let worker = self.liveWorker else { return }

            let chunkWavURL = self.sessionDir.appendingPathComponent("chunk-\(chunk.source)-\(UUID().uuidString).wav")
            do {
                try WavFile.write(samples: chunk.samples, sampleRate: UInt32(chunk.sampleRate), to: chunkWavURL)
                defer { try? FileManager.default.removeItem(at: chunkWavURL) }

                let segments = try await worker.transcribeChunk(
                    audioURL: chunkWavURL,
                    source: chunk.source,
                    language: self.config.language,
                    task: self.config.task,
                    discardBefore: chunk.discardBefore
                )

                self.liveLock.withLock {
                    if chunk.source == "microphone" {
                        self.liveMicSegments.append(contentsOf: segments)
                    } else {
                        self.liveDeviceSegments.append(contentsOf: segments)
                    }
                }

                // Print live preview to console
                for seg in segments {
                    let sourceTag = (seg.source == "microphone") ? "You" : "Remote"
                    print(String(format: "[%5.1fs | %-6@] %@", seg.start, sourceTag, seg.text))
                }
            } catch {
                // Ignore transient live chunk error to prevent capture interruption
            }
        }
    }

    private func setupSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.isStopping {
                print("\nForced abort. Exiting.")
                exit(1)
            }
            self.handleStop()
        }
        source.resume()
        self.sigintSource = source
    }

    private func handleStop() {
        guard !isStopping else { return }
        isStopping = true

        print("\n\n==> Stopping recording...")
        Task {
            // Disconnect chunk handlers so flushing doesn't queue new live tasks
            self.micChunker.onChunkReady = nil
            self.deviceChunker.onChunkReady = nil

            await self.captureEngine?.stop()
            self.micChunker.flush()
            self.deviceChunker.flush()
            self.micWavWriter?.close()
            self.deviceWavWriter?.close()
            self.liveWorker?.terminate()
            self.liveWorker = nil

            let duration = Date().timeIntervalSince(self.sessionStartTime)
            print(String(format: "==> Captured %.1f seconds of audio.", duration))

            if self.config.liveOnly {
                self.finalizeWithLiveSegments(duration: duration)
                self.cleanup()
                self.isRecording = false
                return
            }

            // Prompt user for final pass
            print("\nRun authoritative final pass with whisper-large-v3? [Y/n/later]: ", terminator: "")
            fflush(stdout)

            let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y"

            if input == "later" {
                do {
                    let jobId = try PendingFinalPassQueue.enqueue(
                        title: self.config.title,
                        duration: duration,
                        language: self.config.language,
                        task: self.config.task,
                        micWavURL: self.micWavURL,
                        deviceWavURL: self.deviceWavURL,
                        includeSpeakerLabels: self.config.includeSpeakerLabels,
                        customWikiRoot: self.config.customWikiRoot,
                        forceNoWiki: self.config.forceNoWiki
                    )
                    print("==> Queued for later processing (Job ID: \(jobId)).")
                    print("==> Run 'swift run LocalTranscriber finalize-pending' whenever convenient.")
                } catch {
                    print("Error queueing final pass: \(error.localizedDescription)")
                    self.finalizeWithLiveSegments(duration: duration)
                }
                self.cleanup()
                self.isRecording = false
            } else if input == "n" || input == "no" {
                self.finalizeWithLiveSegments(duration: duration)
                self.cleanup()
                self.isRecording = false
            } else {
                // Run final pass
                await self.runFinalPass(duration: duration)
                self.cleanup()
                self.isRecording = false
            }
        }
    }

    private func runFinalPass(duration: Double) async {
        print("\n==> Running authoritative dual-worker final pass...")
        do {
            let merged = try await FinalPassRunner.run(
                micWavURL: micWavURL,
                deviceWavURL: deviceWavURL,
                language: config.language,
                task: config.task,
                includeSpeakerLabels: config.includeSpeakerLabels
            )
            fileAndIngest(segments: merged, duration: duration, isFinalPass: true)
        } catch {
            print("Final pass failed (\(error.localizedDescription)). Falling back to live transcript.")
            finalizeWithLiveSegments(duration: duration)
        }
    }

    private func finalizeWithLiveSegments(duration: Double) {
        let (mic, dev) = liveLock.withLock {
            (liveMicSegments, liveDeviceSegments)
        }

        let merged = TranscriptSegment.merged(
            micSegments: mic,
            deviceSegments: dev,
            includeSpeakerLabels: config.includeSpeakerLabels
        )
        fileAndIngest(segments: merged, duration: duration, isFinalPass: false)
    }

    private func fileAndIngest(segments: [TranscriptSegment], duration: Double, isFinalPass: Bool) {
        let stem = SessionNames.makeStem(title: config.title, date: sessionStartTime)
        let markdown = TranscriptSegment.formatAsMarkdown(
            segments: segments,
            title: config.title,
            date: sessionStartTime,
            duration: duration,
            includeSpeakerLabels: config.includeSpeakerLabels
        )

        let doc = TranscriptDocument(
            title: config.title,
            createdAt: ISO8601DateFormatter().string(from: sessionStartTime),
            durationSeconds: duration,
            language: config.language,
            segments: segments
        )

        do {
            let result = try WikiFiler.fileTranscript(
                stem: stem,
                markdownContent: markdown,
                document: doc,
                customWikiRoot: config.customWikiRoot,
                forceNoWiki: config.forceNoWiki
            )

            print("\n" + String(repeating: "=", count: 60))
            print("==> Transcript saved:")
            print("    Markdown: \(result.markdownURL.path)")
            print("    JSON Twin: \(result.jsonURL.path)")
            print(String(repeating: "=", count: 60))

            if result.isWiki {
                if config.autoIngest {
                    IngestLauncher.launch(transcriptPath: result.markdownURL.path)
                } else {
                    PendingIngestQueue.enqueue(transcriptPath: result.markdownURL.path)
                    print("\n==> Ingest queued. Run 'claude \"/ingest \(result.markdownURL.path)\"' or 'swift run LocalTranscriber ingest-pending'")
                }
            }
        } catch {
            print("Error filing transcript: \(error.localizedDescription)")
        }
    }

    private func cleanup() {
        if !config.keepAudio {
            try? FileManager.default.removeItem(at: sessionDir)
        } else {
            print("==> Audio preserved at: \(sessionDir.path)")
        }
    }

    // MARK: - CaptureEngineDelegate
    public func captureEngine(_ engine: CaptureEngine, didReceiveMicBuffer buffer: CMSampleBuffer) {
        if let samples = micNormalizer.normalize(sampleBuffer: buffer) {
            aligner.pushMicSamples(samples)
        }
    }

    public func captureEngine(_ engine: CaptureEngine, didReceiveDeviceBuffer buffer: CMSampleBuffer) {
        if let samples = deviceNormalizer.normalize(sampleBuffer: buffer) {
            aligner.pushDeviceSamples(samples)
        }
    }

    public func captureEngineDidStall(_ engine: CaptureEngine) {
        print("\n[WARNING] Audio stall detected: no audio frames received in past 10 seconds.")
        print("\u{7}", terminator: "") // Terminal alert beep
    }

    public func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error) {
        print("\n[ERROR] Audio capture error: \(error.localizedDescription)")
    }
}
