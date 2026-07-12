//
//  PaceMLXScreenAnalysisClient.swift
//  leanring-buddy
//
//  Phase C: in-process VLM. Runs Qwen3-VL-4B-Instruct-4bit (default)
//  directly via `mlx-swift-examples` MLXVLM instead of LM Studio's
//  loopback HTTP. Conforms to `PaceScreenAnalysisClient` so the
//  existing PaceScreenContextService consumes it unchanged.
//
//  When MLXVLM is linked AND the user has opted into bundled VLM,
//  this client takes over the screen-analysis path. Otherwise the
//  factory falls back to the LM Studio HTTP client (unchanged
//  pre-Phase-C behavior).
//
//  Quality posture: SAME model (Qwen3-VL). The win is dropping the
//  HTTP round-trip and the LM Studio max-loaded-models=2 brittleness,
//  not raw model accuracy.
//

import Foundation

#if canImport(MLXVLM)
import MLX
import MLXLMCommon
import MLXVLM
import CoreImage
import AppKit
#endif

nonisolated enum PaceMLXScreenAnalysisError: LocalizedError {
    case runtimeNotLinked
    case modelLoadFailed(underlyingErrorDescription: String)
    case inferenceFailed(underlyingErrorDescription: String)
    case unableToDecodeImageData

    var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "MLXVLM runtime not linked. Add the MLXVLM product from mlx-swift-examples in Xcode → Project → Package Dependencies."
        case .modelLoadFailed(let underlyingErrorDescription):
            return "MLXVLM model load failed: \(underlyingErrorDescription)"
        case .inferenceFailed(let underlyingErrorDescription):
            return "MLXVLM inference failed: \(underlyingErrorDescription)"
        case .unableToDecodeImageData:
            return "Could not decode screenshot image bytes for the VLM."
        }
    }
}

final class PaceMLXScreenAnalysisClient: PaceScreenAnalysisClient, @unchecked Sendable {

    nonisolated static var isRuntimeAvailable: Bool {
        #if canImport(MLXVLM)
        return true
        #else
        return false
        #endif
    }

    private let modelIdentifier: String

    let displayName: String

    init(modelIdentifier: String = "mlx-community/Qwen3-VL-4B-Instruct-4bit") {
        self.modelIdentifier = modelIdentifier
        self.displayName = "MLXVLM in-process (\(Self.shortenedModelLabel(forIdentifier: modelIdentifier)))"
    }

