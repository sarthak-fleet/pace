# Audio pipeline

How Pace hears and speaks — capture, streaming synthesis, interruption, and
the two-track meeting recorder. The ASR/TTS *models* live in
[`new-things.md`](new-things.md) (WhisperKit, Kokoro/mlx-audio); this page is
the plumbing around them.

## Push-to-talk via CGEvent tap
- What: A listen-only `CGEvent` tap that detects the ctrl+option push-to-talk chord system-wide, even when Pace has no focus.
- Why here: An AppKit global monitor misses modifier-only combos while backgrounded; the low-level event tap catches the press reliably so hold-to-talk always works.
- Where: `GlobalPushToTalkShortcutMonitor.swift` — `GlobalPushToTalkShortcutMonitor` (the notch chat shortcut mirrors it in `GlobalChatShortcutMonitor.swift`).
- Source: https://developer.apple.com/documentation/coregraphics/cgevent/1454426-tapcreate

## Streaming sentence TTS pipeline
- What: Consumes the planner's token stream, cuts it at sentence boundaries, and queues each finished sentence to TTS while later sentences are still generating.
- Why here: The core sub-500 ms TTFSW trick — speech starts on sentence 1 while the planner is still writing sentence 2; sentence N+1 is synthesized while N plays.
- Where: `StreamingSentenceTTSPipeline.swift` — `StreamingSentenceTTSPipeline`.
- Source: internal — no external spec.

## Barge-in VAD
- What: Detects the user talking over the assistant using an RMS energy threshold plus echo suppression (a grace window and a raised threshold while TTS is playing).
- Why here: Lets you interrupt Pace mid-reply without the assistant's own TTS bleed tripping a false interruption.
- Where: `PaceBargeInVAD.swift` — `PaceBargeInVAD` / `PaceBargeInVADConfiguration`.
- Source: internal — no external spec.

## Wake word spotter
- What: Always-listening keyword spot via Apple `SFSpeechRecognizer` with `requiresOnDeviceRecognition=true` (ANE-backed), pausing during push-to-talk and honoring low-power / screen-sleep.
- Why here: Opt-in hands-free trigger that persists nothing to disk — the on-device recognizer is the same one used for dictation, so no extra model ships.
- Where: `PaceAppleSpeechWakeWordSpotter.swift` — `PaceAppleSpeechWakeWordSpotter` (behind `PaceWakeWordSpotterProtocol`).
- Source: https://developer.apple.com/documentation/speech/sfspeechrecognizer

## Two-track meeting capture
- What: Records mic (AVAudioEngine tap) and system audio (ScreenCaptureKit SCStream, excluding Pace's own process) as two separate mono WAV tracks with per-track start offsets.
- Why here: Separate tracks give clean speaker attribution ("you" vs "them") for on-device meeting notes — better than one mixed track, and it excludes Pace's own TTS to avoid self-capture.
- Where: `PaceSystemAudioCapture.swift` — `PaceMeetingModeController`; `PaceMeetingAudioRecorder.swift` — `PaceMeetingAudioRecorder`. ScreenCaptureKit itself → see [`new-things.md`](new-things.md).
- Source: internal (built on ScreenCaptureKit + AVAudioEngine).

## Off-main-actor track writer (FIFO)
- What: A per-track `AsyncStream` fed by the capture callbacks and drained by a single detached consumer that does the Float32→PCM16 conversion and `FileHandle` writes off the main actor, in exactly the produced order.
- Why here: Replaces per-buffer `Task { @MainActor }` hops that had no ordering guarantee (buffers could interleave in the WAV) and ran disk I/O on the main thread; the single-consumer stream makes ordering correct by construction.
- Where: `PaceMeetingAudioRecorder.swift` — `MeetingTrackWriter` / `MeetingTrackFinalState`; the mic conversion is boxed in `MicSampleConverter`.
- Source: internal — no external spec. (Swift concurrency idioms → [`infra-and-patterns.md`](infra-and-patterns.md).)

## Meeting turn segmentation
- What: Splits the two tracks into attributed turns using per-window RMS (Accelerate), hysteresis on speech/silence thresholds, and echo trimming when both tracks fire at once.
- Why here: Turns are the unit the meeting-notes builder summarizes; hysteresis prevents a single pause from shattering one utterance into many fragments.
- Where: `PaceMeetingTurnSegmenter.swift` — `PaceMeetingTurnSegmenter`, `PaceMeetingTurn`, `PaceMeetingAudioTrack`.
- Source: https://developer.apple.com/documentation/accelerate (RMS math); hysteresis + echo-trim are internal.

## Segmented audio-file transcription
- What: Transcribes each meeting turn on-device via WhisperKit for long audio, falling back to Apple Speech (which caps ~1 minute) per segment.
- Why here: Meetings routinely exceed Apple Speech's limit, so WhisperKit handles the bulk while Apple Speech guarantees a result on any Mac.
- Where: `PaceAudioFileTranscriber.swift` — `PaceAudioFileTranscriber.transcribeAudioFileSegmented`. WhisperKit itself → see [`new-things.md`](new-things.md).
- Source: internal (orchestration over WhisperKit + Apple Speech).

## RIFF-header crash repair
- What: Recording files are written as `.part` with a placeholder WAV header, patched with real chunk sizes and atomically renamed on clean stop; a launch-time sweep repairs any `.part` left by a crash.
- Why here: A force-quit mid-meeting would otherwise leave an unplayable file with a zero-length header — the repair sweep recovers the audio instead of losing it.
- Where: `PaceMeetingAudioRecorder.swift` — `crashRepairAllMeetingRecordings()`, `repairRIFFPartFile(...)`, `riffHeaderPlaceholder(...)`.
- Source: https://en.wikipedia.org/wiki/WAV (RIFF/WAVE container).

See also: [`README.md`](README.md).
