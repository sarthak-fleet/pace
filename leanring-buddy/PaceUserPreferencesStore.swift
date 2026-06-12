//
//  PaceUserPreferencesStore.swift
//  leanring-buddy
//
//  Typed key namespace + load/save helpers for user-toggleable
//  preferences. Replaces three hand-rolled `UserDefaults
//  .object(forKey:) == nil ? default : bool(forKey:)` patterns scattered
//  across `CompanionManager` — each with its own stringly-typed key.
//
//  The `@Published` properties stay on `CompanionManager` so the
//  existing SwiftUI bindings keep working. This store owns only the
//  storage-layer concern: key strings, defaults, and (for one
//  preference) the Info.plist seed on first launch.
//
//  Adding a new boolean preference is two lines: add a case to
//  `PaceUserPreferenceKey`, and decide its default by calling either
//  `bool(_:default:)` or `boolWithInfoPlistSeed(_:infoPlistKey:)`.
//

import Foundation

enum PaceUserPreferenceKey: String {
    case useLocalVLMForScreenContext
    case isWalkingAvatarEnabled
    case isPaceCursorEnabled
    case areCursorAnnotationsEnabled
    case requiresActionApproval
    case isPostureWatchEnabled
    case isAlwaysListeningEnabled
    case areFocusFatigueNudgesEnabled
    case areCalendarNudgesEnabled
    case areWatchObservationNudgesEnabled
    /// Master switch for the rolling-summary + verbatim-window in-
    /// context memory. Default ON — see PRD
    /// docs/prds/conversational-thread-memory.md.
    case isThreadMemoryEnabled
    /// How many turn pairs the planner sees verbatim before older
    /// turns get folded into the rolling summary. Clamped 1...8.
    case threadMemoryVerbatimWindowSize
    /// How long the thread can stay quiet before its summary +
    /// verbatim window are dropped. Clamped 5...60 minutes.
    case threadMemoryIdleMinutes
    /// Reveals the live summary text in Settings for transparency /
    /// debugging. Default OFF — the summary is never user-facing.
    case isThreadMemoryDebugViewEnabled
    /// Opt-in handoff: when a thread session ends, feed the final
    /// rolling summary to the episodic-fact extractor. Default OFF
    /// because the summarizer is loose; the episodic extractor is
    /// precise. Coupling them risks low-confidence facts.
    case isThreadEndingEpisodicHandoffEnabled
}

enum PaceUserPreferencesStore {
    /// Read a boolean preference. Returns `defaultValue` if the key has
    /// never been written.
    static func bool(_ key: PaceUserPreferenceKey, default defaultValue: Bool) -> Bool {
        guard let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool else {
            return defaultValue
        }
        return stored
    }

    /// Read a boolean preference, falling back to an Info.plist string
    /// value if the user has never touched the toggle. Used for one-off
    /// "seed from build config on first launch" cases.
    static func boolWithInfoPlistSeed(
        _ key: PaceUserPreferenceKey,
        infoPlistKey: String
    ) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
            return stored
        }
        let infoPlistRawValue = AppBundleConfiguration
            .stringValue(forKey: infoPlistKey)?
            .lowercased()
        return infoPlistRawValue == "true"
            || infoPlistRawValue == "1"
            || infoPlistRawValue == "yes"
    }

    static func setBool(_ value: Bool, for key: PaceUserPreferenceKey) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    /// Read an integer preference clamped to an inclusive range.
    /// Returns `defaultValue` (also clamped) if the key was never
    /// written. Used by the thread-memory picker controls so a bad
    /// UserDefaults value can never push the verbatim window above
    /// 8 or below 1.
    static func clampedInt(
        _ key: PaceUserPreferenceKey,
        default defaultValue: Int,
        in clampingRange: ClosedRange<Int>
    ) -> Int {
        let clampedDefault = min(max(defaultValue, clampingRange.lowerBound), clampingRange.upperBound)
        guard let storedRawValue = UserDefaults.standard.object(forKey: key.rawValue) as? Int else {
            return clampedDefault
        }
        return min(max(storedRawValue, clampingRange.lowerBound), clampingRange.upperBound)
    }

    static func setInt(_ value: Int, for key: PaceUserPreferenceKey) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
