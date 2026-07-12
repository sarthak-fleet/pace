//
//  PaceTasksSettingsTab.swift
//  leanring-buddy
//
//  Settings → Tasks tab content. Lists the recurring scheduled tasks the
//  user created by voice ("every 30 minutes check my calendar"), showing
//  each task's humanized interval, weekend-skip note, and when it last
//  ran, with a per-task delete button. Read-only otherwise: scheduled
//  tasks are created through the voice command parser in
//  `PaceCronScheduler.parseVoiceCommand`, not this surface.
//

import SwiftUI

struct PaceTasksSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var cronScheduler = PaceCronScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scheduled tasks")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Recurring things Pace runs for you on a timer. Create one by voice — for example, \"every morning at 9, summarize my calendar\" or \"every 2 hours remind me to stand up\".")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            scheduledTasksSection
        }
    }

    private var scheduledTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recurring tasks")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            if cronScheduler.tasks.isEmpty {
                Text("No scheduled tasks yet. Say something like \"every morning at 9, summarize my calendar\" and it'll show up here.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cronScheduler.tasks) { task in
                        scheduledTaskRow(task)
                    }
                }
            }
        }
    }

    private func scheduledTaskRow(_ task: PaceCronTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(Self.humanizedInterval(task.intervalSeconds))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                    if task.skipWeekends {
                        Text("· Skips weekends")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                Text(Self.lastRunDescription(for: task.lastRunAt))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            paceSettingsButton("Delete", systemName: "trash") {
                cronScheduler.removeTask(id: task.id)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    // MARK: - Formatting helpers

    /// Renders an interval in seconds as a human-readable cadence, e.g.
    /// "Every 30 minutes", "Every 2 hours", or "Daily". Pure so it can
    /// be unit-tested without a scheduler or a view.
    static func humanizedInterval(_ intervalSeconds: TimeInterval) -> String {
        let totalSeconds = Int(intervalSeconds.rounded())
        guard totalSeconds > 0 else { return "Every moment" }

        let secondsPerMinute = 60
        let secondsPerHour = 3_600
        let secondsPerDay = 86_400

        if totalSeconds == secondsPerDay {
            return "Daily"
        }
        if totalSeconds % secondsPerDay == 0 {
            let dayCount = totalSeconds / secondsPerDay
            return "Every \(dayCount) days"
        }
        if totalSeconds == secondsPerHour {
            return "Every hour"
        }
        if totalSeconds % secondsPerHour == 0 {
            let hourCount = totalSeconds / secondsPerHour
            return "Every \(hourCount) hours"
        }
        if totalSeconds == secondsPerMinute {
            return "Every minute"
        }
        if totalSeconds % secondsPerMinute == 0 {
            let minuteCount = totalSeconds / secondsPerMinute
            return "Every \(minuteCount) minutes"
        }
        if totalSeconds == 1 {
            return "Every second"
        }
        return "Every \(totalSeconds) seconds"
    }

    private static let relativeDateTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func lastRunDescription(for lastRunAt: Date?) -> String {
        guard let lastRunAt else { return "Hasn't run yet" }
        let relativeDescription = relativeDateTimeFormatter.localizedString(
            for: lastRunAt,
            relativeTo: Date()
        )
        return "Last ran \(relativeDescription)"
    }
}