    nonisolated static func shortenedModelLabel(forIdentifier modelIdentifier: String) -> String {
        // "mlx-community/Qwen3-VL-4B-Instruct-4bit" → "Qwen3-VL-4B"
        let lastSegment = modelIdentifier.split(separator: "/").last.map(String.init) ?? modelIdentifier
        return lastSegment
            .replacingOccurrences(of: "-Instruct-4bit", with: "")
            .replacingOccurrences(of: "-Instruct-8bit", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
    }

    // MARK: - PaceScreenAnalysisClient

    func analyzeScreenshot(
        screenshotImageData: Data,
        userIntent: String
    ) async throws -> LocalVLMScreenAnalysis {
        #if canImport(MLXVLM)
        let modelContainer: ModelContainer
        do {
            modelContainer = try await Self.sharedModelContainer(modelIdentifier: modelIdentifier)
        } catch {
            throw PaceMLXScreenAnalysisError.modelLoadFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        let promptText = Self.buildScreenAnalysisPrompt(userIntent: userIntent)
        let userInputImage = try Self.makeUserInputImage(from: screenshotImageData)

        let modelResponseText: String
        do {
            modelResponseText = try await modelContainer.perform { context in
                let userInput = UserInput(
                    chat: [
                        .system(Self.systemInstruction),
                        .user(promptText, images: [userInputImage], videos: []),
                    ]
                )
                let modelInput = try await context.processor.prepare(input: userInput)
                let stream = try MLXLMCommon.generate(
                    input: modelInput,
                    parameters: GenerateParameters(temperature: 0.0),
                    context: context
                )
                var accumulatedText = ""
                for await event in stream {
                    if case .chunk(let text) = event {
                        accumulatedText += text
                    }
                }
                return accumulatedText
            }
        } catch {
            throw PaceMLXScreenAnalysisError.inferenceFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        return try Self.parseVLMResponseToScreenAnalysis(modelResponseText)
        #else
        _ = (screenshotImageData, userIntent)
        throw PaceMLXScreenAnalysisError.runtimeNotLinked
        #endif
    }

    // MARK: - Pure helpers (testable without MLXVLM)

    /// The same prompt the LM Studio HTTP client uses — see
    /// `LocalVLMHTTPScreenAnalysisClient.analyzeScreenshot` for the
    /// canonical version. We keep the prompt text identical so the
    /// VLM output schema matches the existing parser.
    nonisolated static let systemInstruction: String = """
    You are a UI vision model. Output STRICT JSON only — no prose, no \
    markdown fences, no commentary outside the JSON object.

    Schema. `elements` FIRST, `description` LAST and SHORT:
    {"elements":[{"label":"<≤4 words>","role":"<button|text_field|static_text|link|image|menu_item|checkbox|tab|other>","bbox":[<x>,<y>,<w>,<h>],"text":"<verbatim or null>"}],"description":"<≤20 words, app + main view>"}

    HARD FORMATTING RULES — failure to follow these causes truncation:
    - Compact JSON only. NO indentation, NO newlines inside the object.
    - No trailing commas. Strings double-quoted. `text:null` (not \
      `text:"null"`) for non-text elements.
    - Coordinates are screen pixels, top-left origin.

    CONTENT RULES:
    - `description` is one terse sentence, not a paragraph.
    - Prefer high recall on interactive elements (buttons, fields, \
      links, tabs). Skip purely decorative chrome.
    - If the user intent below names a target, list that element first.
    """

    nonisolated static func buildScreenAnalysisPrompt(userIntent: String) -> String {
        let trimmedIntent = userIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        let intentLine = trimmedIntent.isEmpty
            ? "User intent: (unspecified — analyse the whole screen)"
            : "User intent: \(trimmedIntent)"
        return "\(intentLine)\n\nAnalyse the screenshot and return the JSON element map."
    }

    /// Try to parse the model's raw text into a LocalVLMScreenAnalysis.
    /// First attempts strict JSON decode; on failure scans for a JSON
    /// object inside the text (handles the "model added a stray prose
    /// preamble" case the HTTP client also has to deal with).
    nonisolated static func parseVLMResponseToScreenAnalysis(_ rawText: String) throws -> LocalVLMScreenAnalysis {
        let decoder = JSONDecoder()
        if let bytes = rawText.data(using: .utf8),
           let decoded = try? decoder.decode(LocalVLMScreenAnalysis.self, from: bytes) {
            return decoded
        }
        // Regex-extract the first {...} that looks like an analysis
        // object. Same fallback shape as the HTTP client.
        if let bracedSubstring = extractFirstJSONObjectSubstring(in: rawText),
           let bytes = bracedSubstring.data(using: .utf8),
           let decoded = try? decoder.decode(LocalVLMScreenAnalysis.self, from: bytes) {
            return decoded
        }
        throw PaceMLXScreenAnalysisError.inferenceFailed(
            underlyingErrorDescription: "VLM output did not contain a parseable LocalVLMScreenAnalysis JSON object"
        )
    }

    nonisolated static func extractFirstJSONObjectSubstring(in text: String) -> String? {
        // Greedy match the first `{ ... }` pair that contains an
        // `"elements"` key. Sufficient because the schema starts with
        // that key by construction.
        guard let openBraceIndex = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        for currentIndex in text[openBraceIndex...].indices {
            let character = text[currentIndex]
            if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[openBraceIndex...currentIndex])
                }
            }
        }
        return nil
    }

    #if canImport(MLXVLM)
    /// Decode the JPEG/PNG bytes into a `UserInput.Image`. The
    /// MLXVLM processor accepts CIImage / CGImage / URL — Pace
    /// hands us JPEG bytes from ScreenCaptureKit, so we go through
    /// CIImage which is the cheapest in-memory path.
    nonisolated static func makeUserInputImage(from imageBytes: Data) throws -> UserInput.Image {
        guard let nsImage = NSImage(data: imageBytes),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PaceMLXScreenAnalysisError.unableToDecodeImageData
        }
        let ciImage = CIImage(cgImage: cgImage)
        return UserInput.Image.ciImage(ciImage)
    }

    /// Single per-process model container. The 4B Qwen3-VL assets
    /// are ~2.5 GB dequantised; loading them multiple times would
    /// blow memory.
    private static var cachedModelContainer: ModelContainer?
    private static let modelLoadLock = NSLock()

    private static func sharedModelContainer(
        modelIdentifier: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        modelLoadLock.lock()
        let cached = cachedModelContainer
        modelLoadLock.unlock()
        if let cached { return cached }

        let factory = VLMModelFactory.shared
        let configuration = ModelConfiguration(id: modelIdentifier)
        let loaded = try await factory.loadContainer(
            configuration: configuration,
            progressHandler: progressHandler
        )

        modelLoadLock.lock()
        cachedModelContainer = loaded
        modelLoadLock.unlock()
        return loaded
    }
    #endif
}
