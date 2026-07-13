## ADDED Requirements

### Requirement: Companion runtime has explicit states
The system SHALL expose `off`, `starting`, `observing`, `interpreting`, `paused`, `degraded`, and `privacy-blocked` runtime states and SHALL make state transitions deterministic and observable.

#### Scenario: User pauses companion mode
- **WHEN** the user pauses companion mode from any active state
- **THEN** the runtime enters `paused`, cancels capture and analysis tasks, and suppresses queued interventions

### Requirement: Every event receives an intervention decision
The system SHALL choose exactly one outcome for a policy-relevant event: remember silently, show silently, queue until idle, ask a clarifying question, speak now, or discard.

#### Scenario: Low-value event is remembered silently
- **WHEN** an event is credible enough for memory but does not exceed usefulness and urgency thresholds
- **THEN** the system updates memory without showing or speaking an intervention

#### Scenario: Ambiguous useful event needs clarification
- **WHEN** an event may be useful but acting on its interpretation would create a misleading memory
- **THEN** the system asks a concise clarifying question only when restraint policy permits

### Requirement: Spoken interventions pass the restraint gate
The system MUST route every companion-initiated spoken intervention through `PaceRestraintGate` using current call, Focus, input, cooldown, confidence, and proactivity-profile context.

#### Scenario: User is on an active call
- **WHEN** an otherwise speakable non-urgent intervention occurs during an active call
- **THEN** the system stays silent and either queues or discards it according to its expiry policy

### Requirement: Intervention policy resists repetition
The system SHALL coalesce equivalent candidates, enforce category and global cooldowns, and incorporate explicit negative feedback into future thresholds.

#### Scenario: Equivalent changes repeat
- **WHEN** multiple observations would produce materially equivalent interventions during the cooldown window
- **THEN** the system emits at most one intervention and retains only any meaningful state update
