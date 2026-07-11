# Screen & vision

How Pace sees the screen: cheap pixel diffing to know *when* to look, a local
VLM to know *what's* there, OCR/AX to ground text and structure, and a
click-recovery loop for when a guess misses. Foundational frameworks
(ScreenCaptureKit, the speculative planner race) are covered in
[`new-things.md`](new-things.md) and referenced here, not re-explained.

---

## Screen image diffing
- What: A low-res grayscale fingerprint plus pixel-delta comparison that decides whether two screenshots differ "meaningfully" rather than pixel-identically.
- Why here: The cheap pre-filter behind watch mode and the prewarm cache — avoids re-running the VLM or emitting an event for a blinking cursor or a clock tick.
- Where: `PaceScreenImageDiffer.swift` — `PaceScreenImageDiffer.fingerprint(...)` and `.diff(...)`, producing a `PaceScreenVisualFingerprint` / `PaceScreenImageDiff`.
- Source: internal — no external spec.

## Watch mode
- What: An explicit watch-loop primitive that samples full-screen captures on an interval and emits typed events only past a diff threshold.
- Why here: Powers "watch my screen" — `PaceScreenWatchModeController.startWatching(onMeaningfulChange:)` loops `CompanionScreenCaptureUtility.captureAllScreensAsJPEG()`, runs each capture through `PaceScreenWatchChangeDetector`, and only calls back (and journals) on a real `PaceScreenWatchEvent`.
- Where: `PaceScreenWatchMode.swift` — `PaceScreenWatchModeController`, `PaceScreenWatchEventCategory` (`.majorScreenChange` / `.contentUpdate` / `.focusedRegionChange`).
- Source: internal — no external spec.

## Set-of-Mark click recovery
- What: When a coordinate click misses, render numbered marks over candidate elements and ask the model which numbered mark corresponds to the intended target, instead of re-guessing raw coordinates.
- Why here: Pace's click-miss recovery path — `PaceSetOfMarkClickRecovery.resolve(inputs:renderMarks:groundMark:)` takes the failed click's screenshot + element map, renders marks, asks the VLM to pick a mark index, and turns that back into a screen coordinate. Pure decision logic — rendering and the VLM round-trip are injected closures, so it's unit-testable without AppKit or a live model.
- Where: `PaceSetOfMarkClickRecovery.swift` — `PaceSetOfMarkClickRecovery.resolve`.
- Source: https://arxiv.org/abs/2310.11441 (Set-of-Mark Prompting Unleashes Extraordinary Visual Grounding in GPT-4V)

## Set-of-Mark renderer
- What: The drawing half of Set-of-Mark — takes a JPEG and a list of boxes, draws numbered outlines + index labels onto it.
- Why here: Separates "what to draw" from "what to decide" — `PaceSetOfMarkRenderer.drawMarks(onJPEG:boxes:)` is the pure rendering function `PaceSetOfMarkClickRecovery` injects as its `renderMarks` closure.
- Where: `PaceSetOfMarkRenderer.swift` — `PaceSetOfMarkRenderer.drawMarks(onJPEG:boxes:)`.
- Source: internal — no external spec.

## Vision OCR client
- What: A wrapper around Apple's Vision text-recognition request, run at the accurate recognition level, returning text plus bounding boxes.
- Why here: Grounds "what does that text say" / "click the button labeled X" turns in real on-screen text rather than relying on the VLM's element-map guesses alone — fully on-device, ~50-200 ms per screenshot.
- Where: `PaceVisionOCRClient.swift` — `PaceVisionOCRClient.recognizeText(...)`, built on `VNRecognizeTextRequest`.
- Source: https://developer.apple.com/documentation/vision/vnrecognizetextrequest

