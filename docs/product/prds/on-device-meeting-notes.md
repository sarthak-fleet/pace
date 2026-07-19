---
title: On-device meeting notes
description: PRD for local two-track meeting capture, transcription, and structured notes.
---

# PRD — On-device meeting notes

> **Follow-up (shipped separately):** adaptive, meeting-type-aware note
> profiles + transcript-grounded action items — meetily-informed but
> Pace-native — are specced in `openspec/changes/adaptive-meeting-notes`.
> The `general` profile reproduces this PRD's `{summary, actionItems,
> decisions}` output byte-for-byte and remains the default.

## Goal

Turn Pace's meeting mode from a stub that publishes RMS levels into a
real product: capture mic + system audio as two separate tracks,
segment the audio into attributed turns, transcribe on-device, and
synthesize structured notes (summary + action items) that feed the
existing retrieval index — so "what did we decide in standup?" is
answerable from local history. Fully on-device. No cloud STT, no
cloud LLM, no bytes off the Mac.

This is the headline wedge: Granola, Otter, and Fireflies all upload
audio to the cloud. Pace already has the ingredients (SCStream capture,
`PaceAudioFileTranscriber` with WhisperKit + Apple Speech backends,
`PaceDictationPostProcessor`, the journal/retrieval index). They are
unassembled. This PRD is the assembly plan.

Blueprint reference: the `os-june` clone's audio pipeline
(source-separated capture → energy-based turn segmentation →
speaker-echo trimming → structured notes) is the right shape to copy.
Pace keeps its in-process SCStream rather than os-june's out-of-process
CoreAudio tap (see ADR candidate below).

## Scope (v1)

A meeting is started and stopped explicitly (voice command or panel
toggle). While active:

1. **Two-track capture** — mic via `AVAudioEngine`, system via the
   existing `SCStream` in `PaceSystemAudioCapture`. Two independent
   `PaceMeetingAudioTrack` buffers, never mixed. Enables "you" vs
   "them" attribution and dropping a silent system track (no meeting
   audio → it's a solo dictation, not a meeting).
2. **On-device recording** — each track is written to a `.wav` (RIFF)
   under `~/Library/Application Support/Pace/meetings/<id>/`. Partial
   file with a `.part` suffix during recording; atomic rename to final
   on clean stop. RIFF-header repair on crash-recovery scan at launch
   so a force-quit mid-meeting still yields a playable file.
3. **Energy-based turn segmentation** — Accelerate RMS over
   fixed-size windows + a hysteresis state machine (speech / silence /
   speech) produces timestamped turn boundaries per track. Speaker-echo
   trimming: when the mic and system tracks both have energy inside a
   window, the louder track owns the turn and the other is suppressed
   for that window (kills Pace's TTS echo and Zoom echo). Output is a
   `[PaceMeetingTurn]` array with `start`, `end`, `track`, `attributedSpeaker`.
4. **Transcription** — each turn's audio slice is fed to
   `PaceAudioFileTranscriber` (WhisperKit first, Apple Speech fallback).
   The transcriber is extended to return per-segment text + timestamps
   instead of one concatenated string, so turns become attributable
   transcript lines. `PaceDictationPostProcessor` runs over the joined
   transcript for capitalization/punctuation cleanup.
5. **Notes synthesis** — the transcript is sent to the active planner
   (LM Studio `qwen3-30b-a3b` by default; Apple FM for short meetings
   if available) with a focused `PaceMeetingNotesPrompt` that returns
   JSON: `{summary, actionItems: [{text, owner, due}], decisions: [...],
   attendees: [...]}`. Failures fail loud (no silent fallback) per the
   existing planner posture; the raw transcript is still saved as the
   artifact so the user loses nothing.
6. **Retrieval wiring** — the notes + transcript are journaled as a
   new `PaceRetrievalSource.meetingNotes` document so "what did we
   decide in standup?" / "did we agree on the launch date?" answer
   from local history. Day-bucketed like `PaceScreenWatchJournal`.

Out of scope for v1: real-time streaming transcription (turns are
transcribed after stop, not live), speaker diarization beyond
mic-vs-system attribution, multi-participant naming, calendar event
auto-association (the user names the meeting on stop), cross-meeting
action-item tracking, cloud sync. Just: capture → segment → transcribe
→ notes → recall.

## Architecture

### Modify: `leanring-buddy/PaceSystemAudioCapture.swift`

`PaceMeetingModeController` today throws audio away — `handleAudioSample`
only forwards an RMS level. Extend the delegate to also append the raw
Float32 samples to a `PaceMeetingAudioTrack` (system) buffer, and
expose a `systemAudioTrack: PaceMeetingAudioTrack?` property. The
existing RMS publisher stays (the panel sound animation still uses it).
Add a `recordingURL: URL?` property and write the track to disk on
`stop()`.

### New file: `leanring-buddy/PaceMeetingAudioRecorder.swift` (~250 lines)

Owns the mic track via `AVAudioEngine` + input node tap, and the
two-track disk writer. Public API:

```swift
@MainActor
final class PaceMeetingAudioRecorder {
    let meetingID: UUID
    private(set) var micTrack: PaceMeetingAudioTrack?
    private(set) var systemTrack: PaceMeetingAudioTrack?
    private(set) var recordingDirectoryURL: URL

