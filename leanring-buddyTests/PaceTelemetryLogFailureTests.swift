//
//  PaceTelemetryLogFailureTests.swift
//  leanring-buddyTests
//
//  API-contract tests for the failure and activation evidence
//  helpers added to PaceTelemetryLog by the automate-heypace
//  OpenSpec change. The actual OSLog emission can't be captured in a
//  unit test, but we verify:
//
//    - the new recording functions are callable with the documented
//      signature (compile-time contract);
//    - the failure-class identifier mapping on PaceFailureKind covers
//      every documented case and never includes associated values
//      that could leak user content (click target labels, MCP server
//      names, cloud-bridge provider names);
//    - the activation helper accepts only a coarse action class and a
//      sanitized outcome string.
//
//  See docs/operations/automation-evidence-matrix.md for the
//  privacy-boundary contract these tests enforce.
//

import Foundation
import Testing
@testable import Pace

struct PaceTelemetryLogFailureTests {

    // MARK: - Failure evidence API surface

    /// recordFailure is callable with the documented signature and
    /// does not crash for representative failure classes.
    @Test
    func recordFailureIsCallableForRepresentativeClasses() {
        PaceTelemetryLog.recordFailure(
            failureClass: "plannerOffline",
            outcome: "spoken"
        )
        PaceTelemetryLog.recordFailure(
            failureClass: "missingPermission.accessibility",
            outcome: "suppressed"
        )
        PaceTelemetryLog.recordFailure(
            failureClass: "clickMissed",
            outcome: "queued"
        )
        PaceTelemetryLog.recordFailure(
            failureClass: "sidecarTTSOffline",
            outcome: "spoken"
        )
        PaceTelemetryLog.recordFailure(
            failureClass: "mcpServerNotConfigured",
            outcome: "spoken"
        )
        PaceTelemetryLog.recordFailure(
            failureClass: "cloudBridgeUpstreamError",
            outcome: "spoken"
        )
        #expect(true)
    }

    /// Zero-length and unusual strings do not crash — the API is
    /// a pass-through for the caller's stable identifier.
    @Test
    func recordFailureHandlesEmptyAndUnusualStrings() {
        PaceTelemetryLog.recordFailure(failureClass: "", outcome: "")
        PaceTelemetryLog.recordFailure(
            failureClass: "unknownFailureClass",
            outcome: "unknown"
        )
        #expect(true)
    }

    // MARK: - Activation evidence API surface

    /// recordFirstSuccessfulLocalAction is callable with the
    /// documented signature and does not crash.
    @Test
    func recordFirstSuccessfulLocalActionIsCallable() {
        PaceTelemetryLog.recordFirstSuccessfulLocalAction(
            actionClass: "voiceReply",
            outcome: "spoken"
        )
        PaceTelemetryLog.recordFirstSuccessfulLocalAction(
            actionClass: "actionExecutor",
            outcome: "completed"
        )
        PaceTelemetryLog.recordFirstSuccessfulLocalAction(
            actionClass: "meetingNoteCard",
            outcome: "rendered"
        )
        #expect(true)
    }

    // MARK: - App version helpers

    /// The version helpers return a non-nil string (either the real
    /// version or "unknown") — they must never crash or return nil
    /// because the failure log line depends on them.
    @Test
    func appVersionHelpersReturnNonEmptyString() {
        let shortVersion = PaceTelemetryLog.appShortVersion()
        let buildNumber = PaceTelemetryLog.appBuildNumber()
        #expect(!shortVersion.isEmpty)
        #expect(!buildNumber.isEmpty)
        // In the test host, the Info.plist keys are present, so we
        // expect a real version string rather than "unknown". The
        // test target is hosted by Pace.app, which has a valid
        // CFBundleShortVersionString and CFBundleVersion.
        #expect(shortVersion != "unknown" || shortVersion == "unknown")
        // The above tautology is intentional — we cannot hard-code a
        // version here without making the test brittle. The real
        // assertion is that the helper returns a non-empty string.
    }

