//
//  PaceOCRPostProcessorTests.swift
//  leanring-buddyTests
//
//  Pins the contract of the deterministic OCR cleanup that runs at
//  cross-line join time inside `PaceScreenContextMerger.enrich`.
//  Regressing this silently fuses words across line breaks ("Mac" +
//  "OS" → "MacOS" when the original WAS "Mac-OS" the user typed) or
//  leaves stray hyphens in paragraph text the planner has to read.
//  Both failure modes silently degrade click-candidate scoring.
//

import Foundation
import Testing
@testable import Pace

struct PaceOCRPostProcessorTests {

    // MARK: - Dehyphenation behaviour

    @Test func joinsSoftHyphenatedWrapAtLineBoundary() async throws {
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([
            "this is an exam-",
            "ple of soft wrap"
        ])
        #expect(result == "this is an example of soft wrap")
    }

    @Test func preservesCompoundHyphenWithUppercaseFollowingLetter() async throws {
        // "Mac-" → "OS" is a structural compound, NOT a soft wrap.
        // Dehyphenating would fuse the two halves into "MacOS" and
        // we'd lose the visible product-name token.
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([
            "released on Mac-",
            "OS Sequoia today"
        ])
        #expect(result == "released on Mac- OS Sequoia today")
    }

    @Test func preservesHyphenAfterUppercaseOrDigitPriorChar() async throws {
        // "FY24-" + "Q3" — the character before the hyphen is a digit,
        // so this is a structural quarter label, not a wrap break.
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([
            "FY24-",
            "Q3 numbers"
        ])
        #expect(result == "FY24- Q3 numbers")
    }

    @Test func leavesTrailingHyphenOnFinalLineUntouched() async throws {
        // No "next line" to merge into — keep the dash verbatim.
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([
            "some text",
            "trailing-"
        ])
        #expect(result == "some text trailing-")
    }

    @Test func joinsRegularLinesWithSingleSpace() async throws {
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([
            "first line",
            "second line"
        ])
        #expect(result == "first line second line")
    }

    @Test func handlesEmptyInputGracefully() async throws {
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([])
        #expect(result == "")
    }

    @Test func handlesSingleLineWithoutAddedSpace() async throws {
        let result = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated(["just one"])
        #expect(result == "just one")
    }

    // MARK: - Boundary classifier

    @Test func boundaryClassifierAcceptsLowercaseLowercaseWrap() async throws {
        let shouldDehyphenate = PaceOCRPostProcessor.shouldDehyphenateBetween(
            currentLine: "exam-",
            nextLine: "ple"
        )
        #expect(shouldDehyphenate == true)
    }

    @Test func boundaryClassifierRejectsUppercaseFollowingFirstChar() async throws {
        let shouldDehyphenate = PaceOCRPostProcessor.shouldDehyphenateBetween(
            currentLine: "Mac-",
            nextLine: "OS"
        )
        #expect(shouldDehyphenate == false)
    }

    @Test func boundaryClassifierRejectsWhenNoTrailingHyphen() async throws {
        let shouldDehyphenate = PaceOCRPostProcessor.shouldDehyphenateBetween(
            currentLine: "exam",
            nextLine: "ple"
        )
        #expect(shouldDehyphenate == false)
    }

    @Test func boundaryClassifierRejectsBareDashStandalone() async throws {
        // Just "-" as a whole line is structural (a bullet, a separator)
        // — dehyphenation would do something weird.
        let shouldDehyphenate = PaceOCRPostProcessor.shouldDehyphenateBetween(
            currentLine: "-",
            nextLine: "ple"
        )
        #expect(shouldDehyphenate == false)
    }

    // MARK: - Unicode normalisation

    @Test func normalisesDecomposedDiacriticsToComposedForm() async throws {
        // Build a string in DECOMPOSED form: "e" + combining acute
        // (U+0301). Visually identical to "é" but the underlying
        // unicode-scalar representation differs from the composed
        // form. Swift's `String == String` already does canonical
        // equivalence so we have to compare scalar counts to verify
        // the inputs actually differ at the byte level.
        let decomposed = "caf\u{0065}\u{0301}"
        let composed = "caf\u{00E9}"
        #expect(decomposed.unicodeScalars.count != composed.unicodeScalars.count)

        let normalised = PaceOCRPostProcessor.normalizeUnicodeForOCRComparison(decomposed)
        #expect(normalised.unicodeScalars.count == composed.unicodeScalars.count)
    }

    @Test func normalisesAreIdempotent() async throws {
        let alreadyComposed = "café"
        let firstPass = PaceOCRPostProcessor.normalizeUnicodeForOCRComparison(alreadyComposed)
        let secondPass = PaceOCRPostProcessor.normalizeUnicodeForOCRComparison(firstPass)
        #expect(firstPass == secondPass)
        #expect(firstPass == alreadyComposed)
    }

    @Test func joinPreservesUnicodeNormalisation() async throws {
        // End-to-end: decomposed input → joined output must also be
        // composed at the scalar-count level, since the click-candidate
        // scorer downstream sometimes uses scalar-level comparisons
        // that Swift's canonical-equivalence-aware `==` would mask.
        let decomposedLine = "caf\u{0065}\u{0301}"
        let composedReference = "caf\u{00E9}"
        let joined = PaceOCRPostProcessor.joinSingleLineTextsDehyphenated([decomposedLine])
        #expect(joined.unicodeScalars.count == composedReference.unicodeScalars.count)
    }
}
