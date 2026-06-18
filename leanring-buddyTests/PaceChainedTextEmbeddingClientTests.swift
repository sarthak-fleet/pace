//
//  PaceChainedTextEmbeddingClientTests.swift
//  leanring-buddyTests
//
//  Pins the contract that semantic recall keeps working when the
//  primary embedding sidecar (LM Studio) is unreachable. Regressions
//  here silently take recall back to BM25 even on machines where
//  Apple NL would have worked.
//

import Foundation
import Testing
@testable import Pace

struct PaceChainedTextEmbeddingClientTests {

    // MARK: - Test doubles

    private struct StubEmbedding: PaceTextEmbedding {
        let vectors: [[Float]]
        let throwError: Error?

        func embed(_ texts: [String]) async throws -> [[Float]] {
            if let throwError { throw throwError }
            return vectors
        }
    }

    private struct StubError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Primary wins when it succeeds

    @Test func returnsPrimaryVectorsWhenPrimarySucceeds() async throws {
        let chained = PaceChainedTextEmbeddingClient(
            primary: StubEmbedding(vectors: [[1, 2, 3]], throwError: nil),
            fallback: StubEmbedding(vectors: [[9, 9, 9]], throwError: nil)
        )
        let result = try await chained.embed(["hello"])
        #expect(result == [[1, 2, 3]])
    }

    // MARK: - Fallback triggers on throw

    @Test func fallsBackToSecondaryWhenPrimaryThrows() async throws {
        let chained = PaceChainedTextEmbeddingClient(
            primary: StubEmbedding(vectors: [], throwError: StubError(message: "LM Studio down")),
            fallback: StubEmbedding(vectors: [[0.5, 0.5]], throwError: nil)
        )
        let result = try await chained.embed(["hello"])
        #expect(result == [[0.5, 0.5]])
    }

    // MARK: - Fallback triggers on wrong cardinality

    @Test func fallsBackWhenPrimaryReturnsWrongVectorCount() async throws {
        // Asked for 2 texts but primary returns 1 vector — that's a
        // contract violation severe enough to lose trust in primary
        // for this call. Fallback runs.
        let chained = PaceChainedTextEmbeddingClient(
            primary: StubEmbedding(vectors: [[1, 2]], throwError: nil),
            fallback: StubEmbedding(vectors: [[0.5, 0.5], [0.5, 0.5]], throwError: nil)
        )
        let result = try await chained.embed(["a", "b"])
        #expect(result == [[0.5, 0.5], [0.5, 0.5]])
    }

    // MARK: - All-zero primary is treated as failure

    @Test func fallsBackWhenPrimaryReturnsAllZeroVectors() async throws {
        // A primary that "succeeds" by returning a uniform zero vector
        // — typical of an embedding model that loaded but couldn't
        // process the input — would silently break recall if we
        // trusted it. Treat as failure and run fallback.
        let chained = PaceChainedTextEmbeddingClient(
            primary: StubEmbedding(vectors: [[0, 0, 0], [0, 0, 0]], throwError: nil),
            fallback: StubEmbedding(vectors: [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5]], throwError: nil)
        )
        let result = try await chained.embed(["a", "b"])
        #expect(result == [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5]])
    }

    // MARK: - Partial-zero primary still wins

    @Test func trustsPrimaryWhenAtLeastOneComponentIsNonZero() async throws {
        // A single non-zero component is enough signal — that's the
        // shape of out-of-vocabulary edge cases we DO want to trust
        // (one vector zeroed because the text was empty; the rest
        // are real).
        let chained = PaceChainedTextEmbeddingClient(
            primary: StubEmbedding(vectors: [[0, 0, 0], [0, 1, 0]], throwError: nil),
            fallback: StubEmbedding(vectors: [[9, 9, 9], [9, 9, 9]], throwError: nil)
        )
        let result = try await chained.embed(["", "real text"])
        #expect(result == [[0, 0, 0], [0, 1, 0]])
    }

    // MARK: - Empty input short-circuits

    @Test func emptyInputReturnsEmptyWithoutCallingEitherClient() async throws {
        // Documenting the short-circuit: both clients should be
        // bypassed entirely on empty input. We can't observe that
        // directly without a spying conformer, but verifying the
        // result shape is the next best evidence.
        let chained = PaceChainedTextEmbeddingClient(
            primary: StubEmbedding(vectors: [[1]], throwError: nil),
            fallback: StubEmbedding(vectors: [[2]], throwError: nil)
        )
        let result = try await chained.embed([])
        #expect(result.isEmpty)
    }
}
