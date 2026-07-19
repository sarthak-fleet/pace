# Proactive surfaces

Pace's opt-in "speaks without being asked" layer — nudges, briefs, and passive
detectors. **Every surface on this page defaults OFF** and, when enabled, still
routes through the restraint gate (active-call check, cooldown, intent
confidence) before it's allowed to speak — see
[`planning-and-latency.md`](planning-and-latency.md) for how that gate works;
it is not re-explained here.

## Proactive nudge framework
- What: A generator protocol (`PaceProactiveNudgeGenerator`) that any nudge source conforms to, plus an orchestrator that wires generators to the restraint gate and to `CompanionManager`'s emit/queue closures.
- Why here: The single scaffold all three built-in nudges (focus-fatigue, calendar pre-meeting, watch-mode observation) share, so adding a fourth nudge source means writing one generator, not a bespoke pipeline.
- Where: `PaceProactiveNudgeFramework.swift` — `PaceProactiveNudgeGenerator`, `PaceProactiveNudgeOrchestrator`; decision helpers in `PaceProactiveNudges.swift` — `PaceFocusFatigueNudgeDecision`, `PaceCalendarPreMeetingNudgeDecision`, `PaceWatchModeObservationNudgeDecision`.
- Source: internal — no external spec.

## Morning triage / brief
- What: A once-per-weekday scheduler that assembles a spoken morning brief from calendar, mail, reminders, and app-usage inputs.
- Why here: Gives Pace a single daily proactive touchpoint instead of scattered ad-hoc interruptions; if the restraint gate says stay quiet at fire time, the brief is parked on a panel card rather than dropped.
- Where: `PaceMorningTriageScheduler.swift` — `PaceMorningTriageScheduler`, `PaceMorningTriageContext` (gated by preference key `isMorningTriageEnabled`); `PaceMorningBriefBuilder.swift` — `PaceMorningBriefInputs`.
- Source: internal — no external spec.

## Focus-fatigue nudge
- What: Tracks how long the user has stayed on one foreground app via `NSWorkspace.didActivateApplicationNotification` and offers a break nudge once a continuous-use threshold is crossed.
- Why here: The simplest proactive surface — no new permission, just an activation-notification subscription — and the template the other two generators followed.
- Where: `PaceFocusFatigueNudgeGenerator.swift` — `PaceFocusFatigueNudgeGenerator` (gated by preference key `areFocusFatigueNudgesEnabled`); decision logic in `PaceProactiveNudges.swift` — `PaceFocusFatigueNudgeDecision.evaluate`.
- Source: internal — no external spec.

## Calendar pre-meeting nudge
- What: Watches upcoming EventKit calendar events and offers a heads-up roughly 5 minutes before a meeting-shaped event starts.
- Why here: Turns Pace's existing calendar read access into a proactive surface instead of a purely on-demand one.
- Where: `PaceCalendarPreMeetingNudgeGenerator.swift` — `PaceCalendarPreMeetingNudgeGenerator` (gated by preference key `areCalendarNudgesEnabled`); decision logic in `PaceProactiveNudges.swift` — `PaceCalendarPreMeetingNudgeDecision`.
- Source: https://developer.apple.com/documentation/eventkit

## Watch-mode observation nudges
- What: Offers help when Watch Mode detects a major screen change (e.g. an error dialog, a stuck state) worth surfacing proactively.
- Why here: The one nudge source that is screen-aware rather than schedule- or calendar-driven, reusing Watch Mode's existing diff events instead of a new sampling loop.
- Where: `PaceWatchModeObservationNudgeGenerator.swift` — `PaceWatchModeObservationNudgeGenerator` (gated by preference key `areWatchObservationNudgesEnabled`); decision logic in `PaceProactiveNudges.swift` — `PaceWatchModeObservationNudgeDecision`.
- Source: internal — no external spec.

## Posture monitor
- What: Samples one frame every 10 seconds from the built-in camera via `AVCaptureSession` and runs Vision face detection on it to infer slouching/leaning posture; frames are never stored, only passed to a pure analyzer.
- Why here: The most privacy-sensitive proactive surface in the app, so it's built to the strictest bar — no frame persistence, no cloud call, a fixed low sampling rate, and an explicit opt-in.
- Where: `PacePostureMonitor.swift` — `PacePostureMonitor` (`samplingIntervalInSeconds = 10`, gated by preference key `isPostureWatchEnabled`), `PacePostureFrameGate`.
- Source: https://developer.apple.com/documentation/vision

## Active-call detector
- What: Polls `NSWorkspace.runningApplications` for known video/call app bundle IDs (Zoom, Teams, FaceTime, Slack) to conservatively infer "the user is probably on a call."
- Why here: The primary signal the restraint gate uses to suppress proactive speech during a meeting — deliberately permission-free and biased toward false negatives (an idle Slack shouldn't block a nudge) over false positives.
- Where: `PaceActiveCallDetector.swift` — `PaceActiveCallDetector`.
- Source: internal — no external spec.

## IDE context detector
- What: A pure window-title parser that maps a frontmost bundle ID + window title string into a typed IDE kind (Xcode, VS Code, Cursor, etc.) and, where the title format allows, the focused file.
- Why here: Lets other surfaces (nudges, journals) reason about "the user is coding, and in what file" without requesting Accessibility permission just to read a window title.
- Where: `PaceIDEContextDetector.swift` — `PaceIDEContext`.
- Source: internal — no external spec.

## App usage journal
- What: A permission-free, day-bucketed record of foreground-app minutes and app-switch counts, fed by `NSWorkspace` activation notifications and capped at a 7-day rolling retention window.
- Why here: The passive data source behind "what did I do today?" recall — the tracker (`PaceAppUsageTracker`) captures the raw signal live, and the journal persists it into the same retrieval-document format the rest of local recall reads from.
- Where: `PaceAppUsageTracker.swift` — `PaceAppUsageTracker`; `PaceAppUsageJournal.swift` — `PaceAppUsageJournal` (source `.appUsageHistory`, `maximumDayBucketCount = 7`).
- Source: internal — no external spec.

## Screen watch journal
- What: A pure day-and-screen-bucketed journal of Watch Mode's screen-change events, persisted as retrieval documents and capped at a 7-day rolling window.
- Why here: Turns Watch Mode from a live-only feature into a historical-recall source — the same "what did I do today?" questions that read the app usage journal also read this one for screen-level detail.
- Where: `PaceScreenWatchJournal.swift` — `PaceScreenWatchJournal`, `PaceScreenWatchJournalEntry` (source `.screenWatchHistory`, `maximumDayBucketCount = 7`).
- Source: internal — no external spec.

## See also

[`README.md`](README.md)
