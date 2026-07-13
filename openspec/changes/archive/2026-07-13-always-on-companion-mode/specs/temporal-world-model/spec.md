## ADDED Requirements

### Requirement: World observations are typed and provenance-bearing
The system SHALL store accepted observations with an identifier, timestamp, source, subject, predicate, value, optional location, confidence, evidence reference, and optional expiry.

#### Scenario: Object location is observed
- **WHEN** perception accepts an observation that a tracked object is in a named zone
- **THEN** the observation log records the location claim and its supporting source, time, confidence, and evidence reference

### Requirement: Current state remains linked to evidence
The system SHALL derive current world-state hypotheses from observations and SHALL retain the identifiers of supporting and contradicting observations.

#### Scenario: A newer location supersedes an older location
- **WHEN** a higher-confidence observation places an object in a different zone
- **THEN** the current state points to the newer location while the older observation remains available as history

#### Scenario: Evidence is insufficient
- **WHEN** all supporting observations are expired, contradicted, or below confidence threshold
- **THEN** the system reports the current state as unknown instead of presenting a stale location as fact

### Requirement: Spatial state uses coarse user-comprehensible zones
The system SHALL model locations as a source plus a user-comprehensible zone or screen/display label and MUST NOT require metric 3D mapping.

#### Scenario: Last-seen query
- **WHEN** the user asks where an object was last seen
- **THEN** the system returns the latest supported zone, observation time, and confidence or states that no reliable observation exists

### Requirement: Corrections supersede rather than erase evidence
The system SHALL record user corrections as high-confidence observations linked to the claims they supersede.

#### Scenario: User corrects an object location
- **WHEN** the user says that the inferred object location is wrong and supplies the correct location
- **THEN** the current state adopts the correction and preserves the earlier claim as superseded history
