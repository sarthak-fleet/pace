//
//  PaceVisionOCRLanguageResolver.swift
//  leanring-buddy
//
//  Pure helper that turns the macOS user's `Locale.preferredLanguages`
//  into a `VNRecognizeTextRequest.recognitionLanguages` list. Stolen
//  from auge (https://github.com/Arthur-Ficial/auge) — their CLI lets
//  callers pass `--langs en-US,de-DE`; we derive the same list from
//  the system preference automatically.
//
//  Why this matters: Pace's old OCR path used Vision's default
//  recognition language ("en-US"), which silently mis-OCRs non-English
//  UIs (German umlauts, Japanese kana, etc.) and breaks downstream
//  click-candidate string matching. Reading the user's preferred
//  languages means OCR fidelity matches the user's actual UI without
//  any per-app configuration.
//
//  Kept actor-free + Vision-free so it stays unit-testable without
//  needing a Vision request or a live `Locale` to inject — both inputs
//  are injectable for tests.
//

import Foundation

nonisolated enum PaceVisionOCRLanguageResolver {

    /// Resolve the recognition-language list Vision should use this
    /// turn.
    ///
    /// - Parameters:
    ///   - preferredLanguagesFromLocale: typically `Locale.preferredLanguages`
    ///     at call time — BCP-47 tags in user-preference order. Injected
    ///     so tests don't depend on the host's locale.
    ///   - supportedLanguagesFromVision: the tags Vision is willing to
    ///     accept on this OS — typically `VNRecognizeTextRequest
    ///     .supportedRecognitionLanguages(for:revision:)` at startup.
    ///     Injected so tests stay Vision-free.
    ///
    /// - Returns: intersection of the two lists, preserving the user's
    ///   preference order. Falls back to `["en-US"]` when intersection
    ///   is empty so Vision still has something usable.
    static func resolveRecognitionLanguages(
        preferredLanguagesFromLocale: [String],
        supportedLanguagesFromVision: [String]
    ) -> [String] {
        let supportedNormalized = Set(supportedLanguagesFromVision.map { $0.lowercased() })

        var resolved: [String] = []
        var alreadyAdded: Set<String> = []
        for preferredTag in preferredLanguagesFromLocale {
            let preferredLowercased = preferredTag.lowercased()
            if supportedNormalized.contains(preferredLowercased),
               !alreadyAdded.contains(preferredLowercased) {
                resolved.append(preferredTag)
                alreadyAdded.insert(preferredLowercased)
                continue
            }
            // Vision tags use `en-US` shape but Locale sometimes hands
            // back the bare language code (e.g. "en"). Map back to the
            // first supported tag whose language prefix matches.
            let preferredLanguagePrefix = preferredLowercased.split(separator: "-").first.map(String.init) ?? preferredLowercased
            if let matchingSupportedTag = supportedLanguagesFromVision.first(where: { supportedTag in
                let supportedLanguagePrefix = supportedTag.lowercased().split(separator: "-").first.map(String.init) ?? supportedTag.lowercased()
                return supportedLanguagePrefix == preferredLanguagePrefix
            }), !alreadyAdded.contains(matchingSupportedTag.lowercased()) {
                resolved.append(matchingSupportedTag)
                alreadyAdded.insert(matchingSupportedTag.lowercased())
            }
        }

        if resolved.isEmpty {
            return ["en-US"]
        }
        return resolved
    }
}
