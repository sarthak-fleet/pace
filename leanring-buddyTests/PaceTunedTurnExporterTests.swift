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

    // Research and cloud/bridge (Codex) turns are now COLLECTED (they used
    // to be skipped) so the teacher brain can be distilled into Pace's own
    // model. Each row must carry provenance so distilled-from-commercial
    // turns can be filtered out before training/shipping.
    func testExporterCollectsResearchTurnWithProvenance() {
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
        let row = PaceTunedTurnExporter.makeExportRow(record: record, systemPrompt: "system")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.messages.count, 3)
        XCTAssertTrue(row?.meta.routing?.contains("research") ?? false)
    }

    func testExporterCollectsCloudBridgeTurnTaggedWithProvenance() {
        let record = PaceToolCallDebugRecord(
            transcript: "summarize this page",
            lane: .planner,
            routingDetail: "screenDescription · conf 0.9 · cloud bridge",
            plannerPathDetail: "cloud bridge (codex/gpt-4-1106-preview)",
            rawPlannerOutput: #"{"spokenText":"here's the gist"}"#,
            spokenText: "here's the gist",
            parsedActionsSummary: "no actions parsed",
            dispatchSummary: "spoken-only",
            userPrompt: "summarize this page"
        )
        let row = PaceTunedTurnExporter.makeExportRow(record: record, systemPrompt: "system")
        XCTAssertNotNil(row)
        // Distillation source is recorded so it can be filtered pre-training.
        XCTAssertEqual(row?.meta.plannerProvenance, "cloud bridge (codex/gpt-4-1106-preview)")
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
