//
//  PaceGeneralSettingsTab.swift
//  leanring-buddy
//
//  Settings → General tab content. Default landing surface: read-my-
//  screen, approve risky actions, cursor annotations, watch mode,
//  always listening, the four nudge toggles, posture watch, and the
//  morning brief subsection (toggle + hour/minute pickers + send-it-now
//  preview button).
//

import SwiftUI

struct PaceGeneralSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            paceSettingsToggleRow(
                title: "Read my screen",
                subtitle: "Use local screen context when a turn needs it.",
                isOn: Binding(
                    get: { companionManager.useLocalVLMForScreenContext },
                    set: { companionManager.setUseLocalVLMForScreenContext($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Approve risky actions",
                subtitle: "Ask before non-undoable local changes, message drafts, shortcuts, and MCP calls.",
                isOn: Binding(
                    get: { companionManager.requiresActionApproval },
                    set: { companionManager.setRequiresActionApproval($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Cursor annotations",
                subtitle: "Show transcript, response, and pointer labels near the cursor.",
                isOn: Binding(
                    get: { companionManager.areCursorAnnotationsEnabled },
                    set: { companionManager.setCursorAnnotationsEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Tuition mode",
                subtitle: "Pace teaches instead of acts: it draws shapes on screen and explains the step, rather than clicking through for you. Turn off when you want it to just do the thing.",
                isOn: Binding(
                    get: { companionManager.isTuitionModeEnabled },
                    set: { companionManager.setIsTuitionModeEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Watch mode",
                subtitle: companionManager.latestWatchModeSummary ?? "Watch for meaningful screen changes.",
                isOn: Binding(
                    get: { companionManager.isWatchModeEnabled },
                    set: { companionManager.setWatchModeEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Always listening",
                subtitle: "Opt-in ambient command mode. Push-to-talk remains available.",
                isOn: Binding(
                    get: { companionManager.isAlwaysListeningEnabled },
                    set: { companionManager.setAlwaysListeningEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Focus nudges",
                subtitle: "Offer a short break prompt after long active foreground sessions.",
                isOn: Binding(
                    get: { companionManager.areFocusFatigueNudgesEnabled },
                    set: { companionManager.setFocusFatigueNudgesEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Calendar nudges",
                subtitle: "Opt-in five-minute lead-time prompts for meeting-like events.",
                isOn: Binding(
                    get: { companionManager.areCalendarNudgesEnabled },
                    set: { companionManager.setCalendarNudgesEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Watch observation nudges",
                subtitle: "Opt-in prompts when watch mode sees local error/build-failure cues.",
                isOn: Binding(
                    get: { companionManager.areWatchObservationNudgesEnabled },
                    set: { companionManager.setWatchObservationNudgesEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Posture watch (camera)",
                subtitle: companionManager.latestPostureStatus
                    ?? "Gentle spoken nudge when you slouch or lean in. One camera frame every ten seconds, analyzed on-device, never stored.",
                isOn: Binding(
                    get: { companionManager.isPostureWatchEnabled },
                    set: { companionManager.setPostureWatchEnabled($0) }
                )
            )
            if companionManager.isPostureWatchEnabled {
                HStack {
                    Spacer()
                    paceSettingsButton("Recalibrate posture", systemName: "figure.seated.side") {
                        companionManager.recalibratePostureWatch()
                    }
                }
                .padding(.top, 6)
            }

            morningBriefSubsection
                .padding(.top, 18)

            meetingNotesSubsection
                .padding(.top, 18)

            automationSubsection
                .padding(.top, 18)
        }
    }

    // MARK: - Automation subsection

    /// Settings → General → Automation. Toggles for meeting mode,
    /// cron scheduling, and dynamic plugins. All default OFF.
    private var automationSubsection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Automation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            paceSettingsToggleRow(
                title: "Meeting mode",
                subtitle: "Capture system audio (excluding Pace) so Pace can listen during calls. Say \"start meeting mode\" or toggle here.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.bool(for: .isMeetingModeEnabled) },
                    set: { newValue in
                        PaceUserPreferencesStore.setBool(newValue, for: .isMeetingModeEnabled)
                        Task { @MainActor in
                            let controller = PaceMeetingModeController.shared
                            if newValue {
                                controller.isEnabled = true
                                controller.localRetriever = companionManager.localRetriever
                                // Privacy-pinned: meeting synthesis never
                                // uses the active (possibly off-device) tier.
                                controller.plannerClient = BuddyPlannerClientFactory.makeLocalOnlyPlannerForPrivacyPinnedFeatures()
                                await controller.start()
                            } else {
                                controller.isEnabled = false
                                await controller.stop()
                            }
                        }
                    }
                )
            )

            paceSettingsToggleRow(
                title: "Cron scheduling",
                subtitle: "Run recurring planner tasks on a timer. Say \"every 30 minutes check my calendar\" to add a task.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.bool(for: .isCronSchedulerEnabled) },
                    set: { newValue in
                        PaceUserPreferencesStore.setBool(newValue, for: .isCronSchedulerEnabled)
                        PaceCronScheduler.shared.setEnabled(newValue)
                    }
                )
            )

            paceSettingsToggleRow(
                title: "Dynamic plugins",
                subtitle: "Load user-installed tool plugins from ~/Library/Application Support/Pace/plugins/. Auto-repair failed commands via the planner.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.bool(.areDynamicPluginsEnabled, default: false) },
                    set: { newValue in
                        PaceUserPreferencesStore.setBool(newValue, for: .areDynamicPluginsEnabled)
                    }
                )
            )
        }
    }

    // MARK: - Morning brief subsection

    /// Settings → General → Morning brief. Toggle + hour/minute pickers
    /// + a "Send it now" preview button. The toggle is opt-in (default
    /// OFF in `PaceUserPreferencesStore`); the preview button always
    /// works so users can tune brief content before committing to a
    /// daily fire time.
    private var morningBriefSubsection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Morning brief")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            paceSettingsToggleRow(
                title: "Daily morning brief",
                subtitle: "Calm 30-second spoken brief at the configured weekday time. Gated by the same active-call rules as other proactive features.",
                isOn: Binding(
                    get: { companionManager.isMorningTriageEnabled },
                    set: { companionManager.setMorningTriageEnabled($0) }
                )
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fire time")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Local time, weekdays only. Saturday and Sunday are skipped.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Picker(
                    "Hour",
                    selection: Binding(
                        get: { companionManager.morningTriageHourOfDay },
                        set: { companionManager.setMorningTriageHourOfDay($0) }
                    )
                ) {
                    ForEach(0..<24, id: \.self) { hourOfDayCandidate in
                        Text(String(format: "%02d", hourOfDayCandidate))
                            .tag(hourOfDayCandidate)
                    }
                }
                .labelsHidden()
                .frame(width: 60)

                Text(":")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                Picker(
                    "Minute",
                    selection: Binding(
                        get: { companionManager.morningTriageMinuteOfHour },
                        set: { companionManager.setMorningTriageMinuteOfHour($0) }
                    )
                ) {
                    ForEach(0..<60, id: \.self) { minuteOfHourCandidate in
                        Text(String(format: "%02d", minuteOfHourCandidate))
                            .tag(minuteOfHourCandidate)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            HStack {
                Spacer()
                paceSettingsButton("Send it now", systemName: "paperplane") {
                    companionManager.deliverMorningBriefPreviewNow()
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Meeting notes subsection

    /// Settings → General → Meeting notes. Retention days, transcription
    /// backend picker, crash-repair button, and the per-source retrieval
    /// toggle for `meetingNotes`.
    private var meetingNotesSubsection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meeting notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Retention")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Days to keep meeting notes in the retrieval index.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Stepper(
                    value: Binding(
                        get: { PaceUserPreferencesStore.meetingNotesRetentionDays() },
                        set: { PaceUserPreferencesStore.setMeetingNotesRetentionDays($0) }
                    ),
                    in: 1...365
                ) {
                    Text("\(PaceUserPreferencesStore.meetingNotesRetentionDays()) days")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcription backend")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("WhisperKit is more accurate on long audio; Apple Speech needs no model download.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Picker(
                    "Backend",
                    selection: Binding(
                        get: { PaceUserPreferencesStore.meetingNotesTranscriptionBackend() },
                        set: { PaceUserPreferencesStore.setMeetingNotesTranscriptionBackend($0) }
                    )
                ) {
                    Text("WhisperKit").tag("whisperkit")
                    Text("Apple Speech").tag("apple")
                }
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            paceSettingsToggleRow(
                title: "Index meeting notes for recall",
                subtitle: "When on, synthesized notes are journaled so \"what did we decide in standup?\" answers from local history.",
                isOn: Binding(
                    get: { companionManager.isLocalRetrievalSourceEnabled(.meetingNotes) },
                    set: { companionManager.setLocalRetrievalSourceEnabled($0, for: .meetingNotes) }
                )
            )

            HStack {
                Spacer()
                paceSettingsButton("Repair crashed recordings", systemName: "wrench.and.screwdriver") {
                    // Static sweep over EVERY meeting directory — a fresh
                    // recorder instance can't know a crashed meeting's UUID.
                    PaceMeetingAudioRecorder.crashRepairAllMeetingRecordings()
                }
            }
            .padding(.top, 8)
        }
    }
}
