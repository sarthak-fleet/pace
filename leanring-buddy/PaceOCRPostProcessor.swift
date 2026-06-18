//
//  PaceOCRPostProcessor.swift
//  leanring-buddy
//
//  Pure deterministic OCR cleanup — stolen from auge's `--clean` idea
//  (https://github.com/Arthur-Ficial/auge) but without the FoundationModels
//  round-trip cost. The auge CLI sends the full OCR string to Apple FM
//  for a holistic dehyphenate+reflow+fix pass; in Pace, OCR runs on
//  every turn so the 50-100ms FM call would compound across screen
//  captures. The deterministic version below catches the two cases
//  that actually bite Pace's downstream click-candidate scorer:
//
//    1. Cross-line hyphenation in wrapped paragraph text. Vision
//       returns one `VNRecognizedTextObservation` per visual line, so
//       a sentence wrapped as "exam-\nple sentence" arrives as TWO
//       boxes — "exam-" and "ple sentence". Without dehyphenation the
//       merged element text reads "exam- ple sentence", which breaks
//       both the planner's prose comprehension AND any string match
//       the click-candidate scorer tries against the transcript.
//
//    2. NFC Unicode normalization. macOS apps sometimes emit composed
//       diacritics ("é" U+00E9) and sometimes decomposed ("e" + U+0301).
//       The string-equality match in PaceActionExecutor's click scorer
//       can't see those as the same character. NFC normalisation makes
//       all OCR output use the composed form consistently.
//
//  Pure value-type transform — no I/O, no Vision dependency, no actor
//  isolation. Trivially unit-testable.
//

import Foundation

nonisolated enum PaceOCRPostProcessor {

    /// Join an ordered list of single-line OCR texts into a single
    /// string, dropping cross-line hyphenation where it's clear the
    /// hyphen is a soft-wrap break (line N ends with a hyphen following
    /// a lowercase letter AND line N+1 begins with a lowercase letter).
    /// Other cases (compound hyphens like "state-of-the-art", trailing
    /// dash for emphasis, hyphen after an uppercase letter as in
    /// "Mac-OS") are left alone — better to keep a stray hyphen than
    /// to accidentally fuse a real compound word.
    static func joinSingleLineTextsDehyphenated(
        _ singleLineTexts: [String]
    ) -> String {
        guard !singleLineTexts.isEmpty else { return "" }

        var resultBuffer = ""
        for (lineIndex, currentLine) in singleLineTexts.enumerated() {
            let nextLine = (lineIndex + 1 < singleLineTexts.count) ? singleLineTexts[lineIndex + 1] : nil
            let isLastLine = nextLine == nil

            if let nextLine,
               shouldDehyphenateBetween(currentLine: currentLine, nextLine: nextLine) {
                // Drop the trailing hyphen and merge directly into the
                // next line — no space between them. Example:
                //   "exam-" + "ple sentence" → "example sentence"
                let currentLineWithoutTrailingHyphen = String(currentLine.dropLast())
                resultBuffer += currentLineWithoutTrailingHyphen
                continue
            }

            resultBuffer += currentLine
            if !isLastLine {
                resultBuffer += " "
            }
        }
        return normalizeUnicodeForOCRComparison(resultBuffer)
    }

    /// Single-line normalisation pass. Apply before publishing any
    /// individual OCR box text into the downstream pipeline, so the
    /// click-candidate scorer compares like with like.
    static func normalizeUnicodeForOCRComparison(_ rawString: String) -> String {
        // NFC = canonical composition. Maps "e" + U+0301 → "é".
        return rawString.precomposedStringWithCanonicalMapping
    }

    /// Test whether the boundary between `currentLine` and `nextLine`
    /// looks like a soft hyphenation wrap.
    static func shouldDehyphenateBetween(currentLine: String, nextLine: String) -> Bool {
        guard currentLine.hasSuffix("-") else { return false }
        // Char before the trailing hyphen must be lowercase ASCII or
        // a lowercase Unicode letter; otherwise the hyphen is more
        // likely structural ("Mac-OS", "FY24-Q3").
        let trimmedCurrentLine = currentLine.dropLast()
        guard let characterImmediatelyBeforeHyphen = trimmedCurrentLine.last else { return false }
        guard characterImmediatelyBeforeHyphen.isLowercase else { return false }

        // First char of next line must be lowercase too — that's the
        // shape of a wrapped word continuation. If it's uppercase we'd
        // be fusing two distinct words, which is worse than the stray
        // hyphen.
        guard let firstCharacterOfNextLine = nextLine.first else { return false }
        guard firstCharacterOfNextLine.isLowercase else { return false }

        return true
    }
}
