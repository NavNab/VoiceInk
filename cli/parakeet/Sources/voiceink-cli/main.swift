import FluidAudio
import Foundation

let toolVersion = "1.0.0"

enum CLIError: LocalizedError {
    case usage(String)
    case modelMissing(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .modelMissing(let path):
            return "Parakeet models not found at \(path). Download the model once in VoiceInk (Settings > AI Models)."
        }
    }
}

nonisolated(unsafe) var quietMode = false

func log(_ message: String) {
    guard !quietMode else { return }
    FileHandle.standardError.write(Data(("voiceink-cli: " + message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("voiceink-cli: error: " + message + "\n").utf8))
    exit(2)
}

let usage = """
    Usage: voiceink-cli [options] <file> [<file>...]

    Transcribe audio or video files locally with NVIDIA Parakeet (FluidAudio), using the
    same pipeline and post-processing as the VoiceInk app. Models are read from the local
    FluidAudio cache; nothing is downloaded.

    Options:
      -f, --format txt|json|srt  Output format (default: txt)
      -o, --output PATH          Output file (single input) or directory (several inputs).
                                 Without it, a single input is written to stdout.
          --lang CODE            Script hint for the decoder (en, fr, de, es, it, pt, ...).
                                 Default: auto, as in the app.
          --model NAME           parakeet-tdt-0.6b-v3 (default) or parakeet-tdt-0.6b-v2
          --skip-existing        Skip inputs whose output file already exists
          --no-vad               Disable voice activity detection (app setting by default)
          --no-format            Disable paragraph formatting (app setting by default)
          --keep-fillers         Keep filler words (app setting by default)
          --no-replacements      Skip the VoiceInk dictionary word replacements
      -q, --quiet                Suppress progress messages on stderr
      -h, --help                 Show this help
          --version              Show the version

    Exit status: 0 when every file succeeded, 1 when at least one file failed, 2 on usage errors.
    """

struct Options {
    var inputs: [String] = []
    var format: OutputFormat = .txt
    var output: String?
    var language: Language?
    var modelName = "parakeet-tdt-0.6b-v3"
    var skipExisting = false
    var disableVAD = false
    var disableFormatting = false
    var keepFillers = false
    var disableReplacements = false
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    func value(for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw CLIError.usage("Missing value for \(flag)") }
        return arguments[index]
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-f", "--format":
            let raw = try value(for: argument)
            guard let format = OutputFormat(rawValue: raw.lowercased()) else {
                throw CLIError.usage("Unknown format '\(raw)'. Use txt, json or srt.")
            }
            options.format = format
        case "-o", "--output":
            options.output = try value(for: argument)
        case "--lang", "--language":
            let raw = try value(for: argument).lowercased()
            if raw == "auto" {
                options.language = nil
            } else if let language = Language(rawValue: raw) {
                options.language = language
            } else {
                let supported = Language.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.usage("Unsupported language '\(raw)'. Use auto or one of: \(supported)")
            }
        case "--model":
            let raw = try value(for: argument)
            guard ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2"].contains(raw) else {
                throw CLIError.usage("Unsupported model '\(raw)'. Use parakeet-tdt-0.6b-v3 or parakeet-tdt-0.6b-v2.")
            }
            options.modelName = raw
        case "--skip-existing": options.skipExisting = true
        case "--no-vad": options.disableVAD = true
        case "--no-format": options.disableFormatting = true
        case "--keep-fillers": options.keepFillers = true
        case "--no-replacements": options.disableReplacements = true
        case "-q", "--quiet": quietMode = true
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--version":
            print("voiceink-cli \(toolVersion)")
            exit(0)
        case "--":
            options.inputs += arguments[(index + 1)...]
            index = arguments.count
            continue
        default:
            if argument.hasPrefix("-") {
                throw CLIError.usage("Unknown option '\(argument)'")
            }
            options.inputs.append(argument)
        }
        index += 1
    }

    guard !options.inputs.isEmpty else { throw CLIError.usage("No input file given.") }
    if options.inputs.count > 1 && options.output == nil {
        throw CLIError.usage("Several inputs need --output DIR.")
    }
    if options.skipExisting && options.output == nil {
        throw CLIError.usage("--skip-existing needs --output.")
    }
    return options
}

