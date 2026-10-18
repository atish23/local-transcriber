import Foundation

public struct AudioChunk {
    public let samples: [Float]
    public let sampleRate: Double
    public let startTime: Double
    public let duration: Double
    public let discardBefore: Double
    public let source: String

    public init(samples: [Float], sampleRate: Double, startTime: Double, duration: Double, discardBefore: Double, source: String) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
        self.duration = duration
        self.discardBefore = discardBefore
        self.source = source
    }
}

public final class AudioChunker {
    public static let sampleRate: Double = 16000.0
    public static let maxWindowSeconds: Double = 28.0
    public static let overlapSeconds: Double = 2.0
    public static let minSpeechSeconds: Double = 0.4
    public static let minEarlyCloseSeconds: Double = 8.0
    public static let earlyPauseSeconds: Double = 1.2
    public static let longPauseSeconds: Double = 3.0

    // Energy threshold for voice detection (Float32 RMS)
    public static let speechRmsThreshold: Float = 0.008

    public let sourceName: String
    public var onChunkReady: ((AudioChunk) -> Void)?

    private var buffer = [Float]()
    private var chunkStartTime: Double = 0.0
    private var totalSamplesProcessed: Int64 = 0
    private var isFirstChunk: Bool = true

    // Pause tracking
    private var consecutiveSilenceSamples: Int = 0
    private var accumulatedSpeechSamples: Int = 0

    private let lock = NSLock()

    public init(sourceName: String) {
        self.sourceName = sourceName
    }

    public func push(samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // Process samples in frames (e.g. 100ms frames = 1600 samples)
        let frameSize = 1600
        var offset = 0

        while offset < samples.count {
            let count = min(frameSize, samples.count - offset)
            let frame = Array(samples[offset..<(offset + count)])
            offset += count

            buffer.append(contentsOf: frame)
            totalSamplesProcessed += Int64(count)

            // Calculate RMS energy of frame
            var sumSquares: Float = 0.0
            for sample in frame {
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(count))

            if rms >= AudioChunker.speechRmsThreshold {
                accumulatedSpeechSamples += count
                consecutiveSilenceSamples = 0
            } else {
                consecutiveSilenceSamples += count
            }

            let currentDuration = Double(buffer.count) / AudioChunker.sampleRate
            let silenceDuration = Double(consecutiveSilenceSamples) / AudioChunker.sampleRate

            var shouldCloseChunk = false

            // Condition 1: Max window reached
            if currentDuration >= AudioChunker.maxWindowSeconds {
                shouldCloseChunk = true
            }
            // Condition 2: Early pause after minimum speech duration
            else if currentDuration >= AudioChunker.minEarlyCloseSeconds && silenceDuration >= AudioChunker.earlyPauseSeconds {
                shouldCloseChunk = true
            }
            // Condition 3: Long pause
            else if silenceDuration >= AudioChunker.longPauseSeconds && currentDuration >= AudioChunker.minSpeechSeconds {
                shouldCloseChunk = true
            }

            if shouldCloseChunk {
                emitCurrentChunk()
            }
        }
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            emitCurrentChunk(force: true)
        }
    }

    private func emitCurrentChunk(force: Bool = false) {
        guard !buffer.isEmpty else { return }

        let speechDuration = Double(accumulatedSpeechSamples) / AudioChunker.sampleRate
        let chunkDuration = Double(buffer.count) / AudioChunker.sampleRate

        // Check minimum speech requirement unless forced flush
        if force || speechDuration >= AudioChunker.minSpeechSeconds {
            let discardBefore = isFirstChunk ? 0.0 : AudioChunker.overlapSeconds
            let chunk = AudioChunk(
                samples: buffer,
                sampleRate: AudioChunker.sampleRate,
                startTime: chunkStartTime,
                duration: chunkDuration,
                discardBefore: discardBefore,
                source: sourceName
            )
            onChunkReady?(chunk)
            isFirstChunk = false
        }

        // Prepare next chunk with overlap
        let overlapSamples = Int(AudioChunker.overlapSeconds * AudioChunker.sampleRate)
        if buffer.count > overlapSamples {
            let overlapData = Array(buffer[(buffer.count - overlapSamples)...])
            let advanceSeconds = Double(buffer.count - overlapSamples) / AudioChunker.sampleRate
            chunkStartTime += advanceSeconds
            buffer = overlapData
        } else {
            chunkStartTime += chunkDuration
            buffer.removeAll()
        }

        accumulatedSpeechSamples = 0
        consecutiveSilenceSamples = 0
    }
}
