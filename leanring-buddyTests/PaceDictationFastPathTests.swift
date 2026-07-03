//
//  PaceDictationFastPathTests.swift
//  leanring-buddyTests
//
//  Tests for the dictation fast path — verifies trigger detection
//  and the cleanup → type pipeline.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceDictationFastPathTests {

    // MARK: - Trigger detection

    @Test
    func typeTrigger_detects() {
        let result = PaceDictationFastPath.extractDictationText(from: "type hello world")
        #expect(result == "hello world")
    }

    @Test
    func dictateTrigger_detects() {
        let result = PaceDictationFastPath.extractDictationText(from: "dictate the quick brown fox")
        #expect(result == "the quick brown fox")
    }

    @Test
    func writeTrigger_doesNotDetect_composeIntentsBelongToPlanner() {
        // "write" must NOT trigger the dictation fast path — "write an
        // email to Alice" is a Mail-compose intent for the planner, not
        // literal text to type into the focused field.
        let result = PaceDictationFastPath.extractDictationText(from: "write an email to Alice about the meeting")
        #expect(result == nil)
    }

    @Test
    func noTrigger_returnsNil() {
        let result = PaceDictationFastPath.extractDictationText(from: "what's the weather today")
        #expect(result == nil)
    }

    @Test
    func emptyTranscript_returnsNil() {
        let result = PaceDictationFastPath.extractDictationText(from: "")
        #expect(result == nil)
    }

    @Test
    func triggerOnlyWithNoText_returnsNil() {
        let result = PaceDictationFastPath.extractDictationText(from: "type")
        #expect(result == nil)
    }

    @Test
    func triggerIsCaseInsensitive() {
        let result = PaceDictationFastPath.extractDictationText(from: "TYPE hello world")
        #expect(result == "hello world")
    }

    // MARK: - Dictation pipeline

    @Test
    func dictate_callsTypeTextCallback() async {
        let fastPath = PaceDictationFastPath.shared
        var typedText: String?
        fastPath.typeTextCallback = { text in
            typedText = text
        }
        defer { fastPath.typeTextCallback = nil }

        let result = await fastPath.dictate(transcript: "hello world")
        #expect(result != nil)
        #expect(typedText == result)
        #expect(result?.isEmpty == false)
    }

    @Test
    func dictate_appliesPostProcessor() async {
        let fastPath = PaceDictationFastPath.shared
        var typedText: String?
        fastPath.typeTextCallback = { text in
            typedText = text
        }
        defer { fastPath.typeTextCallback = nil }

        // "period" should be converted to "." by the post-processor
        let result = await fastPath.dictate(transcript: "hello period how are you")
        #expect(result != nil)
        #expect(typedText?.contains(".") == true)
    }

    @Test
    func dictate_returnsNilWhenNoCallback() async {
        let fastPath = PaceDictationFastPath.shared
        fastPath.typeTextCallback = nil

        let result = await fastPath.dictate(transcript: "hello world")
        #expect(result == nil)
    }

    @Test
    func dictate_returnsNilWhenDisabled() async {
        let fastPath = PaceDictationFastPath.shared
        let originalEnabled = fastPath.isEnabled
        fastPath.isEnabled = false
        defer { fastPath.isEnabled = originalEnabled }

        fastPath.typeTextCallback = { _ in }
        defer { fastPath.typeTextCallback = nil }

        let result = await fastPath.dictate(transcript: "hello world")
        #expect(result == nil)
    }

    @Test
    func dictate_capitalizesFirstLetter() async {
        let fastPath = PaceDictationFastPath.shared
        var typedText: String?
        fastPath.typeTextCallback = { text in
            typedText = text
        }
        defer { fastPath.typeTextCallback = nil }

        let result = await fastPath.dictate(transcript: "hello world")
        #expect(result?.first?.isUppercase == true)
    }

    @Test
    func dictate_emptyTranscriptReturnsNil() async {
        let fastPath = PaceDictationFastPath.shared
        fastPath.typeTextCallback = { _ in }
        defer { fastPath.typeTextCallback = nil }

        let result = await fastPath.dictate(transcript: "")
        #expect(result == nil)
    }
}
