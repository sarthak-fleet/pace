//
//  PaceBackgroundAgentRunner.swift
//  leanring-buddy
//
//  Background agent execution — runs multi-step tasks asynchronously
//  while the user continues working. Inspired by ChatGPT App's
//  background task queue and Shiro's parallel sub-agents.
//
//  Unlike the synchronous agent loop (which blocks the UI and TTS
//  pipeline), background agents:
//    - Run on a detached Task with background priority
//    - Report progress via a published state object
//    - Can be cancelled by the user
//    - Speak results only when done (or on failure)
//    - Respect the restraint gate for proactive speech
//
//  Use cases:
//    - "Build a Linear ticket for the bug I just described"
//    - "Draft a Gmail response to the last email"
//    - "Research the top 5 competitors for X"
//
//  Sprint 2.2 enhancements:
//    - Increased concurrency from 2 → 4 (matches subagent coordinator)
//    - Progress tracking: currentStep description + step count
//    - Priority queue: high-priority tasks jump the queue
//    - Elapsed time tracking for UI display
//

import Combine
import Foundation

/// State of a background agent task.
enum PaceBackgroundAgentState: Equatable {
    case queued
    case running
    case completed
    case cancelled
    case failed(String)
}

/// Priority of a background agent task. Higher priority tasks
/// jump ahead of lower priority ones in the queue.
enum PaceBackgroundAgentPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: PaceBackgroundAgentPriority, rhs: PaceBackgroundAgentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A background agent task. Created by voice command or cron trigger.
struct PaceBackgroundAgentTask: Identifiable, Equatable {
    let id: String
    let displayName: String
    let prompt: String
    let priority: PaceBackgroundAgentPriority
    var state: PaceBackgroundAgentState
    var startedAt: Date?
    var completedAt: Date?
    var resultSummary: String?
    var stepCount: Int
    /// Human-readable description of the current step, for UI display.
    /// e.g. "Searching Linear...", "Drafting ticket...", "Done".
    var currentStepDescription: String?

    static func == (lhs: PaceBackgroundAgentTask, rhs: PaceBackgroundAgentTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages background agent tasks. Each task runs as a detached Task
/// that calls the planner with the task prompt and executes the
/// resulting tool calls. Progress is published for UI updates.
@MainActor
final class PaceBackgroundAgentRunner: ObservableObject {
    static let shared = PaceBackgroundAgentRunner()

    @Published private(set) var tasks: [PaceBackgroundAgentTask] = []

    /// Callback to execute a planner turn. Set by CompanionManager.
    var executePlannerTurn: ((String) async -> String)?

    /// Callback to speak a result. Set by CompanionManager.
    var speakResult: ((String) async -> Void)?

    /// Maximum concurrent background tasks. Set to 4 to match the
    /// subagent coordinator — M-series chips can handle 4 parallel
    /// planner turns without contention when using Apple FM.
    private let maxConcurrent = 4

    private var runningTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Task lifecycle

    /// Enqueue a background task. Starts immediately if under the
    /// concurrency limit. Higher-priority tasks jump the queue.
    func enqueue(
        prompt: String,
        displayName: String,
        priority: PaceBackgroundAgentPriority = .normal
    ) -> String {
        let id = "bg-\(UUID().uuidString.prefix(8))"
        let task = PaceBackgroundAgentTask(
            id: id,
            displayName: displayName,
            prompt: prompt,
            priority: priority,
            state: .queued,
            startedAt: nil,
            completedAt: nil,
            resultSummary: nil,
            stepCount: 0,
            currentStepDescription: nil
        )
        tasks.append(task)

        if runningTasks.count < maxConcurrent {
            startNextQueuedTask()
        }

        return id
    }

    /// Cancel a running or queued task.
    func cancel(taskId: String) {
        runningTasks[taskId]?.cancel()
        runningTasks.removeValue(forKey: taskId)
        updateTask(taskId) { task in
            task.state = .cancelled
            task.completedAt = Date()
        }
        // Start next queued task if a slot freed up.
        startNextQueuedTask()
    }

    /// Remove completed/cancelled/failed tasks from the list.
    func clearCompleted() {
        tasks.removeAll { task in
            switch task.state {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    /// Update progress for a running task. Called by the executing
    /// code to report step-level progress for UI display.
    func updateProgress(taskId: String, stepDescription: String, stepCount: Int? = nil) {
        updateTask(taskId) { task in
            task.currentStepDescription = stepDescription
            if let stepCount {
                task.stepCount = stepCount
            }
        }
    }

    // MARK: - Execution

    /// Start the highest-priority queued task, if any.
    private func startNextQueuedTask() {
        guard runningTasks.count < maxConcurrent else { return }
        // Sort queued tasks by priority (highest first), then by
        // insertion order (oldest first).
        let queuedTasks = tasks
            .filter { $0.state == .queued }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                // Preserve insertion order for same-priority tasks.
                return false
            }
        guard let nextTask = queuedTasks.first else { return }
        startTask(nextTask.id)
    }

    private func startTask(_ taskId: String) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[taskIndex].state = .running
        tasks[taskIndex].startedAt = Date()
        tasks[taskIndex].currentStepDescription = "Starting..."

        let prompt = tasks[taskIndex].prompt

        runningTasks[taskId] = Task.detached(priority: .background) { [weak self] in
            await self?.executeTask(taskId: taskId, prompt: prompt)
        }
    }

    private func executeTask(taskId: String, prompt: String) async {
        do {
            guard let executePlannerTurn else {
                await MainActor.run {
                    self.updateTask(taskId) { task in
                        task.state = .failed("No planner callback set")
                        task.completedAt = Date()
                    }
                }
                return
            }

            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.currentStepDescription = "Thinking..."
                    task.stepCount = 1
                }
            }

            let result = await executePlannerTurn(prompt)

            // Check for cancellation before speaking.
            try Task.checkCancellation()

            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .completed
                    task.completedAt = Date()
                    task.resultSummary = result
                    task.currentStepDescription = "Done"
                }
            }

            // Speak the result through the restraint gate.
            if let speakResult, !result.isEmpty {
                await speakResult(result)
            }
        } catch is CancellationError {
            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .cancelled
                    task.completedAt = Date()
                }
            }
        } catch {
            await MainActor.run {
                self.updateTask(taskId) { task in
                    task.state = .failed(error.localizedDescription)
                    task.completedAt = Date()
                }
            }
        }

        await MainActor.run {
            self.runningTasks.removeValue(forKey: taskId)
            // Start next queued task if any.
            self.startNextQueuedTask()
        }
    }

    private func updateTask(_ taskId: String, _ update: (inout PaceBackgroundAgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        update(&tasks[index])
    }

    /// Whether any background tasks are currently running.
    var hasRunningTasks: Bool {
        tasks.contains(where: { $0.state == .running })
    }

    /// Number of tasks in each state, for UI summary.
    var queueSummary: (running: Int, queued: Int, completed: Int) {
        var running = 0, queued = 0, completed = 0
        for task in tasks {
            switch task.state {
            case .running: running += 1
            case .queued: queued += 1
            case .completed, .cancelled, .failed: completed += 1
            }
        }
        return (running, queued, completed)
    }
}
