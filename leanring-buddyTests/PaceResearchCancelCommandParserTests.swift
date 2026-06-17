//
//  PaceResearchCancelCommandParserTests.swift
//  leanring-buddyTests
//
//  Pure parser tests — alphanumeric-normalized substring matching
//  against the cancel-research phrase list.
//

import Foundation
import Testing
@testable import Pace

struct PaceResearchCancelCommandParserTests {

    @Test func recognizedCancelPhrasesReturnCancel() async throws {
        for transcript in [
            "stop researching",
            "stop researching now please",
            "cancel research",
            "cancel the research",
            "abort the research",
            "abort research",
            "stop deep research",
            "end the research",
            "drop the research",
        ] {
            #expect(
                PaceResearchCancelCommandParser.parse(transcript) == .cancel,
                "expected \(transcript) to match"
            )
        }
    }

    @Test func punctuationAndCasingDoNotPreventMatch() async throws {
        #expect(PaceResearchCancelCommandParser.parse("Stop researching!") == .cancel)
        #expect(PaceResearchCancelCommandParser.parse("STOP RESEARCHING.") == .cancel)
        #expect(PaceResearchCancelCommandParser.parse("Cancel — the research!") == .cancel)
    }

    @Test func unrelatedTranscriptDoesNotTrigger() async throws {
        #expect(PaceResearchCancelCommandParser.parse("") == nil)
        #expect(PaceResearchCancelCommandParser.parse("research the new SwiftUI APIs") == nil)
        #expect(PaceResearchCancelCommandParser.parse("I researched it yesterday") == nil)
        #expect(PaceResearchCancelCommandParser.parse("stop the music") == nil)
    }
}
