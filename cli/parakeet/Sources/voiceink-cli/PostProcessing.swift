import Foundation
import NaturalLanguage

/// Ports of the app's text post-processing (`TranscriptionOutputFilter`,
/// `WhisperTextFormatter`, `WordReplacementService`), parameterized by settings
/// instead of reading the app's UserDefaults and SwiftData context.
struct PostProcessor {
    let settings: AppSettings
    let replacements: [ReplacementRule]

    /// Full pipeline applied to a whole transcript, in the app's order.
    func process(_ text: String, formatParagraphs: Bool) -> String {
        var result = OutputFilter.filter(text, settings: settings)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if formatParagraphs && settings.textFormattingEnabled {
            result = TextFormatter.format(result)
        }
        result = WordReplacer.apply(replacements, to: result)
        return OutputFilter.applyUserCleanupPreferences(result, settings: settings)
    }
}

enum OutputFilter {
    private static let apostropheLikeCharacters = CharacterSet(charactersIn: "'’‘ʼ＇")
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,
        #"\(.*?\)"#,
        #"\{.*?\}"#,
    ]

    static func filter(_ text: String, settings: AppSettings) -> String {
        var filteredText = text

        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        filteredText = replace(tagBlockPattern, in: filteredText, with: "")

        for pattern in hallucinationPatterns {
            filteredText = replace(pattern, in: filteredText, with: "")
        }

        if settings.removeFillerWords {
            for fillerWord in settings.fillerWords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
                filteredText = replace(pattern, in: filteredText, with: "", options: .caseInsensitive)
            }
        }

        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return filteredText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func applyUserCleanupPreferences(_ text: String, settings: AppSettings) -> String {
        guard settings.removePunctuation || settings.lowercase else { return text }
        var cleanedText = text
        if settings.removePunctuation {
            cleanedText = removePunctuation(from: cleanedText)
        }
        if settings.lowercase {
            cleanedText = cleanedText.lowercased()
        }
        return cleanedText
    }

    private static func removePunctuation(from text: String) -> String {
        guard !text.isEmpty else { return text }
        let punctuationSeparators = CharacterSet.punctuationCharacters.subtracting(apostropheLikeCharacters)
        let cleaned = text.unicodeScalars.map { scalar -> String in
            if apostropheLikeCharacters.contains(scalar) { return "" }
            if punctuationSeparators.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        return cleaned
            .replacingOccurrences(of: #"[^\S\r\n]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replace(
        _ pattern: String, in text: String, with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

enum WordReplacer {
    private static let nonSpacedScripts: [ClosedRange<UInt32>] = [
        0x3040...0x309F,
        0x30A0...0x30FF,
        0x4E00...0x9FFF,
        0xAC00...0xD7AF,
        0x0E00...0x0E7F,
    ]

    static func apply(_ replacements: [ReplacementRule], to text: String) -> String {
        guard !replacements.isEmpty else { return text }
        var modifiedText = text

        let sortedReplacements = replacements.sorted { $0.originalText.count > $1.originalText.count }
        for replacement in sortedReplacements {
            let variants = replacement.originalText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }

            for original in variants {
                if usesWordBoundaries(original) {
                    let escaped = NSRegularExpression.escapedPattern(for: original)
                    let pattern = "(?<![a-zA-Z0-9])\(escaped)(?![a-zA-Z0-9])"
                    modifiedText = OutputFilter.replace(
                        pattern, in: modifiedText, with: replacement.replacementText, options: .caseInsensitive)
                } else {
                    modifiedText = modifiedText.replacingOccurrences(
                        of: original, with: replacement.replacementText, options: .caseInsensitive)
                }
            }
        }
        return modifiedText
    }

    private static func usesWordBoundaries(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if nonSpacedScripts.contains(where: { $0.contains(scalar.value) }) {
                return false
            }
        }
        return true
    }
}

/// Paragraph formatter equivalent to the app's `WhisperTextFormatter.format`.
enum TextFormatter {
    private static let targetWordCount = 50
    private static let maxSentencesPerChunk = 4
    private static let minWordsForSignificantSentence = 4

    static func format(_ text: String) -> String {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english

        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        sentenceTokenizer.setLanguage(language)
        var sentences: [String] = []
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        guard !sentences.isEmpty else { return "" }

        let wordCounts = sentences.map { wordCount(of: $0, language: language) }
        var paragraphs: [String] = []
        var index = 0

        while index < sentences.count {
            var tentative: [Int] = []
            var chunkWordCount = 0
            var significantCount = 0
            for candidate in index..<sentences.count {
                tentative.append(candidate)
                chunkWordCount += wordCounts[candidate]
                if wordCounts[candidate] >= minWordsForSignificantSentence {
                    significantCount += 1
                }
                if chunkWordCount >= targetWordCount { break }
            }

            var chosen: [Int] = []
            if significantCount > maxSentencesPerChunk {
                var significantSeen = 0
                for candidate in tentative {
                    chosen.append(candidate)
                    if wordCounts[candidate] >= minWordsForSignificantSentence {
                        significantSeen += 1
                        if significantSeen >= maxSentencesPerChunk { break }
                    }
                }
            } else {
                chosen = tentative
            }

            guard !chosen.isEmpty else { break }
            paragraphs.append(chosen.map { sentences[$0] }.joined(separator: " "))
            index += chosen.count
        }

        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(of sentence: String, language: NLLanguage) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        tokenizer.setLanguage(language)
        var count = 0
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