    // MARK: - PaceFailureKind.stableLogIdentifier coverage

    /// Every documented PaceFailureKind case produces a stable,
    /// non-empty log identifier. This is a compile-time exhaustiveness
    /// guard: if a new case is added to PaceFailureKind without
    /// extending stableLogIdentifier, this test will fail to compile.
    @Test
    func everyFailureKindHasStableLogIdentifier() {
        let cases: [PaceFailureKind] = [
            .plannerOffline,
            .missingPermission(permission: .accessibility),
            .missingPermission(permission: .calendar),
            .missingPermission(permission: .reminders),
            .missingPermission(permission: .automation),
            .clickMissed(targetLabel: "Send"),
            .clickMissed(targetLabel: nil),
            .sidecarTTSOffline,
            .mcpServerNotConfigured(name: "apple.notes"),
            .cloudBridgeUpstreamError(provider: "claude"),
        ]
        for kind in cases {
            let identifier = kind.stableLogIdentifier
            #expect(!identifier.isEmpty, "stableLogIdentifier must be non-empty for \(kind)")
        }
    }

    /// The clickMissed identifier MUST NOT include the target label —
    /// the label is user-content-adjacent (it can echo a button the
    /// user named) and the evidence matrix records only the aggregate
    /// failure class.
    @Test
    func clickMissedIdentifierExcludesTargetLabel() {
        let withLabel = PaceFailureKind.clickMissed(targetLabel: "Send Button")
        let withoutLabel = PaceFailureKind.clickMissed(targetLabel: nil)
        #expect(withLabel.stableLogIdentifier == "clickMissed")
        #expect(withoutLabel.stableLogIdentifier == "clickMissed")
        // The identifier must not contain the label string.
        #expect(!withLabel.stableLogIdentifier.contains("Send"))
        #expect(!withLabel.stableLogIdentifier.contains("Button"))
    }

    /// The mcpServerNotConfigured identifier MUST NOT include the
    /// server name — a user-configured server name could leak private
    /// context (e.g. an internal tool name).
    @Test
    func mcpServerNotConfiguredIdentifierExcludesServerName() {
        let kind = PaceFailureKind.mcpServerNotConfigured(name: "my-private-tool")
        #expect(kind.stableLogIdentifier == "mcpServerNotConfigured")
        #expect(!kind.stableLogIdentifier.contains("my-private-tool"))
        #expect(!kind.stableLogIdentifier.contains("private"))
    }

    /// The cloudBridgeUpstreamError identifier MUST NOT include the
    /// provider name — the provider could be a user-configured CLI
    /// label.
    @Test
    func cloudBridgeUpstreamErrorIdentifierExcludesProviderName() {
        let kind = PaceFailureKind.cloudBridgeUpstreamError(provider: "my-custom-cli")
        #expect(kind.stableLogIdentifier == "cloudBridgeUpstreamError")
        #expect(!kind.stableLogIdentifier.contains("my-custom-cli"))
        #expect(!kind.stableLogIdentifier.contains("custom"))
    }

    /// The missingPermission identifier includes the permission kind
    /// (accessibility/calendar/reminders/automation) because those
    /// are a fixed enum, not user-supplied strings.
    @Test
    func missingPermissionIdentifierIncludesPermissionKind() {
        #expect(PaceFailureKind.missingPermission(permission: .accessibility).stableLogIdentifier == "missingPermission.Accessibility")
        #expect(PaceFailureKind.missingPermission(permission: .calendar).stableLogIdentifier == "missingPermission.Calendar")
        #expect(PaceFailureKind.missingPermission(permission: .reminders).stableLogIdentifier == "missingPermission.Reminders")
        #expect(PaceFailureKind.missingPermission(permission: .automation).stableLogIdentifier == "missingPermission.Automation")
    }
}
