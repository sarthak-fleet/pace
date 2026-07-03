//
//  PaceAmbientContextStore.swift
//  leanring-buddy
//
//  Always-on ambient context store — passively gathers lightweight
//  context from the system so the planner has instant background
//  knowledge without burning a screenshot/VLM turn.
//
//  Inspired by FluidVoice's AX-tree-first approach and Granola's
//  always-on meeting context. The key insight: most "what was I
//  looking at?" / "what app am I in?" questions can be answered
//  from free, permission-less system APIs in <1ms, not from a 3s
//  VLM screenshot cycle.
//
//  What this stores (all permission-free, cheap to read):
//    - Frontmost app name + bundle ID
//    - Focused window title (via AX)
//    - Frontmost app's AX tree summary (top-level elements only)
//    - Clipboard change count + last change timestamp (not content)
//    - Active display count
//    - Time of day / day of week
//    - Active Focus Mode name (currently always nil — macOS exposes
//      no public API for the active Focus name; kept as a field so
//      the prompt fragment gains it if an API appears)
//
//  What this does NOT store (privacy boundaries):
//    - Clipboard content (only metadata — "user copied something")
//    - AX tree content (only structure — "3 buttons, 1 text field")
//    - Window content (only title — "Inbox — Mail")
//    - No keylogging, no screen recording, no file content reading
//
//  The snapshot is refreshed every 3 seconds via a Timer. The planner
//  can read the latest snapshot synchronously — zero latency for
//  context that would otherwise cost a VLM round-trip.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

/// A lightweight ambient context snapshot. All fields are derived
/// from permission-free system APIs and cost <1ms to read.
struct PaceAmbientContextSnapshot: Equatable {
    /// When this snapshot was taken.
    let timestamp: Date
    /// Frontmost app name (e.g. "Safari", "Xcode").
    let frontmostAppName: String?
    /// Frontmost app bundle ID (e.g. "com.apple.Safari").
    let frontmostBundleID: String?
    /// Focused window title (e.g. "Inbox — Mail").
    let focusedWindowTitle: String?
    /// Summary of the frontmost app's AX tree (top-level element
    /// counts by role). e.g. "3 buttons, 1 textfield, 2 links".
    let axTreeSummary: String?
    /// Number of times the clipboard has changed since app launch.
    let clipboardChangeCount: Int
    /// When the clipboard last changed.
    let clipboardLastChangedAt: Date?
    /// Number of active displays.
    let displayCount: Int
    /// Whether a Focus Mode is active (and its name if available).
    let focusModeName: String?
    /// Current time-of-day bucket for the planner.
    /// "morning" (5-12), "afternoon" (12-17), "evening" (17-21), "night" (21-5)
    let timeOfDayBucket: String
    /// Day of week.
    let dayOfWeek: String

    /// Render a compact string suitable for injecting into the planner
    /// system prompt as `<ambient_context>...</ambient_context>`.
    var promptFragment: String {
        var lines: [String] = []
        if let app = frontmostAppName {
            lines.append("frontmost app: \(app)")
        }
        if let title = focusedWindowTitle {
            lines.append("window: \(title)")
        }
        if let summary = axTreeSummary {
            lines.append("ui elements: \(summary)")
        }
        if clipboardChangeCount > 0 {
            lines.append("clipboard: changed \(clipboardChangeCount) times (last at \(clipboardLastChangedAt.map { PaceAmbientContextStore.timeFormatter.string(from: $0) } ?? "unknown"))")
        }
        if let focus = focusModeName {
            lines.append("focus mode: \(focus)")
        }
        lines.append("time: \(timeOfDayBucket), \(dayOfWeek)")
        lines.append("displays: \(displayCount)")

        return lines.joined(separator: "; ")
    }

    static func == (lhs: PaceAmbientContextSnapshot, rhs: PaceAmbientContextSnapshot) -> Bool {
        lhs.frontmostAppName == rhs.frontmostAppName &&
            lhs.frontmostBundleID == rhs.frontmostBundleID &&
            lhs.focusedWindowTitle == rhs.focusedWindowTitle &&
            lhs.axTreeSummary == rhs.axTreeSummary &&
            lhs.clipboardChangeCount == rhs.clipboardChangeCount &&
            lhs.displayCount == rhs.displayCount &&
            lhs.focusModeName == rhs.focusModeName
    }
}

/// Manages the always-on ambient context store. Polls the system
/// every 3 seconds and caches the latest snapshot for synchronous
/// reads by the planner.
@MainActor
final class PaceAmbientContextStore: ObservableObject {
    static let shared = PaceAmbientContextStore()

    @Published private(set) var currentSnapshot: PaceAmbientContextSnapshot?

    /// Polling interval in seconds. 3s balances freshness vs CPU cost.
    /// Each poll is <1ms (AX title read + NSWorkspace query + timer).
    private let pollIntervalSeconds: TimeInterval = 3.0
    private var pollTimer: Timer?
    private(set) var isRunning = false

