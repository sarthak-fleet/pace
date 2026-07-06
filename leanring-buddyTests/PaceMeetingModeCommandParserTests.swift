//
//  PaceMeetingModeCommandParserTests.swift
//  leanring-buddyTests
//
//  Covers voice-triggered meeting start/stop with profile selection:
//  "start my one-on-one recording" pins the one-on-one profile, generic
//  starts leave the profile to normal precedence, stop/status still work,
//  and generic verbs ("record a memo") don't hijack the planner.
//

import Foundation
import Testing

@testable import Pace

struct PaceMeetingModeCommandParserTests {

    private var profiles: [PaceMeetingNoteProfile] {
        [
            .general,
            PaceMeetingNoteProfile(
                slug: "standup", name: "Daily Standup", description: "d",
                sections: [.init(key: "s", title: "S", instruction: "i")],
                emitsActionItems: true, emitsDecisions: false, groundsActionItems: true,
                voiceAliases: ["standup", "stand up", "daily standup", "scrum"]
            ),
            PaceMeetingNoteProfile(
                slug: "one-on-one", name: "One-on-One", description: "d",
                sections: [.init(key: "s", title: "S", instruction: "i")],
                emitsActionItems: true, emitsDecisions: false, groundsActionItems: true,
                voiceAliases: ["one-on-one", "one on one", "1 on 1", "1:1"]
            ),
        ]
    }

    private func parse(_ t: String) -> PaceMeetingModeCommand? {
        PaceMeetingModeCommandParser.parse(t, profiles: profiles)
    }

    // MARK: - Named-profile starts (the headline use case)

    @Test func startMyOneOnOneRecordingPinsOneOnOne() {
        #expect(parse("Hey Pace, start my one-on-one recording") == .start(profileSlug: "one-on-one"))
    }

    @Test func recordThisStandupPinsStandup() {
        #expect(parse("record this standup") == .start(profileSlug: "standup"))
    }

    @Test func startAOneToOneViaAliasPinsOneOnOne() {
        #expect(parse("start a 1:1") == .start(profileSlug: "one-on-one"))
        #expect(parse("start my daily standup") == .start(profileSlug: "standup"))
    }

    // MARK: - Generic start (no profile → normal precedence)

    @Test func genericStartsCarryNoProfile() {
        #expect(parse("start meeting mode") == .start(profileSlug: nil))
        #expect(parse("start recording") == .start(profileSlug: nil))
        #expect(parse("meeting mode") == .start(profileSlug: nil))
        #expect(parse("start the meeting") == .start(profileSlug: nil))
    }

    // MARK: - Stop / status

    @Test func stopPhrasingsStop() {
        #expect(parse("stop the meeting") == .stop)
        #expect(parse("stop meeting mode") == .stop)
        #expect(parse("stop my one-on-one") == .stop)
        #expect(parse("end the meeting") == .stop)
    }

    @Test func statusPhrasing() {
        #expect(parse("is meeting mode on") == .status)
        #expect(parse("meeting mode status") == .status)
    }

    // MARK: - No false positives

    @Test func genericVerbsWithoutMeetingContextDoNotMatch() {
        #expect(parse("record a memo") == nil)
        #expect(parse("what's on my calendar") == nil)
        #expect(parse("start the timer for 5 minutes") == nil)
    }

    // MARK: - Lenient decode

    @Test func profileWithoutVoiceAliasesDecodesWithEmptyAliases() throws {
        let json = """
        {"slug":"custom","name":"Custom","description":"d","sections":[{"key":"s","title":"S","instruction":"i"}],"emitsActionItems":true,"emitsDecisions":true,"groundsActionItems":false}
        """
        let data = try #require(json.data(using: .utf8))
        let profile = try JSONDecoder().decode(PaceMeetingNoteProfile.self, from: data)
        #expect(profile.voiceAliases.isEmpty)
    }
}
