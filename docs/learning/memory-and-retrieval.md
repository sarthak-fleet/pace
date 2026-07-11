# Memory and retrieval

How Pace remembers a conversation, remembers durable facts about the user, and
recalls both back into the planner — all on-device, no vector database, no
cloud call.

## Two-tier thread memory
- What: Every planner call carries the last K=4 turn pairs verbatim plus a rolling summary of everything older, injected as `<conversation_so_far>...</conversation_so_far>`.
- Why here: Keeps the planner's context bounded (no unbounded prompt growth over a long session) while still remembering what was said 20 turns ago.
- Where: `PaceThreadMemory.swift` — `PaceThreadMemory` (`verbatimWindow()`, `injectionPrefix()`, `record(userTurn:assistantTurn:turnId:now:)`)
- Source: internal — no external spec.

## Thread memory persistence
- What: The live `PaceThreadMemory` state (session id, summary, verbatim window) is snapshotted to a single on-device JSON file after every turn so a conversation survives quit/relaunch.
- Why here: Policy is "resume always, until reset" — Pace does not lose conversational context just because the user quit the app, but an explicit thread reset wipes it.
- Where: `PaceThreadMemoryStore.swift` — `PaceThreadMemoryStore` (`load()`/`save(_:)`/`clear()`, atomic write to `~/Library/Application Support/Pace/thread-memory.json`)
- Source: internal — no external spec.

## Rolling summary via detached Apple FM
- What: A short, detached model call folds the turn pair that just fell out of the verbatim window into an updated 4-sentence rolling summary.
- Why here: Keeps summarization off the user-facing turn entirely (target ≤300ms warm, never awaited by the reply path) while still compacting older context instead of dropping it.
- Where: `PaceThreadSummarizer.swift` — `PaceThreadFoundationModelSummarizer` (Apple FM path) and `PaceThreadSummarizerClientFactory.makeDefault()` (falls back to `PaceThreadLMStudioSummarizer` when Apple Intelligence is unavailable). See [`new-things.md`](new-things.md) → Apple FoundationModels.
- Gotcha: race-safety is a monotonic `summaryVersion` — `PaceThreadMemory.reserveNextSummaryVersion()` is captured before the detached call fires, and `applySummaryUpdate` drops any result whose version isn't newer, so out-of-order arrivals from overlapping summarizer calls can't clobber a fresher summary.
- Source: internal — no external spec.

## Episodic memory (durable facts)
- What: A small, capped (200-fact LRU) store of durable `(subject, predicate, value)` facts about the user — preferences, family/health context, work milestones — separate from the conversational thread.
- Why here: Thread memory forgets after idle/reset; episodic memory is the layer that remembers "user prefers dark mode" or "mom is in the hospital" across sessions indefinitely (until explicitly deleted).
- Where: `PaceEpisodicMemory.swift` — `PaceEpisodicFactStore` (`apply(_:)`, `PaceEpisodicFactDedupPolicy.decision`, `enforceLRUCap()`)
- Gotcha: dedup key is `(subject, predicate)` case-insensitive — a new fact on the same key either replaces the old one (recent + confidence within 0.1) or is appended alongside it (confidence gap too large to call it the same belief). Deletions leave a `PaceEpisodicTombstone` that blocks re-extraction of the same triplet for 30 days.
- Source: internal — no external spec.

## Sensitive-topic filtering
- What: Facts tagged `#health`, `#finance`, or `#relationship` are stored durably but excluded from the planner's `LOCAL CONTEXT` injection block unless the user opts in.
- Why here: Pace can recall "mom is in the hospital" when the user asks directly, without silently re-surfacing sensitive facts into every unrelated planner turn.
- Where: `PaceEpisodicMemory.swift` — `PaceEpisodicSensitiveTopics` (`isFactSensitive(_:)`, `sensitiveTopicHashtags`), consumed by `PaceEpisodicFactStore.factsForInjection(includeSensitiveTopics:)`
- Source: internal — no external spec.

## Episodic fact extraction
- What: After each turn, a detached call structures the transcript into typed `(subject, predicate, value, confidence, topicHashtags)` facts — Apple FM first, LM Studio fallback, with a no-model deterministic keyword extractor for the small set of high-confidence patterns that don't need a model call at all.
- Why here: Fire-and-forget by design — extraction latency/failure never touches the spoken reply path, and only facts at confidence ≥0.7 are kept.
- Where: `PaceEpisodicFactExtractor.swift` — `PaceEpisodicFoundationModelFactExtractor` / `PaceEpisodicLMStudioFactExtractor`, chosen by `PaceEpisodicFactExtractorFactory.makeDefault()`; the no-model path is `PaceEpisodicPatternFactExtractor` in `PaceEpisodicMemory.swift`.
- Source: internal — no external spec.

## Local retrieval across sources
- What: A single BM25-style lexical index scores candidates across every retrieval source Pace knows about — 14 typed `PaceRetrievalSource` cases (files, mail, notes, calendar, reminders, contacts, paceHistory, screen-watch/app-usage journals, episodic memory, meeting notes, and more).
- Why here: The one recall path behind "what did I do today?", "what did we decide in standup?", and similar questions — instant, embedding-free, and the production ranking path today.
- Where: `PaceLocalRetrieval.swift` — `PaceRetrievalSource` (14 cases), `PaceInMemoryRetrievalStore.bm25Score(...)`. See [`new-things.md`](new-things.md) → BM25.
- Source: internal — no external spec (BM25 itself is external, see pointer above).

## Embedding rerank (optional second pass)
- What: An optional semantic re-ranking pass over the BM25 candidates using a local embedding model served at LM Studio's `/v1/embeddings`, blended 50/50 with the lexical score.
- Why here: Catches paraphrases the lexical scorer misses ("standup notes" vs. "daily sync") without ever making retrieval worse — any embedding failure (endpoint down, model missing, decode error) returns the lexical order unchanged.
- Where: `PaceEmbeddingReranker.swift` — `PaceEmbeddingReranker.rerank(queryText:matches:embedder:)`, `LMStudioEmbeddingClient`
- Source: internal — no external spec.

## Lazy embedding scheduler
- What: A small off-hot-path scheduler that computes embeddings for newly written memory entries in a detached task and writes them back into the index asynchronously.
- Why here: Every memory write site (thread turns, episodic facts, journal entries) needs its text embedded eventually for reranking, but the user-facing turn must never wait on an embedding call — a failed embed just leaves the entry BM25-only.
- Where: `PaceLazyEmbeddingScheduler.swift` — `PaceLazyEmbeddingScheduler.schedule(_:)`
- Source: internal — no external spec.

## CoreSpotlight memory mirror
- What: A one-way mirror of active Pace memory entries into the system CoreSpotlight index, so memories surface from Cmd+Space and other Spotlight-backed system search.
- Why here: Lets a user find something Pace remembered ("dark mode preference") from ordinary macOS search, without adding any new storage — Spotlight gets exactly what's already on disk, and a memory reset wipes both the source JSON and the mirror together.
- Where: `PaceSpotlightMemoryIndexer.swift` — `PaceSpotlightMemoryIndexer` (`syncMirror(toMatch:)`, `deleteAllMirroredItems()`)
- Source: https://developer.apple.com/documentation/corespotlight

## See also

[`README.md`](README.md)
