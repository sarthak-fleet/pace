## ADDED Requirements

### Requirement: Companion mode is explicit and default off
The system MUST default Always-On Companion Mode and every new sensitive perception source to disabled and MUST NOT enable either through migration.

#### Scenario: Existing user upgrades
- **WHEN** an existing installation first runs a version containing companion mode
- **THEN** companion mode remains off until the user explicitly enables it

### Requirement: Active sources are continuously visible
The system SHALL show companion runtime state, active sources, last observation time, and a persistent visual indicator while camera, microphone, or screen sampling is active.

#### Scenario: Camera sampling begins
- **WHEN** the camera perception source starts sampling
- **THEN** the menu-bar and companion settings surfaces visibly indicate camera activity until sampling stops

#### Scenario: Ambient voice gate begins
- **WHEN** the enabled microphone source starts local VAD/wake processing
- **THEN** the menu-bar and companion settings surfaces visibly indicate microphone activity until it stops

### Requirement: Companion processing remains local-only
The system MUST route companion interpretation through guarded loopback or in-process clients, MUST NOT use a selected cloud planner tier, and MUST fail closed when a local endpoint is invalid.

#### Scenario: User selected a cloud conversational tier
- **WHEN** companion mode needs model interpretation while the normal planner tier is off-device
- **THEN** the system uses the privacy-pinned local planner/VLM path or records a local-model-unavailable degraded state without sending data off the Mac

### Requirement: Raw sensor data has a bounded lifetime
The system MUST keep raw screen frames, camera frames, and pre-wake audio in bounded memory only for gating/extraction, MUST NOT persist them by default, and SHALL expose retention and storage usage for structured observations.

#### Scenario: Observation extraction completes
- **WHEN** a raw frame has been processed and is no longer required by the bounded buffer
- **THEN** the system releases the frame while retaining only the permitted structured observation and evidence metadata

### Requirement: Users control and clear each data source
The system SHALL provide source-level enable, pause, retention, clear, and diagnostic status controls and SHALL allow clearing all companion memory.

#### Scenario: User clears camera-derived memory
- **WHEN** the user clears the camera source from companion memory settings
- **THEN** persisted camera-derived observations, derived state, retrieval documents, and queued interventions are removed

### Requirement: Companion mode obeys resource budgets
The system SHALL enforce sampling, concurrent-analysis, battery, memory, and thermal limits and SHALL enter a visible degraded mode when a limit disables an expensive stage. Local VAD/wake gating SHALL remain independent from VLM availability.

#### Scenario: Thermal pressure becomes critical
- **WHEN** the system reaches the configured critical thermal state
- **THEN** camera and VLM analysis suspend, cheap event sources may continue, and the UI reports thermal degradation
