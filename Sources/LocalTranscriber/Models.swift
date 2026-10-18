import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let source: String // "microphone" or "device"

    public init(start: Double, end: Double, text: String, source: String) {
        self.start = start
        self.end = end
        self.text = text
        self.source = source
    }

    public var words: [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Merges mic and device segments, dropping mic segments if >= 80% of their words
    /// appear in contemporaneous device audio (acoustic speaker echo).
    public static func merged(micSegments: [TranscriptSegment], deviceSegments: [TranscriptSegment], includeSpeakerLabels: Bool = false) -> [TranscriptSegment] {
        var cleanMicSegments = [TranscriptSegment]()

        for micSeg in micSegments {
            let micWords = micSeg.words
            if micWords.isEmpty {
                continue
            }

            // Find overlapping device segments within +/- 2.0s
            let overlappingDevice = deviceSegments.filter { devSeg in
                return (micSeg.start < devSeg.end + 2.0) && (devSeg.start < micSeg.end + 2.0)
            }

            let deviceWordsSet = Set(overlappingDevice.flatMap { $0.words })

            var matchedWordCount = 0
            for word in micWords {
                if deviceWordsSet.contains(word) {
                    matchedWordCount += 1
                }
            }

            let matchRatio = Double(matchedWordCount) / Double(micWords.count)
            // If 80% or more words match contemporaneous system audio, drop as echo
            if matchRatio >= 0.80 {
                continue
            }

            cleanMicSegments.append(micSeg)
        }

        let combined = (cleanMicSegments + deviceSegments).sorted { $0.start < $1.start }
        return combined
    }

    public static func formatAsMarkdown(segments: [TranscriptSegment], title: String, date: Date, duration: Double, includeSpeakerLabels: Bool = false) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let dateString = dateFormatter.string(from: date)

        var lines = [String]()
        lines.append("# \(title)")
        lines.append("")
        lines.append("- **Date**: \(dateString)")
        lines.append("- **Duration**: \(String(format: "%.1f", duration)) seconds")
        lines.append("- **Segments**: \(segments.count)")
        lines.append("")
        lines.append("## Transcript")
        lines.append("")

        if segments.isEmpty {
            lines.append("*(No speech detected)*")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        var currentSource: String? = nil
        var currentParagraph = [String]()

        func flushParagraph() {
            guard !currentParagraph.isEmpty else { return }
            let body = currentParagraph.joined(separator: " ")
            if includeSpeakerLabels, let source = currentSource {
                let label = (source == "microphone") ? "**[You]**" : "**[Remote / System]**"
                lines.append("\(label) \(body)")
            } else {
                lines.append(body)
            }
            lines.append("")
            currentParagraph.removeAll()
        }

        for seg in segments {
            if currentSource != nil && currentSource != seg.source && includeSpeakerLabels {
                flushParagraph()
            }
            currentSource = seg.source
            currentParagraph.append(seg.text)
        }
        flushParagraph()

        return lines.joined(separator: "\n")
    }
}

public struct TranscriptDocument: Codable {
    public let title: String
    public let createdAt: String
    public let durationSeconds: Double
    public let language: String
    public let segments: [TranscriptSegment]
}
