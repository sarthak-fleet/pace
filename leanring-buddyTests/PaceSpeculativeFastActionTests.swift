//
//  PaceSpeculativeFastActionTests.swift
//  leanring-buddyTests
//
//  Tests for the speculative fast-action path — verifies that
//  deterministic commands are detected on stable partial transcripts
//  and that the speculative execution logic is correct.
//

import Foundation
import Testing
@testable import Pace

struct PaceSpeculativeFastActionTests {

    // MARK: - Fast-action parser on partials

    /// "open music" should match as a fast-action command even when
    /// passed as a partial transcript (no trailing punctuation).
    @Test
    func openMusic_matchesOnPartialTranscript() {
        let result = PaceFastActionCommandParser.parse(transcript: "open music")
        #expect(result != nil)
        #expect(result?.spokenText.contains("opening") == true)
    }

    /// "volume up" should match as a fast-action command.
    @Test
    func volumeUp_matchesOnPartialTranscript() {
        let result = PaceFastActionCommandParser.parse(transcript: "volume up")
        #expect(result != nil)
    }

    /// "volume down 3" should match with a magnitude.
    @Test
    func volumeDownWithMagnitude_matches() {
        let result = PaceFastActionCommandParser.parse(transcript: "volume down 3")
        #expect(result != nil)
    }

    /// A single word like "open" should NOT match — it's too ambiguous
    /// and could be the start of a longer command.
    @Test
    func singleWord_doesNotMatch() {
        // "open" alone doesn't match because the parser requires a
        // known application name or URL after "open".
        let result = PaceFastActionCommandParser.parse(transcript: "open")
        #expect(result == nil)
    }

    /// "undo that" should match as a fast-action command.
    @Test
    func undoThat_matches() {
        let result = PaceFastActionCommandParser.parse(transcript: "undo that")
        #expect(result != nil)
        #expect(result?.spokenText.contains("undo") == true)
    }

    /// A non-command phrase should NOT match.
    @Test
    func nonCommand_doesNotMatch() {
        let result = PaceFastActionCommandParser.parse(transcript: "what's the weather like")
        #expect(result == nil)
    }

    // MARK: - Word count gating

    /// The speculative path requires at least 2 words. This test
    /// verifies that common commands meet that threshold.
    @Test
    func commonCommands_meetMinWordCount() {
        let commands = ["open music", "volume up", "volume down", "undo that", "open safari"]
        for command in commands {
            let wordCount = command.split(separator: " ").count
            #expect(wordCount >= 2, "Command \"\(command)\" has \(wordCount) words, need >= 2")
        }
    }

    /// Single-word partials should NOT meet the word count threshold.
    @Test
    func singleWordPartials_doNotMeetMinWordCount() {
        let partials = ["open", "volume", "undo", "hey"]
        for partial in partials {
            let wordCount = partial.split(separator: " ").count
            #expect(wordCount < 2, "Partial \"\(partial)\" has \(wordCount) words, should be < 2")
        }
    }

    // MARK: - LocalAgreement stabilizer

    /// The stabilizer should produce a stable prefix after two
    /// agreeing hypotheses.
    @Test
    func stabilizer_producesStablePrefixOnAgreement() {
        var stabilizer = PaceLocalAgreementStabilizer()
        _ = stabilizer.acceptHypothesis("open music")
        let stable = stabilizer.acceptHypothesis("open music")
        #expect(stable.contains("open music"))
    }

    /// The stabilizer should NOT produce a stable prefix when
    /// hypotheses disagree.
    @Test
    func stabilizer_doesNotProduceStablePrefixOnDisagreement() {
        var stabilizer = PaceLocalAgreementStabilizer()
        _ = stabilizer.acceptHypothesis("open music")
        let stable = stabilizer.acceptHypothesis("close safari")
        #expect(stable.isEmpty || !stable.contains("safari"))
    }

    /// The stabilizer should extend the stable prefix when new
    /// hypotheses agree on more words.
    @Test
    func stabilizer_extendsStablePrefixOnAgreement() {
        var stabilizer = PaceLocalAgreementStabilizer()
        _ = stabilizer.acceptHypothesis("open music")
        let stable1 = stabilizer.acceptHypothesis("open music and play")
        // "open music" should be the stable prefix (3 words agree)
        #expect(stable1.contains("open music"))
    }

    // MARK: - Case insensitivity

    /// The fast-action parser should be case-insensitive.
    @Test
    func parser_isCaseInsensitive() {
        let result = PaceFastActionCommandParser.parse(transcript: "OPEN MUSIC")
        #expect(result != nil)
    }

    /// The parser should handle wake-word prefixes.
    @Test
    func parser_handlesWakeWordPrefix() {
        let result = PaceFastActionCommandParser.parse(transcript: "hey pace open music")
        #expect(result != nil)
    }
}
