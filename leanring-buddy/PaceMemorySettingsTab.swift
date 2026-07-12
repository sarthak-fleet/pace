//
//  PaceMemorySettingsTab.swift
//  leanring-buddy
//
//  Settings → Memory tab content. Shows the episodic-memory roster,
//  lets the user delete individual facts (writes a 30-day tombstone),
//  toggles whether sensitive topics flow into the planner prompt, and
//  wipes the whole store. The store + retrieval bucket stay in sync
//  via `CompanionManager.deleteEpisodicFact` / `resetAllEpisodicMemory`.
//

import SwiftUI

struct PaceMemorySettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var injectSensitiveEpisodicTopicsForSettings: Bool = PaceUserPreferencesStore
        .bool(.injectSensitiveEpisodicTopics, default: false)
    @State private var useUnifiedMemoryRecallForSettings: Bool = PaceUserPreferencesStore
        .bool(.useUnifiedMemoryRecall, default: true)
    @State private var memoryRefreshTick: Int = 0
    @State private var researchHistoryRefreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Episodic memory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Durable facts Pace has remembered from your conversations. Pace re-extracts after every turn; the dedup + 200-fact cap + tombstone gates keep this list bounded.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $useUnifiedMemoryRecallForSettings) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart recall (semantic)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Ranks everything Pace remembers by meaning, not just keywords, so a question can recall related memories even without matching words. Needs the embedding model loaded in LM Studio; otherwise Pace falls back to keyword search automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: useUnifiedMemoryRecallForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .useUnifiedMemoryRecall)
            }

            Text("Indexed for recall: \(companionManager.unifiedMemoryFactCount()) fact\(companionManager.unifiedMemoryFactCount() == 1 ? "" : "s") · \(companionManager.unifiedMemoryConversationCount()) conversation\(companionManager.unifiedMemoryConversationCount() == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .id(memoryRefreshTick)

            Toggle(isOn: $injectSensitiveEpisodicTopicsForSettings) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inject sensitive topics in context")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Off by default. Even when off, Pace still STORES sensitive facts — it just keeps them out of the planner prompt. Sensitive topics: #health, #finance, #relationship.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: injectSensitiveEpisodicTopicsForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .injectSensitiveEpisodicTopics)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            episodicFactRosterSection
                .id(memoryRefreshTick)

            Divider()
                .background(DS.Colors.borderSubtle)

            pastResearchSection
                .id(researchHistoryRefreshTick)

            Divider()
                .background(DS.Colors.borderSubtle)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reset all episodic memory")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Tombstones every fact for 30 days so re-extraction won't immediately resurrect them.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                paceSettingsButton("Reset", systemName: "trash.slash") {
                    companionManager.resetAllEpisodicMemory()
                    memoryRefreshTick &+= 1
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var episodicFactRosterSection: some View {
        let allEpisodicFacts = companionManager.episodicFactStore.allFacts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(allEpisodicFacts.count) fact\(allEpisodicFacts.count == 1 ? "" : "s") remembered")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }

            if allEpisodicFacts.isEmpty {
                Text("Pace hasn't remembered anything durable yet. Mention a preference (\"I prefer dark mode\") or a recurring fact and it'll show up here after the next turn.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(allEpisodicFacts) { fact in
                        episodicFactRow(fact)
                    }
                }
            }
        }
    }

    private func episodicFactRow(_ fact: PaceEpisodicFact) -> some View {
        let factIsSensitive = PaceEpisodicSensitiveTopics.isFactSensitive(fact)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(fact.subject) \(fact.predicate) \(fact.value)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(fact.topicHashtags, id: \.self) { hashtag in
                        Text(hashtag)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(factIsSensitive
                                             ? DS.Colors.warning
                                             : DS.Colors.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    (factIsSensitive ? DS.Colors.warning : DS.Colors.accent).opacity(0.12)
                                )
                            )
                    }
                    Text(String(format: "%.0f%% conf", fact.confidence * 100))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer(minLength: 0)
            paceSettingsButton("Delete", systemName: "trash") {
                companionManager.deleteEpisodicFact(withIdentifier: fact.identifier)
                memoryRefreshTick &+= 1
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    // MARK: - Past research subsection

    private var pastResearchSection: some View {
        let researchEntries = companionManager.researchHistoryEntries()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Past research")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if !researchEntries.isEmpty {
                    paceSettingsButton("Clear all", systemName: "trash.slash") {
                        companionManager.clearResearchHistory()
                        researchHistoryRefreshTick &+= 1
                    }
                }
            }

            Text("Research turns Pace has run for you, newest first. Kept for 30 days (up to 100 entries) so \"what did I research about X?\" can recall them.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if researchEntries.isEmpty {
                Text("No research yet. Ask Pace to research something and it'll show up here after the turn finishes.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(researchEntries, id: \.id) { entry in
                        pastResearchRow(entry)
                    }
                }
            }
        }
    }

    private func pastResearchRow(_ entry: PaceResearchJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.question)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.answer)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.researchTimestampFormatter.localizedString(for: entry.recordedAt, relativeTo: Date()))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            paceSettingsButton("Delete", systemName: "trash") {
                companionManager.deleteResearchHistoryEntry(id: entry.id)
                researchHistoryRefreshTick &+= 1
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    private static let researchTimestampFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