## OCR data detector
- What: Runs Foundation's `NSDataDetector` over OCR'd screen text to pull out typed entities — phone numbers, email addresses, URLs, dates, postal addresses.
- Why here: Turns raw OCR text into actionable entities for turns like "add this date to my calendar" or "open that link" without an LLM call to extract them — the same trick TextEdit uses for its data-detector highlights, fully on-device.
- Where: `PaceOCRDataDetector.swift` — `PaceDetectedEntity`, `PaceOCRDataDetector.detectEntities(in:)`.
- Source: https://developer.apple.com/documentation/foundation/nsdatadetector

## OCR language resolver
- What: A pure helper that intersects the user's `Locale.preferredLanguages` with Vision's supported OCR recognition languages, falling back to `en-US` if the intersection is empty.
- Why here: Without it, OCR silently mis-reads non-English UIs (umlauts, kana, etc.) because Vision defaults to `en-US`; both language lists are injected, so this stays actor-free and unit-testable without a live `Locale` or Vision request.
- Where: `PaceVisionOCRLanguageResolver.swift` — `PaceVisionOCRLanguageResolver.resolveRecognitionLanguages(preferredLanguagesFromLocale:supportedLanguagesFromVision:)`.
- Source: internal — no external spec.

## Ambient context store
- What: A permission-free snapshot of the user's current context — frontmost app name/bundle ID, window title, a lightweight AX-tree summary, and clipboard change count/timestamp.
- Why here: Cheap situational grounding the planner gets on every turn without a screenshot or VLM call — `PaceAmbientContextStore` polls `NSWorkspace.shared.frontmostApplication` plus a background AX read and publishes a `PaceAmbientContextSnapshot` that renders into the planner prompt.
- Where: `PaceAmbientContextStore.swift` — `PaceAmbientContextStore`, `PaceAmbientContextSnapshot`.
- Source: internal — no external spec.

## Screen context service
- What: The per-screen VLM analysis cache and AX+OCR+VLM coordinator, keyed by screen/display identity plus a pixel hash of the captured image.
- Why here: Avoids paying VLM latency twice for the same unchanged screen — `PaceScreenContextService.prewarmScreenContext(reason:)` kicks off analysis speculatively at push-to-talk press (`.pushToTalkPress`) and at deeplink chat (`.deepLinkChat`); a pixel-hash match against `PaceCachedScreenAnalysis` reuses the cached element map instead of re-calling the VLM.
- Where: `PaceScreenContextService.swift` — `PaceScreenContextService`, `PaceCachedScreenAnalysis`, `PaceScreenContextPrewarmReason`.
- Source: internal — no external spec.

## Local VLM element maps
- What: The client that sends a screenshot to the local VLM (LM Studio, OpenAI-compatible chat-completions) and parses back a structured element map — label, role, bounding box, and optional verbatim text per UI element.
- Why here: This is what makes screen-action turns groundable in real coordinates instead of hallucinated ones — `LocalVLMClient.analyzeScreenshot(...)` builds the vision chat-completion request, and `groundMarkedClickTarget(...)` is the same client's Set-of-Mark grounding call. Both go through the loopback-only endpoint guard, never leaving the Mac.
- Where: `LocalVLMClient.swift` — `LocalVLMClient` (conforms to `PaceScreenAnalysisClient`), `LocalVLMScreenElement`, `LocalVLMScreenAnalysis`.
- Source: internal — loopback OpenAI-compatible endpoint; see LM Studio entry in [`new-things.md`](new-things.md).

## VLM-skip heuristic
- What: A rule-based check on the transcript text that decides whether a turn is likely to reference the screen at all, before paying VLM latency.
- Why here: Pure-knowledge turns ("what's the capital of France?") don't need a screenshot — `PaceTagParsers.transcriptIsLikelyScreenReferential` gates the VLM call so those turns skip straight to the text-only planner path; `AlwaysRunLocalVLMRegardlessOfTranscript=true` overrides it for testing.
- Where: `PaceTagParsers.swift` — `PaceTagParsers.transcriptIsLikelyScreenReferential(_:)`.
- Source: internal — no external spec.

---

See also [`README.md`](README.md) for the full learning-roadmap index.
