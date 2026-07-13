# ambient-perception Specification

## Purpose
Define privacy-bounded, event-driven collection and staged local interpretation for separately enabled companion sensors.
## Requirements
### Requirement: Companion perception is event-driven and staged
The system SHALL collect enabled sensor signals while companion mode is observing, SHALL gate camera and screen frames by meaningful change or motion, SHALL gate microphone input through local VAD/wake detection, and SHALL invoke STT, OCR, tracking, or a local VLM only for accepted candidates.

#### Scenario: Unchanged screen does not invoke expensive analysis
- **WHEN** consecutive screen fingerprints remain below the meaningful-change threshold
- **THEN** the system updates no visual observation and does not invoke OCR or the VLM

#### Scenario: Meaningful screen change produces a candidate
- **WHEN** a screen diff crosses the configured threshold and the source is enabled
- **THEN** the system emits a typed observation candidate containing the source, timestamp, change category, and evidence reference

### Requirement: Perception sources are independently controlled
The system SHALL support independent lifecycle and permission state for camera perception, ambient voice, screen perception, and macOS context sources.

#### Scenario: Camera is unavailable
- **WHEN** camera perception is enabled but permission or hardware is unavailable
- **THEN** camera perception enters a degraded state while enabled desktop sources continue operating

#### Scenario: Source is disabled
- **WHEN** the user disables a perception source
- **THEN** the system cancels its capture task, discards pending source work, and creates no new observations from that source

### Requirement: Ambient voice is gated before transcription
The system MUST run VAD and wake detection locally, MUST begin transcription only after a wake phrase or active conversational session, and MUST NOT persist or transcribe pre-wake ambient audio.

#### Scenario: Background conversation does not address Pace
- **WHEN** speech is detected but no wake phrase or active companion session exists
- **THEN** the system performs no STT, stores no transcript, and starts no assistant turn

#### Scenario: User wakes Pace
- **WHEN** the local wake gate accepts the configured wake phrase
- **THEN** the system begins a bounded conversational session and routes subsequent speech through on-device STT

### Requirement: Session diarization is non-identifying
The system MAY separate speakers during an active conversational session using ephemeral labels and MUST NOT infer or persist speaker identity.

#### Scenario: Two speakers participate after wake
- **WHEN** local diarization detects multiple speakers during an active session
- **THEN** the transcript uses ephemeral speaker labels that expire with the session

### Requirement: Person perception is non-identifying by default
The system MUST represent detected people as presence events or local ephemeral track identifiers and MUST NOT infer or persist identity.

#### Scenario: Person enters a camera zone
- **WHEN** the enabled camera source detects a new person track entering a configured zone
- **THEN** the system records a non-identifying presence observation with time, zone, and confidence

### Requirement: Perception applies backpressure
The system SHALL allow at most one expensive interpretation task per source, SHALL coalesce newer equivalent candidates, and SHALL discard stale low-priority work.

#### Scenario: Changes arrive during VLM analysis
- **WHEN** multiple equivalent visual changes arrive while a source has an in-flight VLM request
- **THEN** the system retains only the newest relevant candidate for subsequent analysis
