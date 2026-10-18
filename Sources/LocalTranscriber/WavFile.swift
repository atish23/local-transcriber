import Foundation

public enum WavFileError: Error {
    case fileCreationFailed
    case seekFailed
    case writeFailed
}

public final class WavFile {
    public static func createHeader(dataSize: UInt32, sampleRate: UInt32 = 16000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) -> Data {
        var header = Data()
        let fileSize: UInt32 = 36 + dataSize
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)

        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append("WAVE".data(using: .ascii)!)

        header.append("fmt ".data(using: .ascii)!)
        let subchunk1Size: UInt32 = 16
        header.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Array($0) })
        let audioFormat: UInt16 = 1 // Linear PCM
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        return header
    }

    public static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                let clamped = max(-1.0, min(1.0, samples[i]))
                let sample16 = Int16(clamped * 32767.0)
                int16Buffer[i] = sample16.littleEndian
            }
        }
        return data
    }

    public static func write(samples: [Float], sampleRate: UInt32 = 16000, to url: URL) throws {
        let pcmData = floatToPCM16(samples)
        let header = createHeader(dataSize: UInt32(pcmData.count), sampleRate: sampleRate)
        var fileData = Data()
        fileData.append(header)
        fileData.append(pcmData)
        try fileData.write(to: url, options: .atomic)
    }
}

public final class StreamingWavWriter {
    public let fileURL: URL
    public let sampleRate: UInt32
    private var fileHandle: FileHandle?
    private var totalBytesWritten: UInt32 = 0
    private let lock = NSLock()
    private var isClosed = false

    public init(fileURL: URL, sampleRate: UInt32 = 16000) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate

        // Ensure parent directory exists
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create empty file
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw WavFileError.fileCreationFailed
        }
        self.fileHandle = handle

        // Write initial header placeholder with 0 data size
        let initialHeader = WavFile.createHeader(dataSize: 0, sampleRate: sampleRate)
        try? handle.write(contentsOf: initialHeader)
    }

    public func append(samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let handle = fileHandle else { return }

        let pcmData = WavFile.floatToPCM16(samples)
        try? handle.write(contentsOf: pcmData)
        totalBytesWritten += UInt32(pcmData.count)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let handle = fileHandle else { return }
        isClosed = true

        // Update RIFF total size at offset 4
        let totalFileSize: UInt32 = 36 + totalBytesWritten
        try? handle.seek(toOffset: 4)
        var fileSizeLE = totalFileSize.littleEndian
        let fileSizeBytes = withUnsafeBytes(of: &fileSizeLE) { Data($0) }
        try? handle.write(contentsOf: fileSizeBytes)

        // Update data chunk size at offset 40
        try? handle.seek(toOffset: 40)
        var dataSizeLE = totalBytesWritten.littleEndian
        let dataSizeBytes = withUnsafeBytes(of: &dataSizeLE) { Data($0) }
        try? handle.write(contentsOf: dataSizeBytes)

        try? handle.synchronize()
        try? handle.close()
        self.fileHandle = nil
    }

    deinit {
        if !isClosed {
            close()
        }
    }
}
