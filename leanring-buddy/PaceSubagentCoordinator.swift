//
//  PaceSubagentCoordinator.swift
//  leanring-buddy
//
//  Subagent coordinator — decomposes complex tasks into parallel
//  sub-tasks, each with its own planner turn, budget, and result
//  that gets merged back into a single response.
//
//  Inspired by Shiro's parallel sub-agents and Clicky's background
//  agents. Unlike PaceBackgroundAgentRunner (which runs sequential
//  multi-step tasks in the background), the subagent coordinator
//  spawns N parallel planner turns for independent sub-tasks and
//  merges their results.
//
//  Use cases:
//    - "Research X, Y, and Z" → 3 parallel research subagents
//    - "Draft emails to Alice, Bob, and Carol" → 3 parallel drafts
//    - "Compare options A, B, C" → 3 parallel evaluations
//
//  Key design decisions:
//    - Each subagent gets its own context window (no shared state)
//    - Each subagent has a token/step budget to prevent runaway
//    - Results merge via a deterministic strategy (concatenate,
//      summarize, or first-wins)
//    - The coordinator runs on MainActor but subagents run on
//      detached Tasks with userInitiated priority
//    - Cancellation propagates to all subagents
//

import Combine
import Foundation

/// State of a single subagent task.
enum PaceSubagentState: Equatable {
    case pending
    case running
    case completed(String)
    case failed(String)
    case cancelled
}

/// A single subagent task within a coordinated batch.
struct PaceSubagentTask: Identifiable, Equatable {
    let id: String
    let displayName: String
    let prompt: String
    var state: PaceSubagentState
    var startedAt: Date?
    var completedAt: Date?

