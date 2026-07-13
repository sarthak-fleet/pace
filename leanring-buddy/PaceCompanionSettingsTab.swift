//
//  PaceCompanionSettingsTab.swift
//  leanring-buddy
//
//  Explicit opt-in, source transparency, retention, readiness, and clear
//  controls for Always-On Companion Mode.
//

import SwiftUI

struct PaceCompanionSettingsTab: View {
    @ObservedObject var controlCenter: PaceCompanionControlCenter
    @State private var taughtObjectLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard

            paceSettingsToggleRow(
                title: "Always-On Companion Mode",
                subtitle: "Default off. Observe locally and remember structured changes only from sources you enable.",
                isOn: Binding(
                    get: { controlCenter.preferences.isCompanionModeEnabled },
                    set: { controlCenter.setModeEnabled($0) }
                )
            )

            if controlCenter.preferences.isCompanionModeEnabled {
                HStack {
                    paceSettingsButton("Pause now", systemName: "pause.fill") {
                        controlCenter.pause()
                    }
                    Spacer()
                }
            }

            sourceSection
            observeOnlyActionsSection
            outputSection
            storageSection
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(controlCenter.runtimeStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(controlCenter.isLocalModelReady ? "Local model ready" : "Local model unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(controlCenter.isLocalModelReady ? .green : DS.Colors.textTertiary)
            }
            Text(activeSourceSummary)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
            if let lastObservationAt = controlCenter.lastObservationAt {
                Text("Last structured observation: \(lastObservationAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Sources")
            sourceToggle(.camera, title: "Camera", subtitle: "Low-rate motion/object gating in named zones. Separate camera permission required.")
            sourceToggle(.ambientVoice, title: "Ambient voice", subtitle: "Local VAD/wake gate; no transcription before wake and no raw-audio persistence.")
            sourceToggle(.screen, title: "Screen Watch events", subtitle: "Uses the existing explicit Watch Mode loop; no duplicate screen polling.")
            sourceToggle(.macOSContext, title: "Mac context", subtitle: "Frontmost app, window metadata, displays, and time — no screen pixels.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Teach an object")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Hold one object centered in view, name it, then capture. Pace stores a local Vision feature print—not a photo—and only reports conservative matches.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                HStack(spacing: 8) {
                    TextField("keys", text: $taughtObjectLabel)
                        .textFieldStyle(.roundedBorder)
                    paceSettingsButton("Capture centered object", systemName: "viewfinder") {
                        controlCenter.teachObject(label: taughtObjectLabel)
                        taughtObjectLabel = ""
                    }
                    .disabled(controlCenter.activeSources.contains(.camera) == false)
                }
                if let status = controlCenter.objectTeachingStatusText {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                ForEach(controlCenter.taughtObjectLabels, id: \.self) { label in
                    HStack {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Button("Forget") { controlCenter.forgetTaughtObject(label: label) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .pointerCursor()
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private var observeOnlyActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Observe-only dogfood")
            Text("Conversation starts only when you click. It uses Pace’s existing push-to-talk path and does not enable ambient transcription.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
            paceSettingsButton("Talk to Pace now", systemName: "mic.fill") {
                controlCenter.startUserInvokedConversation()
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Interventions")
            paceSettingsToggleRow(
                title: "Silent cards",
                subtitle: "Optional, silent companion observations. Default off and shown only after policy scoring.",
                isOn: Binding(
                    get: { controlCenter.preferences.areSilentCardsEnabled },
                    set: { controlCenter.setSilentCardsEnabled($0) }
                )
            )
            .disabled(PaceCompanionControlCenter.silentCardsAcceptancePassed == false)
            .opacity(PaceCompanionControlCenter.silentCardsAcceptancePassed ? 1 : 0.55)
            paceSettingsToggleRow(
                title: "Spoken interventions",
                subtitle: "Optional and default off. Every utterance still passes active-call, Focus, input, and cooldown restraint.",
                isOn: Binding(
                    get: { controlCenter.preferences.areSpokenInterventionsEnabled },
                    set: { controlCenter.setSpokenInterventionsEnabled($0) }
                )
            )
            .disabled(PaceCompanionControlCenter.spokenInterventionsAcceptancePassed == false)
            .opacity(PaceCompanionControlCenter.spokenInterventionsAcceptancePassed ? 1 : 0.55)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Structured memory")
            Stepper(
                "Retention: \(controlCenter.preferences.structuredObservationRetentionDays) days",
                value: Binding(
                    get: { controlCenter.preferences.structuredObservationRetentionDays },
                    set: { controlCenter.setRetentionDays($0) }
                ),
                in: 1...90
            )
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
            .pointerCursor()

            Text("Storage used: \(ByteCountFormatter.string(fromByteCount: Int64(controlCenter.structuredStorageByteCount), countStyle: .file))")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)

            HStack {
                ForEach(clearableSources, id: \.rawValue) { source in
                    paceSettingsButton("Clear \(displayName(for: source))", systemName: "trash") {
                        controlCenter.clear(source: source)
                    }
                }
                Spacer()
                paceSettingsButton("Clear all", systemName: "trash.fill") {
                    controlCenter.clearAll()
                }
            }
        }
    }

    private func sourceToggle(
        _ source: PacePerceptionSourceKind,
        title: String,
        subtitle: String
    ) -> some View {
        paceSettingsToggleRow(
            title: title,
            subtitle: subtitle,
            isOn: Binding(
                get: { controlCenter.preferences.enabledSources.contains(source) },
                set: { controlCenter.setSource(source, enabled: $0) }
            )
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.bottom, 6)
    }

    private var clearableSources: [PacePerceptionSourceKind] {
        [.camera, .ambientVoice, .screen, .macOSContext]
    }

    private var activeSourceSummary: String {
        guard controlCenter.activeSources.isEmpty == false else { return "No sources actively sampling" }
        return "Active: " + controlCenter.activeSources.map(displayName).sorted().joined(separator: ", ")
    }

    private func displayName(for source: PacePerceptionSourceKind) -> String {
        switch source {
        case .camera: return "camera"
        case .ambientVoice: return "voice"
        case .screen: return "screen"
        case .macOSContext: return "Mac context"
        case .userCorrection: return "corrections"
        }
    }

    private var statusColor: Color {
        switch controlCenter.runtimeState {
        case .observing: return .green
        case .interpreting: return .cyan
        case .paused: return .yellow
        case .degraded: return .orange
        case .privacyBlocked: return .red
        case .off, .starting: return DS.Colors.textTertiary
        }
    }
}