    init(meetingID: UUID, now: Date = Date())

    func startMicCapture() async throws
    func appendSystemSamples(_ samples: [Float])  // called by the SCStream delegate
    func stop() async -> PaceMeetingRecording  // flushes both tracks, atomic renames

    func crashRepairIfNeeded()  // called at launch; repairs .part files
}
```

`PaceMeetingAudioTrack` is a value type: `[Float]` samples + sample
rate + channel count. The writer serializes RIFF WAV headers
(16-bit PCM) directly — no AVAudioFile dependency for the recording
path so a mid-write crash leaves a header that `crashRepairIfNeeded`
can patch (recompute chunk sizes from the file length).

### New file: `leanring-buddy/PaceMeetingTurnSegmenter.swift` (~200 lines)

Pure function over two tracks. No I/O, no async — unit-testable in
isolation. Uses Accelerate `vDSP_rmsqv` over 20 ms windows with a
hysteresis state machine (silence threshold 0.01, speech threshold
0.04, min turn 600 ms, max silence gap 400 ms to merge adjacent
speech). Echo trimming: when both tracks exceed the speech threshold
in the same window, the louder track wins and the other is marked
silent for that window.

```swift
nonisolated enum PaceMeetingTurnSegmenter {
    static func segment(mic: PaceMeetingAudioTrack?,
                        system: PaceMeetingAudioTrack?,
                        now: Date) -> [PaceMeetingTurn]
}

struct PaceMeetingTurn: Equatable {
    let start: Date
    let end: Date
    let track: PaceMeetingAudioTrackKind  // .mic (you) / .system (them)
    let attributedSpeaker: String  // "you" / "them" for v1
    let sampleRange: Range<Int>    // into the owning track's buffer
}
```

### Modify: `leanring-buddy/PaceAudioFileTranscriber.swift`

Add a second entry point that returns timestamped segments instead of
one concatenated string. The existing `transcribeAudioFile(at:)` stays
for the App Intent path (drag-drop result text wants plain text).

```swift
struct PaceTranscriptionSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

