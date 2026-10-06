import FluidAudio
import Foundation

enum OutputFormat: String, CaseIterable {
    case txt, json, srt

    var fileExtension: String { rawValue }
}

struct Segment: Encodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct TranscriptDocument: Encodable {
    let file: String
    let model: String
    let duration: TimeInterval
    let speechDuration: TimeInterval
    let vadApplied: Bool
    let processingSeconds: TimeInterval
    let text: String
    let segments: [Segment]
}

enum SegmentBuilder {
    private static let maxSegmentDuration: TimeInterval = 7
    private static let pauseBreak: TimeInterval = 0.8
    private static let sentenceTerminators: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    /// Groups model tokens into caption-sized segments. A segment closes after
    /// sentence-final punctuation, at a pause, or when it grows too long; word
    /// boundaries are tokens that start with whitespace.
    static func build(from tokens: [TimedToken], postProcessor: PostProcessor) -> [Segment] {
        var segments: [Segment] = []
        var current: [TimedToken] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let raw = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            current.removeAll()
            let text = postProcessor.process(TextNormalizer.shared.normalizeSentence(raw), formatParagraphs: false)
            guard !text.isEmpty else { return }
            segments.append(Segment(start: first.start, end: max(last.end, first.start), text: text))
        }

        for token in tokens {
            let startsWord = token.text.first?.isWhitespace ?? false
            if let last = current.last, let first = current.first, startsWord {
                let endsSentence = last.text.last.map { sentenceTerminators.contains($0) } ?? false
                let paused = token.start - last.end >= pauseBreak
                let tooLong = token.start - first.start >= maxSegmentDuration
                if endsSentence || paused || tooLong {
                    flush()
                }
            }
            current.append(token)
        }
        flush()
        return segments
    }
}

enum Renderer {
    static func render(_ document: TranscriptDocument, as format: OutputFormat) throws -> String {
        switch format {
        case .txt:
            return document.text + "\n"
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            return String(decoding: data, as: UTF8.self) + "\n"
        case .srt:
            return document.segments.enumerated().map { index, segment in
                "\(index + 1)\n\(timestamp(segment.start)) --> \(timestamp(segment.end))\n\(segment.text)\n"
            }.joined(separator: "\n")
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(seconds, 0) * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}
