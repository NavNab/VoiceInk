import AVFoundation
import Foundation

/// Decodes a media file to 16 kHz mono Float32 samples the same way the app's
/// `AudioProcessor.processAudioToSamples` does, followed by the Int16 quantization
/// the app applies when it stores the samples as WAV before transcription.
enum AudioLoader {
    static let targetSampleRate: Double = 16_000
    private static let chunkSize: AVAudioFrameCount = 50_000_000

    enum LoadError: LocalizedError {
        case unreadable(String)
        case conversionFailed
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Cannot decode audio from \(path)"
            case .conversionFailed: return "Failed to convert the audio format"
            case .ffmpegFailed(let detail): return "ffmpeg decoding failed: \(detail)"
            }
        }
    }

    /// Loads samples with AVFoundation, falling back to an ffmpeg-decoded WAV for
    /// containers AVAudioFile cannot open (e.g. some video files).
    static func loadSamples(from url: URL, tempDirectory: URL) throws -> [Float] {
        if let audioFile = try? AVAudioFile(forReading: url) {
            return quantize(try process(audioFile))
        }
        let decoded = try decodeWithFFmpeg(url, tempDirectory: tempDirectory)
        defer { try? FileManager.default.removeItem(at: decoded) }
        guard let audioFile = try? AVAudioFile(forReading: decoded) else {
            throw LoadError.unreadable(url.path)
        }
        return quantize(try process(audioFile))
    }

    private static func process(_ audioFile: AVAudioFile) throws -> [Float] {
        let format = audioFile.processingFormat
        let totalFrames = audioFile.length
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw LoadError.conversionFailed
        }

        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(Double(totalFrames) * targetSampleRate / format.sampleRate) + 1)
        var currentFrame: AVAudioFramePosition = 0

        while currentFrame < totalFrames {
            let framesToRead = min(chunkSize, AVAudioFrameCount(totalFrames - currentFrame))
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw LoadError.conversionFailed
            }
            audioFile.framePosition = currentFrame
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)

            if format.sampleRate == targetSampleRate && format.channelCount == 1 {
                allSamples.append(contentsOf: downmixAndNormalize(inputBuffer))
            } else {
                allSamples.append(contentsOf: downmixAndNormalize(try resample(inputBuffer, to: outputFormat)))
            }
            currentFrame += AVAudioFramePosition(framesToRead)
        }
        return allSamples
    }

    private static func resample(_ inputBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw LoadError.conversionFailed
        }
        let ratio = targetSampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            throw LoadError.conversionFailed
        }

        // Feed the chunk exactly once, then signal end of stream so the converter flushes its tail.
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if error != nil || status == .error {
            throw LoadError.conversionFailed
        }
        return outputBuffer
    }

    /// Averages channels and peak-normalizes the chunk, as `convertToWhisperFormat` does.
    private static func downmixAndNormalize(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples: [Float]

        if channelCount == 1 {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            samples = [Float](repeating: 0, count: frameLength)
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                samples[frame] = sum / Float(channelCount)
            }
        }

        var maxSample: Float = 0
        for sample in samples {
            maxSample = max(maxSample, abs(sample))
        }
        if maxSample > 0 {
            for index in samples.indices {
                samples[index] /= maxSample
            }
        }
        return samples
    }

    /// Mirrors the app's Float -> Int16 WAV write and Int16 -> Float read-back.
    private static func quantize(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            let int16 = Int16(max(-1.0, min(1.0, sample)) * Float(Int16.max))
            return max(-1.0, min(Float(int16) / 32767.0, 1.0))
        }
    }

    private static func decodeWithFFmpeg(_ url: URL, tempDirectory: URL) throws -> URL {
        guard let ffmpeg = findExecutable("ffmpeg") else {
            throw LoadError.unreadable(url.path + " (AVFoundation cannot read it and ffmpeg is not installed)")
        }
        let output = tempDirectory.appendingPathComponent("decoded-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin", "-v", "error", "-y", "-i", url.path,
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_f32le", output.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            let detail = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LoadError.ffmpegFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
        return output
    }

    private static func findExecutable(_ name: String) -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
