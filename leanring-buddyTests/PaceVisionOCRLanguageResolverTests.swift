//
//  PaceVisionOCRLanguageResolverTests.swift
//  leanring-buddyTests
//
//  Pins the contract of the auge-inspired language-hint resolver.
//  The downstream click-candidate scorer can't see umlauts/kana
//  correctly if Vision OCR's language hint is wrong, so regressions
//  here silently break non-English Pace users — these tests are the
//  early warning.
//

import Foundation
import Testing
@testable import Pace

struct PaceVisionOCRLanguageResolverTests {

    @Test func intersectsLocalePreferenceWithVisionSupport() async throws {
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: ["de-DE", "en-US"],
            supportedLanguagesFromVision: ["en-US", "de-DE", "ja-JP"]
        )
        #expect(resolved == ["de-DE", "en-US"])
    }

    @Test func preservesUserPreferenceOrder() async throws {
        // The user prefers German over English in their macOS settings
        // — Vision MUST run the German pass first or umlauts get
        // mis-recognised as ASCII.
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: ["de-DE", "en-US"],
            supportedLanguagesFromVision: ["en-US", "de-DE"]
        )
        #expect(resolved.first == "de-DE")
    }

    @Test func dropsTagsVisionDoesNotSupport() async throws {
        // Tag like "ckb" (Sorani Kurdish) isn't in Vision's set —
        // resolver must NOT pass it through, or Vision throws.
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: ["ckb-IQ", "en-US"],
            supportedLanguagesFromVision: ["en-US", "de-DE"]
        )
        #expect(resolved == ["en-US"])
    }

    @Test func fallsBackToEnglishWhenIntersectionIsEmpty() async throws {
        // Defensive: if the user only has unsupported languages, we'd
        // rather give Vision *something* than pass it an empty array
        // (which on some OS versions throws at request time).
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: ["xx-YY"],
            supportedLanguagesFromVision: ["en-US", "de-DE"]
        )
        #expect(resolved == ["en-US"])
    }

    @Test func bareLanguageCodeMatchesRegionalVisionTag() async throws {
        // Locale.preferredLanguages sometimes hands back "en" (no
        // region) but Vision only ships "en-US" — bare code must
        // still match by language-prefix.
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: ["en"],
            supportedLanguagesFromVision: ["en-US", "de-DE"]
        )
        #expect(resolved == ["en-US"])
    }

    @Test func dedupesEqualTagsAcrossCaseDifferences() async throws {
        // "EN-us" and "en-US" are the same tag for Vision's purposes;
        // we don't want both in the request list.
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: ["EN-us", "en-US"],
            supportedLanguagesFromVision: ["en-US"]
        )
        #expect(resolved.count == 1)
    }

    @Test func handlesEmptyPreferredLanguagesGracefully() async throws {
        // Edge case: empty locale list. Fallback path must still
        // produce a usable list.
        let resolved = PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(
            preferredLanguagesFromLocale: [],
            supportedLanguagesFromVision: ["en-US", "de-DE"]
        )
        #expect(resolved == ["en-US"])
    }
}
