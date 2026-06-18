//
//  PaceLazyEmbeddingScheduler.swift
//  leanring-buddy
//
//  Off-hot-path embedding scheduler extracted from CompanionManager
//  during the post-Wave-7b chip-away. Owns the "given a set of newly
//  upserted entries, compute their embeddings in a detached task and
//  write them back into the index" lifecycle in one place.
//
//  Why a separate file: every memory write site previously called
//  CompanionManager.scheduleLazyEmbedding(_:), which had captured
//  three of the manager's main-actor properties (memoryIndex,
//  persist callback, embedding-client factory) plus the detached-
//  task plumbing. Moving it out collapses a ~25-line block into one
//  call site per write site AND gives us a unit-test seam (the
//  scheduler now takes its dependencies via init rather than
//  closing over them).
//
//  Best-effort: any embedding failure leaves entries nil-embedded.
//  The unified retriever already falls through to BM25 on missing
//  embeddings, so a failed lazy-embed downgrades recall quality
//  rather than breaking it.
//

import Foundation

@MainActor
final class PaceLazyEmbeddingScheduler {

    private let memoryIndex: PaceMemoryIndex
    private let embeddingClientFactory: () -> any PaceTextEmbedding
    private let onEmbeddingsPersisted: () -> Void

    init(
        memoryIndex: PaceMemoryIndex,
        embeddingClientFactory: @escaping () -> any PaceTextEmbedding,
        onEmbeddingsPersisted: @escaping () -> Void
    ) {
        self.memoryIndex = memoryIndex
        self.embeddingClientFactory = embeddingClientFactory
        self.onEmbeddingsPersisted = onEmbeddingsPersisted
    }

    /// Compute embeddings for the given entries off the hot path.
    /// Returns immediately — the detached task does the work and
    /// writes its result back to the index when ready. The user-
    /// facing turn never waits on this.
    func schedule(_ entryIdsAndTexts: [(id: String, text: String)]) {
        guard !entryIdsAndTexts.isEmpty else { return }
        let entryIds = entryIdsAndTexts.map { $0.id }
        let entryTexts = entryIdsAndTexts.map { $0.text }
        let memoryIndexReference = memoryIndex
        let onPersistCallback = onEmbeddingsPersisted
        let clientFactory = embeddingClientFactory
        Task.detached(priority: .utility) {
            let embeddingClient = clientFactory()
            guard
                let embeddingVectors = try? await embeddingClient.embed(entryTexts),
                embeddingVectors.count == entryIds.count
            else {
                return
            }
            await MainActor.run {
                for (entryId, embeddingVector) in zip(entryIds, embeddingVectors) {
                    memoryIndexReference.setEmbedding(embeddingVector, forEntryId: entryId)
                }
                onPersistCallback()
            }
        }
    }
}
