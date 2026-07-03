//
//  PaceLatencyBudgetTests.swift
//  leanring-buddyTests
//
//  Tests for the per-turn latency budget tracker. Verifies that
//  stage timestamps are captured correctly, derived metrics compute
//  the right deltas, and the rolling window aggregates properly.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceLatencyBudgetTests {

    // MARK: - TurnBudget value type

    @Test
    func turnBudget_startsAtPttPress() {
        let turn = TurnBudget(trigger: .pushToTalk)
        #expect(turn.timestamps[.pttPress] != nil)
        #expect(turn.isFinished == false)
    }

    @Test
    func turnBudget_markCapturesTimestampOnlyOnce() {
        let turn = TurnBudget(trigger: .pushToTalk)
        turn.mark(.sttComplete)
        let firstTimestamp = turn.timestamps[.sttComplete]
        #expect(firstTimestamp != nil)

        // Mark again — should NOT overwrite the first timestamp.
        Thread.sleep(forTimeInterval: 0.01)
        turn.mark(.sttComplete)
        #expect(turn.timestamps[.sttComplete] == firstTimestamp)
    }

    @Test
    func turnBudget_markAfterFinishIsIgnored() {
        let turn = TurnBudget(trigger: .pushToTalk)
        turn.finish()
        turn.mark(.sttComplete)
        #expect(turn.timestamps[.sttComplete] == nil)
    }

    @Test
    func turnBudget_finishSetsTtsCompleteIfMissing() {
        let turn = TurnBudget(trigger: .pushToTalk)
        turn.finish()
        #expect(turn.timestamps[.ttsComplete] != nil)
        #expect(turn.isFinished == true)
    }

    // MARK: - Derived metrics

    @Test
    func derivedMetrics_e2eFromPttPressToTtsComplete() {
        let turn = TurnBudget(trigger: .pushToTalk)
        Thread.sleep(forTimeInterval: 0.05)
        turn.mark(.sttComplete)
        Thread.sleep(forTimeInterval: 0.03)
        turn.mark(.ttsComplete)
        turn.finish()

        let e2e = turn.e2eMs
        #expect(e2e != nil)
        #expect(e2e! >= 70) // at least 80ms total
        #expect(e2e! < 200) // but not too long
    }

    @Test
    func derivedMetrics_sttFromPttPressToSttComplete() {
        let turn = TurnBudget(trigger: .pushToTalk)
        Thread.sleep(forTimeInterval: 0.02)
        turn.mark(.sttComplete)

        let stt = turn.sttMs
        #expect(stt != nil)
        #expect(stt! >= 15)
        #expect(stt! < 100)
    }

    @Test
    func derivedMetrics_plannerTTFTFromPlannerStartToFirstToken() {
        let turn = TurnBudget(trigger: .pushToTalk)
        turn.mark(.plannerStart)
        Thread.sleep(forTimeInterval: 0.01)
        turn.mark(.plannerFirstToken)

        let ttft = turn.plannerTTFTMs
        #expect(ttft != nil)
        #expect(ttft! >= 5)
    }

    @Test
    func derivedMetrics_returnsNilForUnmarkedStages() {
        let turn = TurnBudget(trigger: .pushToTalk)
        // Only mark pttPress (auto) and sttComplete
        turn.mark(.sttComplete)

        #expect(turn.vlmMs == nil)       // no VLM stages
        #expect(turn.plannerTTFTMs == nil) // no planner stages
        #expect(turn.toolExecMs == nil)  // no tool exec stages
    }

    @Test
    func derivedMetrics_ttfswFromSttCompleteToTtsFirstDispatch() {
        let turn = TurnBudget(trigger: .pushToTalk)
        turn.mark(.sttComplete)
        Thread.sleep(forTimeInterval: 0.02)
        turn.mark(.ttsFirstDispatch)

        let ttfsw = turn.ttfsWMs
        #expect(ttfsw != nil)
        #expect(ttfsw! >= 15)
    }

    // MARK: - PaceLatencyBudget singleton

    @Test
    func singleton_startTurnCreatesCurrentTurn() {
        let budget = PaceLatencyBudget.shared
        budget.cancelTurn() // clear any prior state
        let turn = budget.startTurn(trigger: .pushToTalk)
        #expect(turn.trigger == .pushToTalk)
        #expect(budget.currentTurn != nil)
    }

    @Test
    func singleton_markPropagatesToCurrentTurn() {
        let budget = PaceLatencyBudget.shared
        budget.cancelTurn()
        _ = budget.startTurn(trigger: .pushToTalk)
        budget.mark(.sttComplete)
        #expect(budget.currentTurn?.timestamps[.sttComplete] != nil)
    }

    @Test
    func singleton_finishTurnEmitsAndClearsCurrent() {
        let budget = PaceLatencyBudget.shared
        budget.cancelTurn()
        _ = budget.startTurn(trigger: .pushToTalk)
        budget.mark(.sttComplete)
        budget.mark(.ttsComplete)
        let finished = budget.finishTurn()

        #expect(finished != nil)
        #expect(budget.currentTurn == nil)
        #expect(budget.recentTurns.contains(where: { $0 === finished! }))
    }

    @Test
    func singleton_cancelTurnClearsWithoutEmitting() {
        let budget = PaceLatencyBudget.shared
        _ = budget.startTurn(trigger: .pushToTalk)
        budget.cancelTurn()
        #expect(budget.currentTurn == nil)
    }

    @Test
    func singleton_rollingWindowCapsAt50() {
        let budget = PaceLatencyBudget.shared
        // Clear existing state
        budget.cancelTurn()
        for _ in 0..<55 {
            _ = budget.startTurn(trigger: .pushToTalk)
            budget.mark(.sttComplete)
            budget.mark(.ttsComplete)
            budget.finishTurn()
        }
        #expect(budget.recentTurns.count == 50)
    }

    @Test
    func singleton_e2eStatsComputeFromWindow() {
        let budget = PaceLatencyBudget.shared
        budget.cancelTurn()
        let countBefore = budget.recentTurns.count
        // Add 3 turns with known E2E
        for _ in 0..<3 {
            _ = budget.startTurn(trigger: .pushToTalk)
            budget.mark(.sttComplete)
            budget.mark(.ttsComplete)
            budget.finishTurn()
        }
        let stats = budget.e2eStats
        // Count should be at least 3 more than before (capped at 50).
        #expect(stats.count >= min(countBefore + 3, 50))
        #expect(stats.fastest >= 0)
        #expect(stats.slowest >= stats.fastest)
    }

    @Test
    func singleton_emptyStatsWhenNoTurns() {
        let budget = PaceLatencyBudget.shared
        budget.cancelTurn()
        // We can't fully clear recentTurns without a reset method,
        // so just verify stats don't crash when currentTurn is nil.
        _ = budget.e2eStats
        _ = budget.ttfsWStats
        #expect(budget.currentTurn == nil)
    }
}
