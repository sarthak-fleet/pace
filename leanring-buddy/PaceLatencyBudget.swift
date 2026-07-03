//
//  PaceLatencyBudget.swift
//  leanring-buddy
//
//  Per-turn latency budget tracker. Captures every pipeline stage from
//  PTT press to TTS complete, emits a single structured log line, and
//  keeps an in-memory rolling window for the settings panel / benchmark
//  script to read.
//
//  Design goals:
//  1. One struct per turn — start it at PTT press, call .stage(.x) at
//     each boundary, call .finish() at TTS complete.
//  2. Single structured log line so `log stream --subsystem com.pace.app`
//     can grep "BUDGET=" and parse the full breakdown.
//  3. Rolling p50/p90 window for the HUD ("last turn: 480ms").
//  4. Timestamps are plain `Date` values in a per-stage dictionary —
//     one small dictionary write per stage boundary, nothing on the
//     audio/TTS hot path itself.
//

import Foundation
import OSLog

// MARK: - Per-turn budget

/// Mutable per-turn latency budget. Create at PTT press, mark stages
/// as the pipeline progresses, call `finish()` when the turn is done.
@MainActor
final class PaceLatencyBudget {
    static let shared = PaceLatencyBudget()

    /// The active turn's budget, or nil if no turn is in flight.
    private(set) var currentTurn: TurnBudget?

    /// Rolling window of completed turns (max 50).
    private(set) var recentTurns: [TurnBudget] = []
    private let maxRecentTurns = 50

    private init() {}

    // MARK: - Turn lifecycle

    /// Start a new turn. Called at PTT press.
    func startTurn(trigger: TurnBudget.TurnTrigger) -> TurnBudget {
        let turn = TurnBudget(trigger: trigger)
        currentTurn = turn
        return turn
    }

    /// Mark a stage boundary on the current turn.
    func mark(_ stage: TurnBudget.Stage) {
        currentTurn?.mark(stage)
    }

    /// Finish the current turn and emit the structured log line.
    @discardableResult
    func finishTurn() -> TurnBudget? {
        guard let turn = currentTurn else { return nil }
        turn.finish()
        recentTurns.append(turn)
        if recentTurns.count > maxRecentTurns {
            recentTurns.removeFirst()
        }
        turn.emitLog()
        currentTurn = nil
        return turn
    }

    /// Cancel the current turn without emitting (e.g. user cancelled).
    func cancelTurn() {
        currentTurn = nil
    }

    // MARK: - Aggregate stats

    struct Stats {
        let p50: Int
        let p90: Int
        let count: Int
        let fastest: Int
        let slowest: Int
    }

    /// E2E stats from the rolling window.
    var e2eStats: Stats {
        stats(for: \.e2eMs)
    }

    /// TTFSW stats from the rolling window.
    var ttfsWStats: Stats {
        stats(for: \.ttfsWMs)
    }

    private func stats(for keyPath: KeyPath<TurnBudget, Int?>) -> Stats {
        let values = recentTurns.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else {
            return Stats(p50: 0, p90: 0, count: 0, fastest: 0, slowest: 0)
        }
        let sorted = values.sorted()
        let p50 = sorted[sorted.count / 2]
        let p90 = sorted[min(Int(Double(sorted.count) * 0.9), sorted.count - 1)]
        return Stats(
            p50: p50,
            p90: p90,
            count: sorted.count,
            fastest: sorted.first!,
            slowest: sorted.last!
        )
    }
}

// MARK: - Turn budget

/// Reference-type per-turn latency budget. Create at PTT press, mark
/// stages as the pipeline progresses, call `finish()` when the turn
/// is done. Reference type so the singleton can mutate it in place.
final class TurnBudget {
    enum TurnTrigger: String {
        case pushToTalk
        case deeplink
        case chatSubmit
        case bargeIn
        case backgroundAgent
    }

    enum Stage: String, CaseIterable {
        case pttPress
        case sttComplete
        case intentClassified
        case vlmStart
        case vlmComplete
        case plannerStart
        case plannerFirstToken
        case plannerComplete
        case toolExecStart
        case toolExecComplete
        case ttsFirstDispatch
        case ttsComplete
    }

    let trigger: TurnTrigger
    private(set) var timestamps: [Stage: Date] = [:]
    private(set) var isFinished: Bool = false

    init(trigger: TurnTrigger) {
        self.trigger = trigger
        timestamps[.pttPress] = Date()
    }

    func mark(_ stage: Stage) {
        guard !isFinished else { return }
        if timestamps[stage] == nil {
            timestamps[stage] = Date()
        }
    }

    func finish() {
        isFinished = true
        if timestamps[.ttsComplete] == nil {
            timestamps[.ttsComplete] = Date()
        }
    }

    // MARK: - Derived metrics

    private func elapsed(_ from: Stage, _ to: Stage) -> Int? {
        guard let s = timestamps[from], let e = timestamps[to] else { return nil }
        return Int(e.timeIntervalSince(s) * 1000)
    }

    /// PTT press → TTS complete (the user-perceived total).
    var e2eMs: Int? { elapsed(.pttPress, .ttsComplete) }

    /// PTT release (intent committed) → first TTS dispatch.
    /// Note: we use sttComplete as the "intent committed" proxy since
    /// that's when the final transcript is ready and the planner starts.
    var ttfsWMs: Int? { elapsed(.sttComplete, .ttsFirstDispatch) }

    /// PTT press → final transcript ready.
    var sttMs: Int? { elapsed(.pttPress, .sttComplete) }

    /// VLM screenshot → element map ready.
    var vlmMs: Int? { elapsed(.vlmStart, .vlmComplete) }

    /// Planner HTTP request → first content chunk.
    var plannerTTFTMs: Int? { elapsed(.plannerStart, .plannerFirstToken) }

    /// Planner HTTP request → last chunk.
    var plannerTotalMs: Int? { elapsed(.plannerStart, .plannerComplete) }

    /// Tool execution start → complete.
    var toolExecMs: Int? { elapsed(.toolExecStart, .toolExecComplete) }

    /// First TTS dispatch → TTS complete.
    var ttsMs: Int? { elapsed(.ttsFirstDispatch, .ttsComplete) }

    /// Intent classification duration.
    var intentMs: Int? { elapsed(.sttComplete, .intentClassified) }

    // MARK: - Structured log emission

    func emitLog() {
        let parts: [String] = [
            "trigger=\(trigger.rawValue)",
            "e2e=\(e2eMs.map { "\($0)ms" } ?? "nil")",
            "ttfsw=\(ttfsWMs.map { "\($0)ms" } ?? "nil")",
            "stt=\(sttMs.map { "\($0)ms" } ?? "nil")",
            "intent=\(intentMs.map { "\($0)ms" } ?? "nil")",
            "vlm=\(vlmMs.map { "\($0)ms" } ?? "nil")",
            "planner_ttft=\(plannerTTFTMs.map { "\($0)ms" } ?? "nil")",
            "planner_total=\(plannerTotalMs.map { "\($0)ms" } ?? "nil")",
            "tool_exec=\(toolExecMs.map { "\($0)ms" } ?? "nil")",
            "tts=\(ttsMs.map { "\($0)ms" } ?? "nil")",
        ]
        let line = "BUDGET=" + parts.joined(separator: " ")
        PaceTelemetryLog.logger.info("\(line, privacy: .public)")
        // Also print to console for dev visibility
        print("⚡ \(line)")
    }
}
