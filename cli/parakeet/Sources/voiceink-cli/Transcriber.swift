import FluidAudio
import Foundation

struct TimedToken {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct RawTranscript {
    /// Normalized model text, before the app's output filters.
    let text: String
    /// Token timings mapped back to positions in the original audio.
    let tokens: [TimedToken]
    let audioDuration: TimeInterval
    let speechDuration: TimeInterval
    let vadApplied: Bool
}

/// Reproduces `FluidAudioTranscriptionService.transcribe` for an in-memory sample buffer.
final class Transcriber {
    static let sampleRate = 16_000
    private static let vadMinimumDuration: TimeInterval = 20
    private static let vadThreshold: Float = 0.7
    private static let trailingSilenceSamples = 16_000
    private static let maxSingleChunkSamples = 240_000

    private let asrManager: AsrManager
    private let vadEnabled: Bool
    private let language: Language?
    private var vadManager: VadManager?
    private var vadInitFailed = false

    private init(asrManager: AsrManager, vadEnabled: Bool, language: Language?) {
        self.asrManager = asrManager
        self.vadEnabled = vadEnabled
        self.language = language
    }

    /// Loads the cached models only; a missing model is an error, never a download.
    static func make(version: AsrModelVersion, vadEnabled: Bool, language: Language?) async throws -> Transcriber {
        let directory = AsrModels.defaultCacheDirectory(for: version)
        guard AsrModels.modelsExist(at: directory, version: version) else {
            throw CLIError.modelMissing(directory.path)
        }
        let models = try await AsrModels.loadFromCache(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return Transcriber(asrManager: manager, vadEnabled: vadEnabled, language: language)
    }

    func transcribe(_ samples: [Float]) async throws -> RawTranscript {
        let audioDuration = Double(samples.count) / Double(Self.sampleRate)

        // Each span maps a range of the concatenated speech buffer to its origin in the file.
        var spans: [(speechStart: Int, originStart: Int, length: Int)] = [(0, 0, samples.count)]
        var speechAudio = samples
        var vadApplied = false

        if audioDuration >= Self.vadMinimumDuration, vadEnabled, let vad = await vadManagerIfAvailable() {
            do {
                let segments = try await vad.segmentSpeech(samples)
                if !segments.isEmpty {
                    var concatenated: [Float] = []
                    var mapped: [(Int, Int, Int)] = []
                    for segment in segments {
                        let start = max(0, min(segment.startSample(sampleRate: Self.sampleRate), samples.count))
                        let end = max(start, min(segment.endSample(sampleRate: Self.sampleRate), samples.count))
                        mapped.append((concatenated.count, start, end - start))
                        concatenated.append(contentsOf: samples[start..<end])
                    }
                    speechAudio = concatenated
                    spans = mapped
                    vadApplied = true
                }
            } catch {
                log("VAD segmentation failed; using full audio: \(error.localizedDescription)")
            }
        }

        if speechAudio.count + Self.trailingSilenceSamples <= Self.maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: Self.trailingSilenceSamples)
        }

        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(speechAudio, decoderState: &decoderState, language: language)

        let tokens = (result.tokenTimings ?? []).map { timing in
            TimedToken(
                text: timing.token,
                start: Self.originTime(timing.startTime, spans: spans),
                end: Self.originTime(timing.endTime, spans: spans)
            )
        }

        return RawTranscript(
            text: TextNormalizer.shared.normalizeSentence(result.text),
            tokens: tokens,
            audioDuration: audioDuration,
            speechDuration: Double(spans.reduce(0) { $0 + $1.length }) / Double(Self.sampleRate),
            vadApplied: vadApplied
        )
    }

    func cleanup() async {
        await asrManager.cleanup()
    }

    private func vadManagerIfAvailable() async -> VadManager? {
        if let vadManager { return vadManager }
        guard !vadInitFailed else { return nil }
        do {
            vadManager = try await VadManager(config: VadConfig(defaultThreshold: Self.vadThreshold))
        } catch {
            vadInitFailed = true
            log("VAD init failed; falling back to full audio: \(error.localizedDescription)")
        }
        return vadManager
    }

    private static func originTime(_ time: TimeInterval, spans: [(speechStart: Int, originStart: Int, length: Int)]) -> TimeInterval {
        let position = Int((time * Double(sampleRate)).rounded())
        var chosen = spans[0]
        for span in spans where span.speechStart <= position {
            chosen = span
        }
        let offset = min(max(position - chosen.speechStart, 0), chosen.length)
        return Double(chosen.originStart + offset) / Double(sampleRate)
    }
}
