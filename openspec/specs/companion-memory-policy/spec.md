# companion-memory-policy Specification

## Purpose
Define deterministic, provenance-preserving promotion, correction, retention, retrieval, and forgetting for companion observations.
## Requirements
### Requirement: Memory promotion is deterministic and auditable
The system SHALL apply explicit rules to promote observations into episodic, semantic, spatial, or routine memory and SHALL retain the observation identifiers supporting each promoted memory.

#### Scenario: One observation does not become a routine
- **WHEN** an activity or location pattern has only one supporting observation
- **THEN** the system may retain an episode but does not promote the pattern to routine memory

#### Scenario: User confirms a durable fact
- **WHEN** the user explicitly confirms a preference or durable fact
- **THEN** the system promotes it to semantic memory with the confirmation observation as provenance

### Requirement: Memory confidence changes over time
The system SHALL decay unsupported spatial and routine confidence, SHALL increase confidence from repeated consistent evidence, and SHALL reduce confidence from contradictions.

#### Scenario: Last-seen location becomes stale
- **WHEN** a spatial memory receives no confirming observation within its configured freshness window
- **THEN** retrieval labels it stale or uncertain rather than current fact

### Requirement: Memory is compressed and bounded
The system SHALL enforce per-memory-type retention and size limits and SHALL compact repetitive low-value episodes without losing the time range and provenance summary.

#### Scenario: Episode bucket exceeds its limit
- **WHEN** an episodic bucket exceeds its configured entry limit
- **THEN** the system compacts or expires the lowest-value entries and remains within the storage bound

### Requirement: Memory can be retrieved by time, entity, and place
The system SHALL support retrieval constrained by time range, subject/entity, location, and memory type and SHALL return confidence and provenance with results.

#### Scenario: User asks what changed since morning
- **WHEN** the user asks for changes since a specified time
- **THEN** the system returns relevant episodic changes in chronological order with source times and uncertainty

### Requirement: Users can correct and forget memories
The system SHALL support correction, deletion of an individual memory, clearing a memory type or source, and disabling future promotion for a source.

#### Scenario: User forgets a spatial memory
- **WHEN** the user deletes an object's stored location history
- **THEN** the system removes the derived state and supporting persisted spatial records and does not expose them in future retrieval
