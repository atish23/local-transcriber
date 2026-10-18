import Foundation
import AVFoundation
import CoreMedia

public final class AudioNormalizer {
    public static let targetSampleRate: Double = 16000.0
    public static let targetChannels: AVAudioChannelCount = 1

    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: targetChannels,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?

    public init() {}

    public func normalize(sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let inputFormat = AVAudioFormat(streamDescription: audioStreamBasicDescription) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else {
            return []
        }

        guard let inputPcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        inputPcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var blockBuffer: CMBlockBuffer?
        let bufferListSizeNeeded = MemoryLayout<AudioBufferList>.size + (Int(inputFormat.channelCount) - 1) * MemoryLayout<AudioBuffer>.size

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: inputPcmBuffer.mutableAudioBufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        return convert(inputBuffer: inputPcmBuffer)
    }

    public func convert(inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = inputBuffer.format

        if cachedInputFormat == nil || !cachedInputFormat!.isEqual(inputFormat) {
            cachedInputFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: AudioNormalizer.targetFormat)
        }

        guard let converter = converter else {
            return nil
        }

        let ratio = AudioNormalizer.targetSampleRate / inputFormat.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: AudioNormalizer.targetFormat, frameCapacity: estimatedOutputFrames) else {
            return nil
        }

        var isInputConsumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if isInputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            isInputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let convertStatus = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if convertStatus == .error || error != nil {
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData?[0] else {
            return []
        }

        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        return samples
    }
}
