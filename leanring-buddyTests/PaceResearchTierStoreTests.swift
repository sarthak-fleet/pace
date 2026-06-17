//
//  PaceResearchTierStoreTests.swift
//  leanring-buddyTests
//
//  Pure tests for `PaceResearchTierStore` — defaults, clamping, and
//  round-trip persistence. Each test cleans up its own UserDefaults
//  state so re-runs don't leak settings across tests.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceResearchTierStoreTests {

    /// All UserDefaults keys the store writes to; clean these before
    /// and after every test so re-runs don't leak across.
    private static let userDefaultsKeysToClean: [String] = [
        "pace.research.tier.selectedTier",
        "pace.research.tier.directAPI.provider",
        "pace.research.tier.directAPI.model",
        "pace.research.tier.directAPI.customEndpointURL",
        "pace.research.tier.cliBridge.upstream",
        "pace.research.tier.cliBridge.model",
        "pace.research.tier.maximumAgentSteps",
        "pace.research.tier.perTurnTokenBudgetCap"
    ]

    private static func cleanUserDefaults() {
        for key in userDefaultsKeysToClean {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func defaultsAreOpaqueAndOptIn() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        let configuration = PaceResearchTierStore.loadConfiguration()
        // Default tier is OFF so the feature stays opt-in — existing
        // users see zero behavior change until they touch Settings →
        // Research.
        #expect(configuration.tier == .off)
        #expect(configuration.directAPIProvider == .anthropic)
        #expect(configuration.directAPIModelIdentifier == "claude-opus-4-7")
        #expect(configuration.cliBridgeUpstream == .claude)
        #expect(configuration.cliBridgeModel == "claude-opus-4-7")
        #expect(configuration.maximumAgentSteps == PaceResearchTierStore.defaultMaximumAgentSteps)
        #expect(configuration.perTurnTokenBudgetCap == PaceResearchTierStore.defaultPerTurnTokenBudgetCap)
    }

    @Test func saveTierPersistsAcrossLoads() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.directAPI)
        let configuration = PaceResearchTierStore.loadConfiguration()
        #expect(configuration.tier == .directAPI)
    }

    @Test func maximumAgentStepsAreClampedHighAndLow() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveMaximumAgentSteps(9999)
        let configurationAfterHighSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterHighSave.maximumAgentSteps == PaceResearchTierStore.maximumAgentStepsRange.upperBound)

        PaceResearchTierStore.saveMaximumAgentSteps(0)
        let configurationAfterLowSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterLowSave.maximumAgentSteps == PaceResearchTierStore.maximumAgentStepsRange.lowerBound)
    }

    @Test func perTurnTokenBudgetCapIsClampedHighAndLow() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.savePerTurnTokenBudgetCap(99_999_999)
        let configurationAfterHighSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterHighSave.perTurnTokenBudgetCap == PaceResearchTierStore.perTurnTokenBudgetCapRange.upperBound)

        PaceResearchTierStore.savePerTurnTokenBudgetCap(1)
        let configurationAfterLowSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterLowSave.perTurnTokenBudgetCap == PaceResearchTierStore.perTurnTokenBudgetCapRange.lowerBound)
    }

    @Test func directAPIProviderAndModelRoundTrip() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveDirectAPIProvider(.openrouter)
        PaceResearchTierStore.saveDirectAPIModelIdentifier("anthropic/claude-opus-4")
        let configuration = PaceResearchTierStore.loadConfiguration()
        #expect(configuration.directAPIProvider == .openrouter)
        #expect(configuration.directAPIModelIdentifier == "anthropic/claude-opus-4")
    }

    @Test func cliBridgeUpstreamAndModelRoundTrip() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveCLIBridgeUpstream(.codex)
        PaceResearchTierStore.saveCLIBridgeModel("gpt-5-turbo")
        let configuration = PaceResearchTierStore.loadConfiguration()
        #expect(configuration.cliBridgeUpstream == .codex)
        #expect(configuration.cliBridgeModel == "gpt-5-turbo")
    }

    @Test func customEndpointURLResolverFallsBackToProviderDefault() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveDirectAPIProvider(.anthropic)
        let configuration = PaceResearchTierStore.loadConfiguration()
        let resolvedEndpoint = PaceResearchTierStore.resolvedDirectAPIEndpointURLString(for: configuration)
        #expect(resolvedEndpoint == PaceDirectAPIProvider.anthropic.defaultEndpointURLString)
    }

    @Test func customEndpointURLResolverReturnsPastedURLForCustom() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveDirectAPIProvider(.custom)
        PaceResearchTierStore.saveDirectAPICustomEndpointURL("https://my-proxy.example.com/v1/chat/completions")
        let configuration = PaceResearchTierStore.loadConfiguration()
        let resolvedEndpoint = PaceResearchTierStore.resolvedDirectAPIEndpointURLString(for: configuration)
        #expect(resolvedEndpoint == "https://my-proxy.example.com/v1/chat/completions")
    }
}