static func transcribeAudioFileSegmented(at fileURL: URL) async throws -> [PaceTranscriptionSegment]
```

WhisperKit already returns segments — `transcribeWithWhisperKit` joins
them today; the new path returns them directly. Apple Speech fallback
returns a single segment spanning the whole file (it has no segment
API), so segmented callers degrade to one block on the fallback path.
Document this in the doc comment.

### New file: `leanring-buddy/PaceMeetingNotesBuilder.swift` (~220 lines)

Drives the planner to produce structured notes from the transcript.
Pure-ish: takes a transcript + the active `BuddyPlannerClient`, returns
a `PaceMeetingNotes` value. Parses the planner's JSON response with a
lenient decoder (unknown fields ignored, missing action items → empty
array, not a crash). On planner failure, returns the raw transcript as
the "summary" with `synthesisFailed: true` so the artifact is still
saved and recallable.

```swift
struct PaceMeetingNotes: Equatable, Codable {
    let meetingID: UUID
    let startedAt: Date
    let endedAt: Date
    let title: String  // user-supplied or "Meeting <time>"
    let transcript: String  // full joined, post-dictation-cleanup
    let turns: [PaceMeetingTurnRecord]  // for the transcript view
    let summary: String
    let actionItems: [PaceMeetingActionItem]
    let decisions: [String]
    let synthesisFailed: Bool
}
```

The `PaceMeetingNotesPrompt` is a new constant in
`CompanionSystemPrompt`-adjacent territory — focused, JSON-only, no
persona prose. Keeps the meeting-notes planner call cheap and
schema-stable.

### New file: `leanring-buddy/PaceMeetingNotesJournal.swift` (~180 lines)

Mirrors `PaceScreenWatchJournal`'s shape: one retrieval document per
meeting, source `.meetingNotes`, persisted via the existing
`PaceRetrievalStore`. Document text is the summary + action items +
decisions rendered as natural language so BM25 lexical retrieval can
match "what did we decide" / "action items from standup". Retention:
30 days (longer than the 7-day watch journal — meeting decisions are
referenced weeks later).

### Modify: `leanring-buddy/PaceLocalRetrieval.swift`

- Add `case meetingNotes` to `PaceRetrievalSource` + its `displayName`.
- Add `recordMeetingNotes(_ notes: PaceMeetingNotes)` on
  `PaceLocalRetriever` mirroring `recordScreenWatchObservation`:
  rehydrates the journal lazily, records, upserts the changed document.
- Rehydration helper `rehydratedMeetingNotesJournal(now:)` mirroring
  the screen-watch one.

### Modify: `leanring-buddy/PaceMeetingModeController.swift` (in `PaceSystemAudioCapture.swift`)

`start()` now also creates a `PaceMeetingAudioRecorder` and starts mic
capture. `stop()` now: stops the recorder, runs the segmenter over the
two tracks, slices each turn's audio to a temp file, calls
`PaceAudioFileTranscriber.transcribeAudioFileSegmented` per turn (or
one call over the joined track if segmentation yielded a single turn),
joins into a `PaceMeetingNotes.transcript`, runs
`PaceDictationPostProcessor`, calls `PaceMeetingNotesBuilder.build`,
and journals via `PaceLocalRetriever.recordMeetingNotes`. State
machine gains `.transcribing` / `.synthesizing` so the panel can show
progress. On any failure, the recording files are still saved and a
`PaceFailureNarrator`-style message is shown.

### Modify: `leanring-buddy/CompanionManager.swift`

- Hold a `meetingNotesJournal` reference (lazy, like
  `screenWatchJournal`).
- Wire `PaceMeetingModeController.shared` to call back into the
  retriever for journaling (the controller is `@MainActor` singleton
  today; pass the retriever in via a setter to avoid an init cycle).

### Modify: `leanring-buddy/PaceUserPreferencesStore.swift`

New keys:
- `meetingNotesRetentionDays` (Int, default 30)
- `meetingNotesTranscriptionBackend` (String: "whisperkit" / "apple",
  default "whisperkit" — lets users force Apple Speech if WhisperKit
  isn't installed)

### Modify: `leanring-buddy/CompanionPanelView.swift`

When meeting mode is active, render a meeting card showing: state
(recording / transcribing / synthesizing), elapsed time, and a
live RMS meter (reuse the existing `audioLevelPublisher`). After
stop, render the notes (summary, action items, decisions) with a
"copy" button and a "save title" field. The card dismisses on next
turn start.

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

New "Meeting notes" subsection under the General tab:
- Retention days stepper.
- Transcription backend picker.
- A "repair crashed recordings" button (calls
  `PaceMeetingAudioRecorder.crashRepairIfNeeded`).
- Per-source enable toggle for the `meetingNotes` retrieval source
  (reuses the existing per-source toggle pattern).

### Modify: `leanring-buddy/PaceRestraintGate.swift`

Add `PaceProactiveSource.meetingNotesSynthesis` so the planner call
for notes synthesis is gated the same way other proactive planner
calls are (stays quiet during an active call — though if a meeting
just ended, the user probably isn't in one; still, cheap correctness).

## Acceptance criteria

- [ ] All existing tests still pass (`bash scripts/test-pace.sh` green).
- [ ] New `PaceMeetingTurnSegmenterTests` cover: mic-only (solo
      dictation → all turns attributed "you"), system-only, both
      tracks with overlapping energy (echo trimming picks louder
      track), pure silence → zero turns, single long utterance →
      one turn, hysteresis merges a 200 ms silence gap inside speech.
- [ ] New `PaceMeetingAudioRecorderTests` cover: atomic rename on
      clean stop (`.part` → final), `crashRepairIfNeeded` patches a
      truncated RIFF header to a playable file, silent mic track is
      still written (so the user can verify their mic was muted).
- [ ] New `PaceAudioFileTranscriberSegmentedTests` cover: WhisperKit
      path returns multi-segment, Apple Speech fallback returns a
      single segment spanning the file, empty audio → empty array
      (not a crash).
- [ ] New `PaceMeetingNotesBuilderTests` cover: well-formed planner
      JSON → populated notes, malformed JSON → `synthesisFailed: true`
      with transcript preserved, planner-throws → same, empty
      transcript → empty notes (no planner call).
- [ ] New `PaceMeetingNotesJournalTests` cover: record → document
      upserted with `.meetingNotes` source, rehydration across a
      simulated restart, 30-day retention pruning, disabled source →
      no-op.
- [ ] End-to-end smoke (gated by `PACE_ENABLE_SMOKE_HOOKS=1`): start
      meeting → play a 5 s tone into mic + system → stop → notes
      artifact exists on disk + retrieval document exists + panel
      card renders.
- [ ] "what did we decide in the standup" queried against the
      retriever post-meeting returns the meeting notes document in
      the top results.
- [ ] No network calls during the entire flow (verify via
      `PaceAPIAuditLog` — zero off-device entries for a meeting
      session, since the planner is local and STT is local).
- [ ] Default state: meeting mode still defaults to OFF; the existing
      `isMeetingModeEnabled` toggle now actually does something
      useful instead of publishing RMS into the void.

## Risks

- **WhisperKit not installed.** Mitigated by the Apple Speech fallback
  in `PaceAudioFileTranscriber` (already wired) + the new backend
  preference key. The first-run experience should detect a missing
  WhisperKit model and surface a one-line "install WhisperKit for
  better meeting transcripts" hint in the panel card, not block.
- **Long meetings exceed memory.** Two tracks of Float32 at 48 kHz ×
  1 hour ≈ 700 MB in RAM. Mitigated by streaming to disk during
  capture (the recorder writes incrementally; the in-memory buffer
  is only for segmentation, and segmentation can run on the disk file
  in a second pass if RAM pressure rises — note this as a v1.1
  optimization, v1 keeps it in RAM and documents the 1-hour soft cap
  in the panel).
- **Planner offline.** Mitigated by `synthesisFailed: true` — the
  transcript is still saved and recallable; the user gets the raw
  transcript as the "summary" with a clear "notes synthesis failed,
  transcript saved" message. No silent fallback, per the existing
  planner posture.
- **Screen Recording TCC revoked mid-meeting.** The SCStream stops;
  the mic track continues. The meeting saves with system track
  truncated and a narrator message. The mic-only portion is still
  useful (the user's own notes).
- **Echo from Pace's own TTS.** Mitigated by echo trimming (Pace's
  TTS plays through the system track; the mic track's energy in those
  windows is suppressed) AND by the existing
  `excludesCurrentProcessAudio = true` on the SCStream config, which
  already drops Pace's audio from the system capture. Defense in
  depth.

## ADR candidate (capture approach)

**Decision:** keep Pace's in-process `SCStream` for system audio
capture; do NOT adopt os-june's out-of-process CoreAudio-tap helper
(their ADR-0004).

**3-part test:**
- Hard-to-reverse? No — both are replaceable, but the in-process path
  is one app, one target, one TCC prompt. Switching later is a
  contained change.
- Surprising? Mildly — the tradeoff is Screen-Recording TCC (in-process
  SCStream) vs a separate audio entitlement (out-of-process tap). The
  Screen-Recording TCC is the same permission Pace already needs for
  watch mode and screen context, so it's free for the user.
- Real trade-off? Yes — out-of-process is more robust to Pace crashes
  (audio keeps recording) but adds a helper app + XPC + a second
  entitlement. For one menu-bar app, not worth it in v1.

**Verdict:** document in `docs/architecture/decisions/0001-meeting-audio-capture.md`
(created as part of this PRD's implementation) and revisit if Pace
adds a separate recording helper for other reasons.

## Effort estimate

~1100 lines incl. tests. Two Sonnet passes: (1) capture + segmenter +
transcriber extension + their tests, (2) notes builder + journal +
panel/settings UI + retrieval wiring + their tests. The segmenter and
notes builder are pure and can be developed/tested first for fast
feedback.

## Implementation order (for the agent)

1. `PaceMeetingTurnSegmenter.swift` + tests (pure, fast feedback).
2. `PaceMeetingAudioRecorder.swift` + tests (disk I/O, RIFF repair).
3. `PaceAudioFileTranscriber.transcribeAudioFileSegmented` + tests.
4. `PaceMeetingNotesBuilder.swift` + tests (uses a mock planner).
5. `PaceMeetingNotesJournal.swift` + tests.
6. `PaceRetrievalSource.meetingNotes` + `PaceLocalRetriever.recordMeetingNotes`.
7. `PaceMeetingModeController` wiring (start/stop → recorder →
   segmenter → transcriber → notes builder → journal).
8. `CompanionManager` retriever wiring.
9. `PaceUserPreferencesStore` keys.
10. `PaceRestraintGate` source enum extension.
11. Panel meeting card UI.
12. Settings meeting-notes subsection.
13. `docs/architecture/decisions/0001-meeting-audio-capture.md`.
14. AGENTS.md update: add the new files to `docs/development/key-files.md`, note
    meeting notes in the architecture section's capabilities list,
    update the "meeting mode is a stub" wording (it won't be anymore).
15. Run `bash scripts/test-pace.sh` — must end green.
16. Commit with the standard format. **Do not run release-pace.sh.**

Where in code: `leanring-buddy/PaceMeetingTurnSegmenter.swift` (pure
Accelerate-based turn segmentation), `leanring-buddy/PaceMeetingAudioRecorder.swift`
(two-track capture + RIFF writer), and `leanring-buddy/PaceMeetingNotesBuilder.swift`
(planner-driven structured notes synthesis).
