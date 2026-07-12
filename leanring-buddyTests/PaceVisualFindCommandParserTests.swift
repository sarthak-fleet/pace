//
//  PaceVisualFindCommandParserTests.swift
//  leanring-buddyTests
//
//  Pure parser tests — no CompanionManager construction, no OCR, no
//  screenshot. Verifies the phrase matrix (matches + non-matches) and
//  query extraction / quote-stripping.
//

import Testing
@testable import Pace

struct PaceVisualFindCommandParserTests {

    // MARK: - Matching forms extract the right query

    @Test func findOnScreenFormsMatchAndExtractQuery() async throws {
        let matchingCases: [(transcript: String, expectedQuery: String)] = [
            ("find account on screen", "account"),
            ("find the login button on screen", "login button"),
            ("find me the submit button on the screen", "submit button"),
            ("search for total balance on my screen", "total balance"),
            ("highlight the error message on screen", "error message"),
            ("mark checkout on screen", "checkout"),
            ("where is the settings gear on screen", "settings gear"),
            ("where's the send button on the screen", "send button"),
            ("locate the password field on screen", "password field"),
        ]
        for testCase in matchingCases {
            let command = PaceVisualFindCommandParser.parse(testCase.transcript)
            #expect(
                command?.searchQuery == testCase.expectedQuery,
                "expected '\(testCase.transcript)' → query '\(testCase.expectedQuery)', got \(String(describing: command?.searchQuery))"
            )
        }
    }

    @Test func showMeWhereFormMatchesWithoutScreenMarker() async throws {
        let matchingCases: [(transcript: String, expectedQuery: String)] = [
            ("show me where the account balance is", "account balance"),
            ("show me where the save button is located", "save button"),
            ("show where the search bar is", "search bar"),
            ("show me the download link", "download link"),
        ]
        for testCase in matchingCases {
            let command = PaceVisualFindCommandParser.parse(testCase.transcript)
            #expect(
                command?.searchQuery == testCase.expectedQuery,
                "expected '\(testCase.transcript)' → query '\(testCase.expectedQuery)', got \(String(describing: command?.searchQuery))"
            )
        }
    }

    // MARK: - Quote stripping

    @Test func wrappingQuotesAreStrippedFromQuery() async throws {
        #expect(
            PaceVisualFindCommandParser.parse("find \"account balance\" on screen")?.searchQuery
                == "account balance"
        )
        #expect(
            PaceVisualFindCommandParser.parse("find 'sign out' on screen")?.searchQuery == "sign out"
        )
        // Curly quotes (as some dictation engines emit) are stripped too.
        #expect(
            PaceVisualFindCommandParser.parse("find \u{201C}reset\u{201D} on screen")?.searchQuery
                == "reset"
        )
    }

    // MARK: - Case / punctuation tolerance

    @Test func casingIsToleratedAndQueryCasingPreserved() async throws {
        #expect(
            PaceVisualFindCommandParser.parse("FIND API Key on screen")?.searchQuery == "API Key"
        )
    }

    // MARK: - Non-matches

    @Test func plainChitchatDoesNotMatch() async throws {
        // The headline non-match: no screen marker, no "show me where" —
        // must not trigger a screen search.
        #expect(PaceVisualFindCommandParser.parse("find my keys") == nil)
        #expect(PaceVisualFindCommandParser.parse("find me a good restaurant nearby") == nil)
        #expect(PaceVisualFindCommandParser.parse("search for the best pizza") == nil)
        #expect(PaceVisualFindCommandParser.parse("where is the nearest gas station") == nil)
    }

    @Test func skillRunPhrasesAreUntouched() async throws {
        // "run the find skill" belongs to the skill parser (which runs
        // BEFORE this one). Even parsed in isolation it must not match:
        // no leading find/search/where verb, no screen marker.
        #expect(PaceVisualFindCommandParser.parse("run the find skill") == nil)
        #expect(PaceVisualFindCommandParser.parse("run the cat search skill") == nil)
        #expect(PaceVisualFindCommandParser.parse("install the find files skill") == nil)
    }

    @Test func emptyQueryReturnsNil() async throws {
        #expect(PaceVisualFindCommandParser.parse("") == nil)
        // Verb + screen marker but no actual query text between them.
        #expect(PaceVisualFindCommandParser.parse("find on screen") == nil)
        #expect(PaceVisualFindCommandParser.parse("show me where is") == nil)
    }

    @Test func screenMarkerAloneWithoutFindVerbDoesNotMatch() async throws {
        // Has "on screen" but no find/search/locate verb — not a search.
        #expect(PaceVisualFindCommandParser.parse("what is on screen") == nil)
        #expect(PaceVisualFindCommandParser.parse("read what is on the screen") == nil)
    }
}
