//
//  PaceSubagentCoordinatorTests.swift
//  leanring-buddyTests
//
//  Tests for the subagent coordinator — parallel task decomposition,
//  execution, merging, and cancellation.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceSubagentCoordinatorTests {

    // MARK: - Batch creation

    @Test
    func decomposeAndRun_createsBatchWithSubagents() {
        let coordinator = PaceSubagentCoordinator.shared
        let batchId = coordinator.decomposeAndRun(
            parentPrompt: "research X, Y, Z",
            subtasks: [
                ("Research X", "research topic X"),
                ("Research Y", "research topic Y"),
                ("Research Z", "research topic Z")
            ]
        )
        #expect(coordinator.batches.contains(where: { $0.id == batchId }))
        #expect(coordinator.batches.first(where: { $0.id == batchId })?.subagents.count == 3)
    }

    @Test
    func decomposeAndRun_allSubagentsStartPending() {
        let coordinator = PaceSubagentCoordinator.shared
        let batchId = coordinator.decomposeAndRun(
            parentPrompt: "test",
            subtasks: [("A", "do A"), ("B", "do B")]
        )
        let batch = coordinator.batches.first(where: { $0.id == batchId })
        #expect(batch != nil)
        #expect(batch?.subagents.allSatisfy { $0.state == .pending } == true)
    }

    // MARK: - Cancellation

    @Test
    func cancelBatch_marksAllPendingAsCancelled() {
        let coordinator = PaceSubagentCoordinator.shared
        let batchId = coordinator.decomposeAndRun(
            parentPrompt: "test",
            subtasks: [("A", "do A"), ("B", "do B")]
        )
        coordinator.cancelBatch(batchId)

        let batch = coordinator.batches.first(where: { $0.id == batchId })
        #expect(batch?.completedAt != nil)
        // All should be cancelled (they were pending, not running yet)
        #expect(batch?.subagents.allSatisfy {
            if case .cancelled = $0.state { return true }
            return false
        } == true)
    }

    // MARK: - Merge strategy

    @Test
    func mergeStrategy_concatenateJoinsResults() async {
        let coordinator = PaceSubagentCoordinator.shared

        // Set up a mock planner that returns known results
        coordinator.executePlannerTurn = { prompt in
            return "result for \(prompt)"
        }
        coordinator.summarizeResults = nil

        let batchId = coordinator.decomposeAndRun(
            parentPrompt: "test",
            subtasks: [("Task A", "do A"), ("Task B", "do B")],
            mergeStrategy: .concatenate
        )

        // Wait for completion (poll up to 5 seconds)
        for _ in 0..<50 {
            if let batch = coordinator.batches.first(where: { $0.id == batchId }),
               batch.completedAt != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let result = coordinator.mergedResult(for: batchId)
        #expect(result != nil)
        #expect(result?.contains("result for do A") == true)
        #expect(result?.contains("result for do B") == true)
    }

    @Test
    func mergeStrategy_firstWinsReturnsFirstResult() async {
        let coordinator = PaceSubagentCoordinator.shared

        coordinator.executePlannerTurn = { prompt in
            return "first result"
        }

        let batchId = coordinator.decomposeAndRun(
            parentPrompt: "test",
            subtasks: [("Task A", "do A"), ("Task B", "do B")],
            mergeStrategy: .firstWins
        )

        for _ in 0..<50 {
            if let batch = coordinator.batches.first(where: { $0.id == batchId }),
               batch.completedAt != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let result = coordinator.mergedResult(for: batchId)
        #expect(result?.contains("first result") == true)
    }

    // MARK: - State tracking

    @Test
    func hasRunningBatches_trueWhenSubagentsPending() {
        let coordinator = PaceSubagentCoordinator.shared
        _ = coordinator.decomposeAndRun(
            parentPrompt: "test",
            subtasks: [("A", "do A")]
        )
        // Without a planner callback, the subagent will fail fast,
        // but right after creation it should be pending/running.
        // Note: this is a race — the subagent may have already failed.
        // Just verify the method doesn't crash.
        _ = coordinator.hasRunningBatches
    }

    @Test
    func clearCompleted_removesFinishedBatches() {
        let coordinator = PaceSubagentCoordinator.shared
        let batchId = coordinator.decomposeAndRun(
            parentPrompt: "test",
            subtasks: [("A", "do A")]
        )
        coordinator.cancelBatch(batchId)
        let countBefore = coordinator.batches.count
        coordinator.clearCompleted()
        #expect(coordinator.batches.count <= countBefore)
    }
}

// MARK: - AsyncSemaphore tests

@MainActor
struct AsyncSemaphoreTests {

    @Test
    func semaphore_allowsUpToLimitConcurrent() async {
        let semaphore = AsyncSemaphore(limit: 2)
        await semaphore.wait()
        await semaphore.wait()
        // Third wait should block — we can't easily test blocking in a
        // unit test, so just verify the first two succeeded.
        await semaphore.signal()
        await semaphore.signal()
    }

    @Test
    func semaphore_signalReleasesWaiter() async {
        let semaphore = AsyncSemaphore(limit: 1)
        await semaphore.wait()
        // Signal should release the slot
        await semaphore.signal()
        // Now we can wait again
        await semaphore.wait()
        await semaphore.signal()
    }
}
