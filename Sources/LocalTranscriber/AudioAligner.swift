import Foundation

public final class AudioAligner {
    public static let sampleRate: Double = 16000.0
    public static let lagThresholdSamples: Int64 = Int64(0.5 * sampleRate) // 8000 samples = 0.5s

    private var micSampleCount: Int64 = 0
    private var deviceSampleCount: Int64 = 0
    private let lock = NSLock()

    public var onMicAligned: (([Float]) -> Void)?
    public var onDeviceAligned: (([Float]) -> Void)?

    public init() {}

    public func pushMicSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        var output = [Float]()

        // Check if mic is lagging behind device by more than lag threshold
        if deviceSampleCount > micSampleCount {
            let lag = deviceSampleCount - micSampleCount
            if lag >= AudioAligner.lagThresholdSamples {
                let silence = [Float](repeating: 0.0, count: Int(lag))
                output.append(contentsOf: silence)
                micSampleCount += lag
            }
        }

        output.append(contentsOf: samples)
        micSampleCount += Int64(samples.count)
        lock.unlock()

        onMicAligned?(output)
    }

    public func pushDeviceSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        var output = [Float]()

        // Check if device is lagging behind mic by more than lag threshold
        if micSampleCount > deviceSampleCount {
            let lag = micSampleCount - deviceSampleCount
            if lag >= AudioAligner.lagThresholdSamples {
                let silence = [Float](repeating: 0.0, count: Int(lag))
                output.append(contentsOf: silence)
                deviceSampleCount += lag
            }
        }

        output.append(contentsOf: samples)
        deviceSampleCount += Int64(samples.count)
        lock.unlock()

        onDeviceAligned?(output)
    }

    public func getTimelineOffsets() -> (micSamples: Int64, deviceSamples: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (micSampleCount, deviceSampleCount)
    }

    public func reset() {
        lock.lock()
        micSampleCount = 0
        deviceSampleCount = 0
        lock.unlock()
    }
}