    static func == (lhs: PaceSubagentTask, rhs: PaceSubagentTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Strategy for merging subagent results into a single response.
enum PaceSubagentMergeStrategy {
    /// Concatenate all results with headers.
    case concatenate
    /// Use Apple FM to summarize all results into one.
    case summarize
    /// First non-empty result wins (for racing subagents).
    case firstWins
}

/// A coordinated batch of subagents.
struct PaceSubagentBatch: Identifiable, Equatable {
    let id: String
    let parentPrompt: String
    var subagents: [PaceSubagentTask]
    var mergeStrategy: PaceSubagentMergeStrategy
    var startedAt: Date?
    var completedAt: Date?
    var mergedResult: String?

    static func == (lhs: PaceSubagentBatch, rhs: PaceSubagentBatch) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages subagent coordination — decomposing tasks, spawning
/// parallel planner turns, and merging results.
@MainActor
final class PaceSubagentCoordinator: ObservableObject {
    static let shared = PaceSubagentCoordinator()

    @Published private(set) var batches: [PaceSubagentBatch] = []

    /// Callback to execute a planner turn for a subagent.
    /// Set by CompanionManager. The subagent's prompt is passed in,
    /// and the full planner response is returned.
    var executePlannerTurn: ((String) async -> String)?

    /// Callback to summarize merged results via Apple FM.
    /// Set by CompanionManager.
    var summarizeResults: ((String) async -> String)?

    /// Maximum concurrent subagents per batch.
    private let maxConcurrent = 4

    /// Token budget per subagent (in planner response chars).
    /// Prevents a single subagent from monopolizing the context.
    private let subagentCharBudget = 4000

    private var runningBatches: [String: [Task<Void, Never>]] = [:]

    private init() {}

    // MARK: - Batch lifecycle

    /// Decompose a complex prompt into sub-tasks and run them in
    /// parallel. Returns the batch ID for tracking/cancellation.
    func decomposeAndRun(
        parentPrompt: String,
        subtasks: [(displayName: String, prompt: String)],
        mergeStrategy: PaceSubagentMergeStrategy = .concatenate
    ) -> String {
        let batchId = "batch-\(UUID().uuidString.prefix(8))"
        let subagents = subtasks.enumerated().map { index, subtask in
            PaceSubagentTask(
                id: "\(batchId)-sub-\(index)",
                displayName: subtask.displayName,
                prompt: subtask.prompt,
                state: .pending,
                startedAt: nil,
                completedAt: nil
            )
        }

        let batch = PaceSubagentBatch(
            id: batchId,
            parentPrompt: parentPrompt,
            subagents: subagents,
            mergeStrategy: mergeStrategy,
            startedAt: Date(),
            completedAt: nil,
            mergedResult: nil
        )
        batches.append(batch)

        runBatch(batchId)
        return batchId
    }

    /// Cancel all subagents in a batch.
    func cancelBatch(_ batchId: String) {
        runningBatches[batchId]?.forEach { $0.cancel() }
        runningBatches.removeValue(forKey: batchId)
        updateBatch(batchId) { batch in
            for index in batch.subagents.indices {
                if batch.subagents[index].state == .pending || batch.subagents[index].state == .running {
                    batch.subagents[index].state = .cancelled
                    batch.subagents[index].completedAt = Date()
                }
            }
            batch.completedAt = Date()
        }
    }

    /// Remove completed/cancelled batches from the list.
    func clearCompleted() {
        batches.removeAll { batch in
            batch.completedAt != nil
        }
    }

    // MARK: - Execution

    private func runBatch(_ batchId: String) {
        guard let batch = batches.first(where: { $0.id == batchId }) else { return }

        var tasks: [Task<Void, Never>] = []
        let semaphore = AsyncSemaphore(limit: maxConcurrent)

        for subagent in batch.subagents {
            let taskId = Task.detached(priority: .userInitiated) { [weak self] in
                await semaphore.wait()
                guard !Task.isCancelled else {
                    await semaphore.signal()
                    return
                }
                await self?.executeSubagent(batchId: batchId, subagentId: subagent.id, prompt: subagent.prompt)
                await semaphore.signal()
            }
            tasks.append(taskId)
        }

        runningBatches[batchId] = tasks
    }

    private func executeSubagent(batchId: String, subagentId: String, prompt: String) async {
        await MainActor.run {
            self.updateSubagent(batchId, subagentId) { sub in
                sub.state = .running
                sub.startedAt = Date()
            }
        }

        do {
            guard let executePlannerTurn else {
                await MainActor.run {
                    self.updateSubagent(batchId, subagentId) { sub in
                        sub.state = .failed("No planner callback set")
                        sub.completedAt = Date()
                    }
                }
                return
            }

            let result = await executePlannerTurn(prompt)
            try Task.checkCancellation()

            // Truncate to budget to prevent context blowup.
            let truncated = result.count > subagentCharBudget
                ? String(result.prefix(subagentCharBudget)) + "\n[...truncated]"
                : result

            await MainActor.run {
                self.updateSubagent(batchId, subagentId) { sub in
                    sub.state = .completed(truncated)
                    sub.completedAt = Date()
                }
                self.checkBatchCompletion(batchId)
            }
        } catch is CancellationError {
            await MainActor.run {
                self.updateSubagent(batchId, subagentId) { sub in
                    sub.state = .cancelled
                    sub.completedAt = Date()
                }
                self.checkBatchCompletion(batchId)
            }
        } catch {
            await MainActor.run {
                self.updateSubagent(batchId, subagentId) { sub in
                    sub.state = .failed(error.localizedDescription)
                    sub.completedAt = Date()
                }
                self.checkBatchCompletion(batchId)
            }
        }
    }

    /// Check if all subagents in a batch are done, and if so,
    /// merge results.
    private func checkBatchCompletion(_ batchId: String) {
        guard let batch = batches.first(where: { $0.id == batchId }) else { return }
        let allDone = batch.subagents.allSatisfy { sub in
            switch sub.state {
            case .pending, .running: return false
            default: return true
            }
        }
        guard allDone else { return }

        Task {
            await mergeBatchResults(batchId)
        }
    }

    /// Merge subagent results according to the batch's merge strategy.
    private func mergeBatchResults(_ batchId: String) async {
        guard let batch = batches.first(where: { $0.id == batchId }) else { return }

        let completedResults = batch.subagents.compactMap { sub -> String? in
            if case .completed(let result) = sub.state {
                return "## \(sub.displayName)\n\n\(result)"
            }
            return nil
        }

        let merged: String
        switch batch.mergeStrategy {
        case .concatenate:
            merged = completedResults.joined(separator: "\n\n---\n\n")

        case .summarize:
            let concatenated = completedResults.joined(separator: "\n\n---\n\n")
            if let summarizeResults {
                merged = await summarizeResults(concatenated)
            } else {
                merged = concatenated
            }

        case .firstWins:
            merged = completedResults.first ?? ""
        }

        updateBatch(batchId) { batch in
            batch.mergedResult = merged
            batch.completedAt = Date()
        }

        runningBatches.removeValue(forKey: batchId)
    }

    // MARK: - Helpers

    private func updateBatch(_ batchId: String, _ update: (inout PaceSubagentBatch) -> Void) {
        guard let index = batches.firstIndex(where: { $0.id == batchId }) else { return }
        update(&batches[index])
    }

    private func updateSubagent(_ batchId: String, _ subagentId: String, _ update: (inout PaceSubagentTask) -> Void) {
        guard let batchIndex = batches.firstIndex(where: { $0.id == batchId }) else { return }
        guard let subIndex = batches[batchIndex].subagents.firstIndex(where: { $0.id == subagentId }) else { return }
        update(&batches[batchIndex].subagents[subIndex])
    }

    /// Whether any batches are currently running.
    var hasRunningBatches: Bool {
        batches.contains { batch in
            batch.subagents.contains { sub in
                sub.state == .running || sub.state == .pending
            }
        }
    }

    /// Get the merged result for a completed batch.
    func mergedResult(for batchId: String) -> String? {
        batches.first(where: { $0.id == batchId })?.mergedResult
    }
}

// MARK: - AsyncSemaphore

/// A simple async counting semaphore for limiting concurrency.
/// Used by the subagent coordinator to cap parallel planner turns.
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else if available < limit {
            available += 1
        }
    }
}
