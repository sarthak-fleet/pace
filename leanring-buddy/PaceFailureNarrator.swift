//
//  PaceFailureNarrator.swift
//  leanring-buddy
//
//  Pure deterministic composer for plain-language failure messages
//  Pace speaks when one of the documented failure modes fires. Mirrors
//  the shape of `PaceMorningBriefBuilder` — strictly templated, no LLM
//  call, no I/O, fully unit-testable.
//
//  The CompanionManager calls into this module at four wired sites
//  (planner offline, preflight block, click all-fail, sidecar TTS
//  fallback) plus two more catch-all kinds (MCP server missing, cloud
//  bridge upstream error). The composer returns a spoken string plus
//  an optional UI hint (Settings deep-link target) so the panel can
//  surface a follow-up affordance.
//
//  See PRD `docs/prds/trust-and-failures.md` for the full kinds list.
//

import Foundation

/// Kind of permission the user is missing for a requested action. Maps
/// onto the same buckets `PaceToolPreflight` already reports as
/// blocking issues so the manager can pass through preflight results
/// without inventing new categories.
nonisolated enum PaceMissingPermissionKind: Equatable {
    case accessibility
    case calendar
    case reminders
    case automation

    /// Spoken-friendly noun used in the templated failure copy.
    /// Lower-case so it reads naturally inside a sentence.
    var spokenNoun: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .automation: return "Automation"
        }
    }
}

/// Optional follow-up affordance Pace can surface alongside the
/// spoken message. Kept as a typed enum so the panel can render its
/// own button copy and deep-link target without parsing strings.
nonisolated enum PaceFailureSuggestion: Equatable {
    case openSettings
    case openSpecificPermission(PaceMissingPermissionKind)
    case runTTSSidecarScript
    case configureMCPServer(name: String)
    case openLocalAIBridgeFolder
}

/// Full set of failure kinds Pace can speak deterministically. Only
/// these kinds are allowed — expanding the list is a deliberate
/// product decision, not a one-off addition. See PRD risks: "failure
/// narrator becomes noisy."
nonisolated enum PaceFailureKind: Equatable {
    /// The configured planner is unreachable — LM Studio not running
    /// for `.local`, Apple FM unavailable for `.appleFoundationModels`,
    /// or Direct API / cloud bridge endpoint refused the request.
    case plannerOffline

    /// An auto-execute action needed a permission Pace doesn't have.
    /// The popup approval path already shows the preflight issue; this
    /// path covers the silent-failure case where actions were going to
    /// run without approval.
    case missingPermission(permission: PaceMissingPermissionKind)

    /// The click candidate set exhausted without producing an
    /// observable state change. The target label (if known) is echoed
    /// back so the user can confirm what Pace was aiming at.
    case clickMissed(targetLabel: String?)

    /// The Kokoro TTS sidecar is unreachable and Pace has fallen back
    /// to the system voice for this turn. Fires at most once per
    /// outage so we don't nag the user every sentence.
    case sidecarTTSOffline

    /// A `<tool_calls>` MCP call named a server that isn't configured
    /// in `~/.config/pace/mcp-servers.json`.
    case mcpServerNotConfigured(name: String)

    /// The cloud-bridge upstream (Claude Code, Codex, Gemini CLI)
    /// returned an error. The provider name is echoed back so the user
    /// knows which auth/CLI to inspect.
    case cloudBridgeUpstreamError(provider: String)

    /// Stable, privacy-safe identifier for the failure class. Used by
    /// `PaceTelemetryLog.recordFailure` so the log line carries a
    /// fixed enum-case name (e.g. `"plannerOffline"`,
    /// `"missingPermission.accessibility"`) instead of any associated
    /// value that could leak user content (e.g. a click target label
    /// or a provider error body). The switch is exhaustive so adding
    /// a new case is a compile error until this is extended — that
    /// prevents a future case from silently losing failure-class
    /// visibility.
    var stableLogIdentifier: String {
        switch self {
        case .plannerOffline:
            return "plannerOffline"
        case .missingPermission(let permission):
            return "missingPermission.\(permission.spokenNoun)"
        case .clickMissed:
            // Intentionally does NOT include the target label — the
            // label is user-content-adjacent (it can echo a button the
            // user named) and the failure matrix records only the
            // aggregate class.
            return "clickMissed"
        case .sidecarTTSOffline:
            return "sidecarTTSOffline"
        case .mcpServerNotConfigured:
            // Intentionally does NOT include the server name — a
            // user-configured server name could leak private context.
            return "mcpServerNotConfigured"
        case .cloudBridgeUpstreamError:
            // Intentionally does NOT include the provider name — the
            // provider could be a user-configured CLI label.
            return "cloudBridgeUpstreamError"
        }
    }
}

/// The composed result the manager hands to the TTS layer plus the
/// optional panel suggestion. Equatable so tests can pin both fields.
nonisolated struct PaceFailureNarration: Equatable {
    /// Templated, spoken-ready string. Always non-empty.
    let spokenText: String
    /// Optional UI follow-up. `nil` when no actionable suggestion fits.
    let suggestion: PaceFailureSuggestion?
}

nonisolated enum PaceFailureNarrator {
    /// Composes a deterministic failure narration. Pure — no I/O, no
    /// model call, no global state.
    static func compose(_ kind: PaceFailureKind) -> PaceFailureNarration {
        switch kind {
        case .plannerOffline:
            return PaceFailureNarration(
                spokenText: "I can't reach the local planner right now — open Settings and switch to a different tier?",
                suggestion: .openSettings
            )

        case .missingPermission(let permission):
            return PaceFailureNarration(
                spokenText: "I'd need \(permission.spokenNoun) access for that — want me to open Settings?",
                suggestion: .openSpecificPermission(permission)
            )

        case .clickMissed(let targetLabel):
            let trimmedLabel = targetLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let trimmedLabel, !trimmedLabel.isEmpty {
                return PaceFailureNarration(
                    spokenText: "I couldn't find a \(trimmedLabel) on this screen — want to point it out?",
                    suggestion: nil
                )
            }
            return PaceFailureNarration(
                spokenText: "I couldn't find that on this screen — want to point it out?",
                suggestion: nil
            )

        case .sidecarTTSOffline:
            return PaceFailureNarration(
                spokenText: "Switched to the system voice — the Kokoro sidecar isn't reachable. Run scripts/start-tts-server.sh to get it back.",
                suggestion: .runTTSSidecarScript
            )

        case .mcpServerNotConfigured(let serverName):
            let trimmedServerName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedServerName = trimmedServerName.isEmpty ? "that" : trimmedServerName
            return PaceFailureNarration(
                spokenText: "I'd use the \(renderedServerName) MCP server for that, but it isn't configured — want to add it?",
                suggestion: .configureMCPServer(name: renderedServerName)
            )

        case .cloudBridgeUpstreamError(let provider):
            let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            let renderedProvider = trimmedProvider.isEmpty ? "the cloud bridge" : trimmedProvider
            return PaceFailureNarration(
                spokenText: "The \(renderedProvider) bridge returned an error — check that the CLI is signed in.",
                suggestion: .openLocalAIBridgeFolder
            )
        }
    }
}