func outputURL(for input: URL, options: Options) -> URL? {
    guard let output = options.output else { return nil }
    let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
    if options.inputs.count > 1 || (exists && isDirectory.boolValue) {
        let name = input.deletingPathExtension().lastPathComponent + "." + options.format.fileExtension
        return outputURL.appendingPathComponent(name)
    }
    return outputURL
}

func formatSeconds(_ seconds: TimeInterval) -> String {
    String(format: "%.1fs", seconds)
}

func run() async -> Int32 {
    let options: Options
    do {
        options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    } catch {
        fail("\(error.localizedDescription)\n\n\(usage)")
    }

    var settings = AppSettings.load()
    if options.disableVAD { settings.vadEnabled = false }
    if options.disableFormatting { settings.textFormattingEnabled = false }
    if options.keepFillers { settings.removeFillerWords = false }

    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voiceink-cli-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    } catch {
        fail("Cannot create temporary directory: \(error.localizedDescription)")
    }
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    if let output = options.output, options.inputs.count > 1 {
        do {
            try FileManager.default.createDirectory(
                atPath: (output as NSString).expandingTildeInPath, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: tempDirectory)
            fail("Cannot create output directory: \(error.localizedDescription)")
        }
    }

    var replacements: [ReplacementRule] = []
    if !options.disableReplacements {
        do {
            replacements = try DictionaryStore.loadReplacements(
                from: DictionaryStore.defaultStoreURL, tempDirectory: tempDirectory)
        } catch {
            log("warning: \(error.localizedDescription); continuing without word replacements")
        }
    }
    let postProcessor = PostProcessor(settings: settings, replacements: replacements)
    log("settings: vad=\(settings.vadEnabled) format=\(settings.textFormattingEnabled) fillers-removed=\(settings.removeFillerWords) replacements=\(replacements.count) lang=\(options.language?.rawValue ?? "auto")")

    let version: AsrModelVersion = options.modelName.hasSuffix("v2") ? .v2 : .v3
    let loadStart = Date()
    let transcriber: Transcriber
    do {
        transcriber = try await Transcriber.make(
            version: version, vadEnabled: settings.vadEnabled, language: options.language)
    } catch {
        try? FileManager.default.removeItem(at: tempDirectory)
        fail(error.localizedDescription)
    }
    log("loaded \(options.modelName) in \(formatSeconds(Date().timeIntervalSince(loadStart)))")

    var failures = 0
    for (position, path) in options.inputs.enumerated() {
        let input = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let prefix = "[\(position + 1)/\(options.inputs.count)] \(input.lastPathComponent)"
        let destination = outputURL(for: input, options: options)

        if options.skipExisting, let destination, FileManager.default.fileExists(atPath: destination.path) {
            log("\(prefix): skipped, \(destination.path) exists")
            continue
        }

        do {
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw CLIError.usage("File not found: \(input.path)")
            }
            let start = Date()
            let samples = try AudioLoader.loadSamples(from: input, tempDirectory: tempDirectory)
            let decodeSeconds = Date().timeIntervalSince(start)

            let raw = try await transcriber.transcribe(samples)
            let processingSeconds = Date().timeIntervalSince(start)

            let document = TranscriptDocument(
                file: input.path,
                model: options.modelName,
                duration: raw.audioDuration,
                speechDuration: raw.speechDuration,
                vadApplied: raw.vadApplied,
                processingSeconds: processingSeconds,
                text: postProcessor.process(raw.text, formatParagraphs: true),
                segments: options.format == .txt
                    ? [] : SegmentBuilder.build(from: raw.tokens, postProcessor: postProcessor)
            )
            let rendered = try Renderer.render(document, as: options.format)

            if let destination {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rendered.write(to: destination, atomically: true, encoding: .utf8)
            } else {
                FileHandle.standardOutput.write(Data(rendered.utf8))
            }

            let speed = processingSeconds > 0 ? raw.audioDuration / processingSeconds : 0
            let target = destination.map { " -> \($0.path)" } ?? ""
            log("\(prefix): \(formatSeconds(raw.audioDuration)) audio in \(formatSeconds(processingSeconds)) (decode \(formatSeconds(decodeSeconds)), \(String(format: "%.1f", speed))x realtime)\(target)")
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("voiceink-cli: error: \(prefix): \(error.localizedDescription)\n".utf8))
        }
    }

    await transcriber.cleanup()
    return failures == 0 ? 0 : 1
}

exit(await run())
