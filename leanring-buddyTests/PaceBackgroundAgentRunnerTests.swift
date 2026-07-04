//
//  PaceBackgroundAgentRunnerTests.swift
//  leanring-buddyTests
//
//  Tests for the background agent runner. Verifies task lifecycle,
//  concurrency limits, cancellation, and callback wiring.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceBackgroundAgentRunnerTests {

    // MARK: - Task lifecycle

    /// Enqueuing a task adds it to the task list.
    @Test
    func enqueueAddsTaskToList() {
        let runner = PaceBackgroundAgentRunner.shared
        let initialCount = runner.tasks.count

        let id = runner.enqueue(prompt: "test prompt", displayName: "Test Task")

        #expect(runner.tasks.count == initialCount + 1)
        #expect(runner.tasks.contains(where: { $0.id == id }))

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// A task that completes successfully reports .completed state.
    @Test
    func taskCompletesSuccessfully() async {
        let runner = PaceBackgroundAgentRunner.shared

        runner.executePlannerTurn = { prompt in
            return "Done: \(prompt)"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "do something", displayName: "Success Task")

        // Wait for the background task to complete. Background priority
        // tasks may take a while to schedule.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let task = runner.tasks.first(where: { $0.id == id }),
               task.state == .completed || task.state == .failed("") {
                break
            }
        }

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task != nil)
        #expect(task?.state == .completed)
        #expect(task?.resultSummary?.contains("Done: do something") == true)

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// Cancelling a running task sets state to .cancelled.
    @Test
    func cancelRunningTaskSetsCancelledState() async {
        let runner = PaceBackgroundAgentRunner.shared

        // Make the planner turn take a while so we can cancel it.
        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(10))
            return "should not reach"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "long task", displayName: "Long Task")

        // Give it a moment to start.
        try? await Task.sleep(for: .milliseconds(500))

        runner.cancel(taskId: id)

        try? await Task.sleep(for: .milliseconds(200))

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task?.state == .cancelled)
    }

    /// A task with no planner callback fails gracefully.
    @Test
    func taskWithoutCallbackFailsGracefully() async {
        let runner = PaceBackgroundAgentRunner.shared
        runner.executePlannerTurn = nil

        let id = runner.enqueue(prompt: "no callback", displayName: "No Callback")

        // Wait for the background task to process.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let task = runner.tasks.first(where: { $0.id == id }),
               case .failed = task.state {
                break
            }
        }

        let task = runner.tasks.first(where: { $0.id == id })
        if case .failed(let message) = task?.state {
            #expect(message.contains("No planner callback"))
        } else {
            #expect(Bool(false), "Task should be in failed state")
        }

        // Cleanup.
        runner.cancel(taskId: id)
    }

    // MARK: - State tracking

    /// hasRunningTasks is true when a task is running.
    @Test
    func hasRunningTasksReflectsState() async {
        let runner = PaceBackgroundAgentRunner.shared

        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(2))
            return "done"
        }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "running test", displayName: "Running Test")

        // Wait for the task to start running.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(runner.hasRunningTasks == true)

        // Wait for completion.
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(300))
            if !runner.hasRunningTasks { break }
        }
        #expect(runner.hasRunningTasks == false)

        // Cleanup.
        runner.cancel(taskId: id)
    }

    /// clearCompleted removes completed/cancelled/failed tasks.
    @Test
    func clearCompletedRemovesFinishedTasks() async {
        let runner = PaceBackgroundAgentRunner.shared

        runner.executePlannerTurn = { _ in "done" }
        defer { runner.executePlannerTurn = nil }

        let id = runner.enqueue(prompt: "clear test", displayName: "Clear Test")

        // Poll until THIS task reaches a finished state — a fixed sleep
        // flakes under CI load (the detached execution task may not have
        // completed yet), and asserting on the task's own id keeps the
        // test immune to other tests' tasks in the shared runner.
        for _ in 0..<100 {
            let enqueuedTask = runner.tasks.first(where: { $0.id == id })
            if enqueuedTask?.state == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let enqueuedTaskState = runner.tasks.first(where: { $0.id == id })?.state
        #expect(enqueuedTaskState == .completed)

        runner.clearCompleted()
        #expect(runner.tasks.contains(where: { $0.id == id }) == false)
    }

    // MARK: - Priority queue (Sprint 2.2)

    /// High-priority tasks should be started before low-priority ones
    /// when both are queued.
    @Test
    func highPriorityTaskStartsFirst() async {
        let runner = PaceBackgroundAgentRunner.shared

        // Block all slots with slow tasks so we can queue more.
        runner.executePlannerTurn = { _ in
            try? await Task.sleep(for: .seconds(5))
            return "done"
        }
        defer { runner.executePlannerTurn = nil }

        // Fill all 4 concurrent slots with normal-priority tasks.
        var blockerIds: [String] = []
        for i in 0..<4 {
            blockerIds.append(runner.enqueue(prompt: "blocker \(i)", displayName: "Blocker \(i)"))
        }

        try? await Task.sleep(for: .milliseconds(500))

        // Now queue a low-priority and a high-priority task.
        let lowId = runner.enqueue(prompt: "low priority", displayName: "Low", priority: .low)
        let highId = runner.enqueue(prompt: "high priority", displayName: "High", priority: .high)

        // Both should be queued (all slots are full).
        #expect(runner.tasks.first(where: { $0.id == lowId })?.state == .queued)
        #expect(runner.tasks.first(where: { $0.id == highId })?.state == .queued)

        // Cancel one blocker to free a slot.
        runner.cancel(taskId: blockerIds[0])
        try? await Task.sleep(for: .milliseconds(500))

        // The high-priority task should have started, not the low one.
        let highTask = runner.tasks.first(where: { $0.id == highId })
        let lowTask = runner.tasks.first(where: { $0.id == lowId })
        #expect(highTask?.state == .running || highTask?.state == .completed || highTask?.state == .failed(""))
        #expect(lowTask?.state == .queued)

        // Cleanup.
        for id in blockerIds { runner.cancel(taskId: id) }
        runner.cancel(taskId: lowId)
        runner.cancel(taskId: highId)
    }

    // MARK: - Progress tracking (Sprint 2.2)

    /// updateProgress should update the step description and count.
    @Test
    func updateProgressSetsStepDescription() {
        let runner = PaceBackgroundAgentRunner.shared
        let id = runner.enqueue(prompt: "progress test", displayName: "Progress Test")

        runner.updateProgress(taskId: id, stepDescription: "Searching...", stepCount: 2)

        let task = runner.tasks.first(where: { $0.id == id })
        #expect(task?.currentStepDescription == "Searching...")
        #expect(task?.stepCount == 2)

        runner.cancel(taskId: id)
    }

    // MARK: - Queue summary (Sprint 2.2)

    /// queueSummary should report correct counts.
    @Test
    func queueSummaryReportsCorrectCounts() {
        let runner = PaceBackgroundAgentRunner.shared
        let id1 = runner.enqueue(prompt: "summary 1", displayName: "Summary 1")
        let id2 = runner.enqueue(prompt: "summary 2", displayName: "Summary 2")

        let summary = runner.queueSummary
        // At least 2 tasks should be running or queued.
        #expect(summary.running + summary.queued >= 2)

        runner.cancel(taskId: id1)
        runner.cancel(taskId: id2)
    }
}
