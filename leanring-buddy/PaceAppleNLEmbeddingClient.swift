//
//  PaceAppleNLEmbeddingClient.swift
//  leanring-buddy
//
//  `PaceTextEmbedding` conformer backed by Apple's NaturalLanguage
//  framework (`NLEmbedding.sentenceEmbedding(for:)`). 300-dim, fully
//  on-device, no LM Studio dependency, no network.
//
//  Quality is lower than nomic-embed-text-v1.5 (see
//  scripts/eval-locomo-recall.py for the gap), but auge's lesson
//  applies: a free always-on baseline is worth the recall hit when
//  it eliminates a sidecar dependency. Wired via
//  `PaceChainedTextEmbeddingClient` so LM Studio (when up) still
//  wins; Apple NL only fires when LM Studio is unreachable.
//
//  Lazy-loaded — `NLEmbedding.sentenceEmbedding(for: .english)`
//  costs a couple hundred milliseconds on first call (model load
//  from disk) and we don't want that on app launch. Cached on a
//  serial actor-isolated property so we pay the load exactly once.
//

import Foundation
import NaturalLanguage

/// Apple NaturalLanguage sentence-embedding client. The embedding
/// model for `.english` ships with every Mac running macOS 12+; no
/// download, no Apple Intelligence dependency, no entitlement.
final class PaceAppleNLEmbeddingClient: PaceTextEmbedding {
    /// One sentence-embedding model per language. Keyed by the
    /// caller-requested language so the same client can serve
    /// English and German memory chunks without reloading.
    /// Access is serialised through `loadLock` since `NLEmbedding`
    /// itself is documented as thread-safe but the cache map is not.
    private var modelCache: [NLLanguage: NLEmbedding] = [:]
    private let cacheLock = NSLock()

    /// Pace's primary content language. The unified memory index
    /// today holds English-dominant content (transcripts, action
    /// summaries, journals), so we always resolve to `.english`
    /// unless the caller passes a query in a different language.
    /// We deliberately do NOT auto-detect per-string: Apple NL's
    /// language detector is slow enough to be its own latency
    /// concern at 100+ entries, and a wrong-language detection
    /// silently zeros the vector. Future work can layer detection
    /// on top once we have a measurement story for it.
    private let defaultLanguage: NLLanguage

    init(defaultLanguage: NLLanguage = .english) {
        self.defaultLanguage = defaultLanguage
    }

    /// Embed each text into a 300-dim vector. Texts whose embedding
    /// returns nil (out-of-vocabulary, model not available, empty
    /// after trim) get a zero-vector — the upstream
    /// `PaceMemoryIndex.rankBySemanticSimilarity` already drops
    /// zero-vector entries from the ranking, so this is the right
    /// way to signal "no signal here" without changing the array
    /// shape.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let embeddingModel = try loadEmbeddingModel(for: defaultLanguage)
        let vectorDimension = embeddingModel.dimension
        let zeroVector = Array(repeating: Float(0), count: vectorDimension)

        return texts.map { rawText in
            let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return zeroVector }
            guard let doubleVector = embeddingModel.vector(for: trimmedText) else {
                return zeroVector
            }
            return doubleVector.map { Float($0) }
        }
    }

    private func loadEmbeddingModel(for language: NLLanguage) throws -> NLEmbedding {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedModel = modelCache[language] {
            return cachedModel
        }
        guard let freshlyLoadedModel = NLEmbedding.sentenceEmbedding(for: language) else {
            // Some macOS minor releases ship the model lazily — at
            // some point in NL's history `.english` could return nil
            // until iCloud or a system update populated the on-disk
            // model. Throwing rather than zero-vectoring everything
            // lets `PaceChainedTextEmbeddingClient` fall back to
            // BM25 ranking instead.
            throw PaceEmbeddingClientError(
                message: "Apple NL sentence embedding for \(language.rawValue) is unavailable on this system"
            )
        }
        modelCache[language] = freshlyLoadedModel
        return freshlyLoadedModel
    }
}