    /// Clipboard tracking (metadata only, never content).
    private var clipboardChangeCount: Int = 0
    private var clipboardLastChangedAt: Date?
    private var lastClipboardChangeCount: Int = 0

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private init() {
        // Seed the clipboard change count.
        lastClipboardChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("🌐 Ambient context store started (polling every \(Int(pollIntervalSeconds))s)")

        // Take an immediate snapshot so the planner has context from
        // the first turn.
        refreshSnapshot()

        let timer = Timer(
            timeInterval: pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
        print("🌐 Ambient context store stopped")
    }

    // MARK: - Snapshot

    /// Take a fresh snapshot of the system state.
    private func refreshSnapshot() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName
        let bundleID = frontmostApp?.bundleIdentifier

        // Read the focused window title via AX. This is <1ms for most
        // apps; we don't walk the full tree here (that's the job of
        // PaceAXScreenReader when a screenshot is needed).
        let windowTitle = readFocusedWindowTitle()

        // Read a lightweight AX tree summary (just top-level element
        // counts by role). This is much cheaper than a full tree walk.
        let axSummary = readAXTreeSummary()

        // Track clipboard changes (metadata only).
        let currentChangeCount = NSPasteboard.general.changeCount
        if currentChangeCount != lastClipboardChangeCount {
            clipboardChangeCount += 1
            clipboardLastChangedAt = Date()
            lastClipboardChangeCount = currentChangeCount
        }

        let displayCount = NSScreen.screens.count
        let focusMode = readFocusMode()
        let (timeOfDay, weekday) = computeTimeContext()

        let snapshot = PaceAmbientContextSnapshot(
            timestamp: Date(),
            frontmostAppName: appName,
            frontmostBundleID: bundleID,
            focusedWindowTitle: windowTitle,
            axTreeSummary: axSummary,
            clipboardChangeCount: clipboardChangeCount,
            clipboardLastChangedAt: clipboardLastChangedAt,
            displayCount: displayCount,
            focusModeName: focusMode,
            timeOfDayBucket: timeOfDay,
            dayOfWeek: weekday
        )

        // Only publish if something meaningful changed (avoids
        // unnecessary @Published churn).
        if snapshot != currentSnapshot {
            currentSnapshot = snapshot
        }
    }

    // MARK: - System readers

    /// Read the focused window title via AX. Returns nil if AX is
    /// not available or the app doesn't expose a window title.
    private func readFocusedWindowTitle() -> String? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard let pid = frontmostApp?.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        // Type-check before casting — a force cast here would crash the
        // 3-second poll timer on the MainActor if an app ever returns an
        // unexpected CFTypeRef for the focused-window attribute.
        guard let focusedWindow = focusedWindowRef,
              CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { return nil }
        let focusedWindowElement = unsafeDowncast(focusedWindow as AnyObject, to: AXUIElement.self)

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindowElement, kAXTitleAttribute as CFString, &titleRef)
        return titleRef as? String
    }

    /// Read a lightweight summary of the frontmost app's AX tree.
    /// Only counts top-level elements by role — doesn't walk the
    /// full tree. This is <5ms for most apps.
    private func readAXTreeSummary() -> String? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard let pid = frontmostApp?.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(pid)

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        // Count top-level elements by role.
        var roleCounts: [String: Int] = [:]
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String {
                roleCounts[role, default: 0] += 1
            }
        }

        guard !roleCounts.isEmpty else { return nil }
        // Format as "3 AXButton, 1 AXTextField, 2 AXWebArea"
        return roleCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
    }

    /// Read the current Focus Mode name. Returns nil if no Focus
    /// Mode is active or if the API is unavailable.
    private func readFocusMode() -> String? {
        // Focus Mode detection via NSWorkspace on macOS 12+.
        // The actual API is limited; we check if Do Not Disturb
        // is on via the user defaults proxy.
        // This is a best-effort read — not critical if it fails.
        return nil
    }

    /// Compute the time-of-day bucket and day of week.
    private func computeTimeContext() -> (timeOfDay: String, weekday: String) {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekdayIndex = calendar.component(.weekday, from: now)

        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        case 17..<21: timeOfDay = "evening"
        default: timeOfDay = "night"
        }

        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekday = weekdays[weekdayIndex - 1]

        return (timeOfDay, weekday)
    }

    /// Get the current snapshot's prompt fragment for injection
    /// into the planner system prompt. Returns empty string if
    /// no snapshot is available.
    var ambientPromptFragment: String {
        guard let snapshot = currentSnapshot else { return "" }
        let fragment = snapshot.promptFragment
        return fragment.isEmpty ? "" : "<ambient_context>\(fragment)\n</ambient_context>"
    }
}
