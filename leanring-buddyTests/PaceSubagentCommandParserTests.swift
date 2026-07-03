//
//  PaceSubagentCommandParserTests.swift
//  leanring-buddyTests
//
//  Tests for the subagent command parser — verifies that multi-topic
//  commands are detected and split into parallel subtasks.
//

import Foundation
import Testing
@testable import Pace

struct PaceSubagentCommandParserTests {

    // MARK: - Detection

    @Test
    func researchWithCommas_detectsThreeSubtopics() {
        let result = PaceSubagentCommandParser.parse("research React, Vue, and Svelte")
        #expect(result != nil)
        #expect(result?.subtasks.count == 3)
        #expect(result?.subtasks[0].displayName == "React")
        #expect(result?.subtasks[1].displayName == "Vue")
        #expect(result?.subtasks[2].displayName == "Svelte")
    }

    @Test
    func compareWithCommas_detectsThreeSubtopics() {
        let result = PaceSubagentCommandParser.parse("compare AWS, GCP, and Azure")
        #expect(result != nil)
        #expect(result?.subtasks.count == 3)
    }

    @Test
    func researchWithAnd_detectsTwoSubtopics() {
        let result = PaceSubagentCommandParser.parse("research quantum computing and neural networks")
        #expect(result != nil)
        #expect(result?.subtasks.count == 2)
    }

    @Test
    func singleTopic_doesNotTrigger() {
        let result = PaceSubagentCommandParser.parse("research quantum computing")
        #expect(result == nil)
    }

    @Test
    func noTriggerKeyword_returnsNil() {
        let result = PaceSubagentCommandParser.parse("what's the weather like today")
        #expect(result == nil)
    }

    @Test
    func emptyTranscript_returnsNil() {
        let result = PaceSubagentCommandParser.parse("")
        #expect(result == nil)
    }

    // MARK: - Merge strategy

    @Test
    func researchUsesSummarizeMerge() {
        let result = PaceSubagentCommandParser.parse("research React, Vue, and Svelte")
        #expect(result?.mergeStrategy == .summarize)
    }

    @Test
    func compareUsesConcatenateMerge() {
        let result = PaceSubagentCommandParser.parse("compare AWS, GCP, and Azure")
        #expect(result?.mergeStrategy == .concatenate)
    }

    @Test
    func draftEmailsUsesConcatenateMerge() {
        let result = PaceSubagentCommandParser.parse("draft emails to Alice, Bob, and Carol")
        #expect(result?.mergeStrategy == .concatenate)
    }

    // MARK: - Subtask prompts

    @Test
    func researchSubtasksHaveResearchVerb() {
        let result = PaceSubagentCommandParser.parse("research cats, dogs, and birds")
        #expect(result?.subtasks[0].prompt == "research cats")
        #expect(result?.subtasks[1].prompt == "research dogs")
    }

    @Test
    func compareSubtasksHaveCompareVerb() {
        let result = PaceSubagentCommandParser.parse("compare iOS, Android, and web")
        #expect(result?.subtasks[0].prompt == "compare ios")
    }

    // MARK: - Edge cases

    @Test
    func lookIntoKeyword_detects() {
        let result = PaceSubagentCommandParser.parse("look into option A and option B")
        #expect(result != nil)
        #expect(result?.subtasks.count == 2)
    }

    @Test
    func investigateKeyword_detects() {
        let result = PaceSubagentCommandParser.parse("investigate company A, company B, and company C")
        #expect(result != nil)
        #expect(result?.subtasks.count == 3)
    }

    @Test
    func plusConjunction_splitsCorrectly() {
        let result = PaceSubagentCommandParser.parse("research topic A plus topic B")
        #expect(result != nil)
        #expect(result?.subtasks.count == 2)
    }

    // MARK: - Over-trigger guards

    @Test
    func midSentenceKeyword_doesNotTrigger() {
        // "research" appears mid-sentence — this is conversational and
        // belongs to the planner, not the subagent coordinator.
        let result = PaceSubagentCommandParser.parse("I need to research why X and Y happened")
        #expect(result == nil)
    }

    @Test
    func pronounTopics_doNotTrigger() {
        // "it" and "then tell me" are not researchable topics.
        let result = PaceSubagentCommandParser.parse("look into it and then tell me")
        #expect(result == nil)
    }

    @Test
    func politenessPrefix_stillTriggers() {
        let result = PaceSubagentCommandParser.parse("please research React and Vue")
        #expect(result != nil)
        #expect(result?.subtasks.count == 2)
    }

    @Test
    func heyPacePrefix_stillTriggers() {
        let result = PaceSubagentCommandParser.parse("hey pace compare AWS, GCP, and Azure")
        #expect(result != nil)
        #expect(result?.subtasks.count == 3)
    }
}
