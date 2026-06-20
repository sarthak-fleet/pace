//
//  PaceTunedTurnExporterTests.swift
//  leanring-buddyTests
//

import XCTest
@testable import Pace

final class PaceTunedTurnExporterTests: XCTestCase {
    func testAnonymizerRedactsEmailAndHomePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let input = "mail me at sarthak@example.com from \(home)/Documents/secret.txt"
        let output = PaceTunedTurnAnonymizer.anonymize(input)
        XCTAssertFalse(output.contains("sarthak@example.com"))
        XCTAssertFalse(output.contains(home))
        XCTAssertTrue(output.contains("[redacted-email]") || output.contains("~"))
    }

    func testExporterSkipsFastPath() {
        let record = PaceToolCallDebugRecord(
            transcript: "volume up",
            lane: .fastPath,
            routingDetail: "fast local parser matched",
            rawPlannerOutput: "",
            spokenText: "turning volume up",
            parsedActionsSummary: "volume_up",
            dispatchSummary: "executed"
        )
        XCTAssertNil(
            PaceTunedTurnExporter.makeExportRow(
                record: record,
                systemPrompt: "system"
            )
        )
    }

    func testExporterSkipsResearchTurns() {
        let record = PaceToolCallDebugRecord(
            transcript: "research quantum dots",
            lane: .planner,
            routingDetail: "research · conf 0.91 · local",
            rawPlannerOutput: #"{"spokenText":"here is what I found"}"#,
            spokenText: "here is what I found",
            parsedActionsSummary: "no actions parsed",
            dispatchSummary: "spoken-only",
            userPrompt: "research quantum dots"
        )
        XCTAssertNil(
            PaceTunedTurnExporter.makeExportRow(
                record: record,
                systemPrompt: "system"
            )
        )
    }

    func testExporterBuildsMessagesShape() {
        let record = PaceToolCallDebugRecord(
            transcript: "click save",
            lane: .planner,
            routingDetail: "screenAction · conf 0.88 · local",
            rawPlannerOutput: #"{"spokenText":"saving","intent":"act","payload":{"calls":[{"name":"key","args":{"combo":"cmd+s"}}]}}"#,
            spokenText: "saving",
            parsedActionsSummary: "key: cmd+s",
            dispatchSummary: "executed",
            userPrompt: "USER: click save\nELEMENT: [0] button|10,10|Save|Save"
        )
        let row = PaceTunedTurnExporter.makeExportRow(
            record: record,
            systemPrompt: "You are Pace."
        )
        XCTAssertEqual(row?.messages.count, 3)
        XCTAssertEqual(row?.messages.first?.role, "system")
        XCTAssertEqual(row?.messages.last?.role, "assistant")
        XCTAssertTrue(row?.messages.last?.content.contains("spokenText") ?? false)
    }
}
