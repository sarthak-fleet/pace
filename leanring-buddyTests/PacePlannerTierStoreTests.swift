//
//  PacePlannerTierStoreTests.swift
//  leanring-buddyTests
//
//  Pure tests for PacePlannerTierStore — the on-disk state for the
//  user-facing tier picker. No keychain, no network.
//

import Foundation
import Testing

@testable import Pace

/// The tier store reads/writes `UserDefaults.standard`, so concurrent
/// tests would race on shared keys. Running this suite serially keeps
/// the assertions deterministic without isolating to a per-suite domain
/// (production code uses .standard, so changing that would mask real
/// behavior). Matches the same pattern PaceCloudBridgeConsentTests
/// would benefit from — see the known-flake note in the PRD.
@Suite(.serialized)
struct PacePlannerTierStoreTests {

    /// All keys this store uses. Mirrors the private enum in
    /// PacePlannerTierStore — keep these in sync if keys change.
    private static let allPlannerTierUserDefaultsKeys: [String] = [
        "pace.planner.tier.selectedTier",
        "pace.planner.tier.directAPI.provider",
        "pace.planner.tier.directAPI.model",
        "pace.planner.tier.directAPI.customEndpointURL",
        "pace.planner.tier.directAPI.fallsBackToLocalOnFailure"
    ]

    /// Saves and restores the full set of tier-picker keys around the test
    /// so we never leave production UserDefaults in a dirty state.
    private func withClearedAndRestoredPlannerTierState<R>(
        _ body: () throws -> R
    ) rethrows -> R {
        var savedValuesByKey: [String: Any] = [:]
        for keyName in Self.allPlannerTierUserDefaultsKeys {
            if let savedValue = UserDefaults.standard.object(forKey: keyName) {
                savedValuesByKey[keyName] = savedValue
            }
            UserDefaults.standard.removeObject(forKey: keyName)
        }
        defer {
            for keyName in Self.allPlannerTierUserDefaultsKeys {
                if let savedValue = savedValuesByKey[keyName] {
                    UserDefaults.standard.set(savedValue, forKey: keyName)
                } else {
                    UserDefaults.standard.removeObject(forKey: keyName)
                }
            }
        }
        return try body()
    }

    // MARK: - First-launch defaults

    @Test
    func firstLaunchDefaultsToLocalTier() {
        withClearedAndRestoredPlannerTierState {
            let configuration = PacePlannerTierStore.loadConfiguration()
            #expect(configuration.tier == .local)
        }
    }

    @Test
    func firstLaunchDefaultsToAnthropicDirectAPIProvider() {
        withClearedAndRestoredPlannerTierState {
            let configuration = PacePlannerTierStore.loadConfiguration()
            #expect(configuration.directAPIProvider == .anthropic)
        }
    }

    @Test
    func firstLaunchDefaultsToAnthropicDefaultModelIdentifier() {
        withClearedAndRestoredPlannerTierState {
            let configuration = PacePlannerTierStore.loadConfiguration()
            #expect(configuration.directAPIModelIdentifier == PaceDirectAPIProvider.anthropic.defaultModelIdentifier)
        }
    }

    @Test
    func firstLaunchDefaultsCustomEndpointURLToEmptyString() {
        withClearedAndRestoredPlannerTierState {
            let configuration = PacePlannerTierStore.loadConfiguration()
            #expect(configuration.directAPICustomEndpointURLString.isEmpty)
        }
    }

    @Test
    func firstLaunchDefaultsFallsBackToLocalOnCloudFailureToFalse() {
        withClearedAndRestoredPlannerTierState {
            let configuration = PacePlannerTierStore.loadConfiguration()
            #expect(configuration.fallsBackToLocalOnCloudFailure == false)
        }
    }

    // MARK: - Persistence round trips

    @Test
    func savingATierPersistsAcrossLoads() {
        withClearedAndRestoredPlannerTierState {
            for tierUnderTest in PacePlannerTier.allCases {
                PacePlannerTierStore.saveTier(tierUnderTest)
                let reloadedConfiguration = PacePlannerTierStore.loadConfiguration()
                #expect(reloadedConfiguration.tier == tierUnderTest)
            }
        }
    }

    @Test
    func savingADirectAPIProviderPersistsAcrossLoads() {
        withClearedAndRestoredPlannerTierState {
            for providerUnderTest in PaceDirectAPIProvider.allCases {
                PacePlannerTierStore.saveDirectAPIProvider(providerUnderTest)
                let reloadedConfiguration = PacePlannerTierStore.loadConfiguration()
                #expect(reloadedConfiguration.directAPIProvider == providerUnderTest)
            }
        }
    }

    @Test
    func savingADirectAPIModelIdentifierPersistsAcrossLoads() {
        withClearedAndRestoredPlannerTierState {
            let modelIdentifierUnderTest = "claude-opus-4-7"
            PacePlannerTierStore.saveDirectAPIModelIdentifier(modelIdentifierUnderTest)
            let reloadedConfiguration = PacePlannerTierStore.loadConfiguration()
            #expect(reloadedConfiguration.directAPIModelIdentifier == modelIdentifierUnderTest)
        }
    }

    @Test
    func savingACustomEndpointURLPersistsAcrossLoads() {
        withClearedAndRestoredPlannerTierState {
            let customEndpointURLString = "https://example.com/v1/chat/completions"
            PacePlannerTierStore.saveDirectAPICustomEndpointURL(customEndpointURLString)
            let reloadedConfiguration = PacePlannerTierStore.loadConfiguration()
            #expect(reloadedConfiguration.directAPICustomEndpointURLString == customEndpointURLString)
        }
    }

    @Test
    func savingFallsBackToLocalOnCloudFailurePersistsAcrossLoads() {
        withClearedAndRestoredPlannerTierState {
            PacePlannerTierStore.saveFallsBackToLocalOnCloudFailure(true)
            #expect(PacePlannerTierStore.loadConfiguration().fallsBackToLocalOnCloudFailure == true)

            PacePlannerTierStore.saveFallsBackToLocalOnCloudFailure(false)
            #expect(PacePlannerTierStore.loadConfiguration().fallsBackToLocalOnCloudFailure == false)
        }
    }

    // MARK: - Endpoint URL resolution

    @Test
    func endpointURLResolutionReturnsBuiltInDefaultForKnownProviders() {
        let builtInProviders: [PaceDirectAPIProvider] = [.anthropic, .openai, .openrouter]
        for providerUnderTest in builtInProviders {
            let configuration = PacePlannerTierConfiguration(
                tier: .directAPI,
                directAPIProvider: providerUnderTest,
                directAPIModelIdentifier: providerUnderTest.defaultModelIdentifier,
                directAPICustomEndpointURLString: "https://ignored-because-not-custom.example.com",
                fallsBackToLocalOnCloudFailure: false
            )
            let resolved = PacePlannerTierStore.resolvedDirectAPIEndpointURLString(for: configuration)
            #expect(resolved == providerUnderTest.defaultEndpointURLString)
        }
    }

    @Test
    func endpointURLResolutionReturnsCustomEndpointWhenProviderIsCustom() {
        let pastedCustomEndpointURLString = "https://my-proxy.example.com/v1/chat/completions"
        let configuration = PacePlannerTierConfiguration(
            tier: .directAPI,
            directAPIProvider: .custom,
            directAPIModelIdentifier: "custom-model",
            directAPICustomEndpointURLString: pastedCustomEndpointURLString,
            fallsBackToLocalOnCloudFailure: false
        )
        #expect(PacePlannerTierStore.resolvedDirectAPIEndpointURLString(for: configuration) == pastedCustomEndpointURLString)
    }

    // MARK: - Provider defaults

    @Test
    func everyBuiltInProviderHasANonEmptyDefaultEndpointURL() {
        let builtInProviders: [PaceDirectAPIProvider] = [.anthropic, .openai, .openrouter]
        for providerUnderTest in builtInProviders {
            #expect(!providerUnderTest.defaultEndpointURLString.isEmpty)
            #expect(providerUnderTest.defaultEndpointURLString.hasPrefix("https://"))
        }
    }

    @Test
    func customProviderDefaultEndpointURLIsEmpty() {
        #expect(PaceDirectAPIProvider.custom.defaultEndpointURLString.isEmpty)
        #expect(PaceDirectAPIProvider.custom.defaultModelIdentifier.isEmpty)
    }

    @Test
    func anthropicProviderUsesAnthropicNativeAuthHeaderConvention() {
        #expect(PaceDirectAPIProvider.anthropic.usesAnthropicAuthHeader == true)
        #expect(PaceDirectAPIProvider.openai.usesAnthropicAuthHeader == false)
        #expect(PaceDirectAPIProvider.openrouter.usesAnthropicAuthHeader == false)
        #expect(PaceDirectAPIProvider.custom.usesAnthropicAuthHeader == false)
    }

    // MARK: - Equality

    @Test
    func configurationEqualityRequiresAllFieldsToMatch() {
        let configurationA = PacePlannerTierConfiguration(
            tier: .directAPI,
            directAPIProvider: .anthropic,
            directAPIModelIdentifier: "claude-sonnet-4-5",
            directAPICustomEndpointURLString: "",
            fallsBackToLocalOnCloudFailure: false
        )
        let configurationB = PacePlannerTierConfiguration(
            tier: .directAPI,
            directAPIProvider: .anthropic,
            directAPIModelIdentifier: "claude-sonnet-4-5",
            directAPICustomEndpointURLString: "",
            fallsBackToLocalOnCloudFailure: false
        )
        #expect(configurationA == configurationB)

        let configurationDifferentTier = PacePlannerTierConfiguration(
            tier: .local,
            directAPIProvider: .anthropic,
            directAPIModelIdentifier: "claude-sonnet-4-5",
            directAPICustomEndpointURLString: "",
            fallsBackToLocalOnCloudFailure: false
        )
        #expect(configurationA != configurationDifferentTier)
    }
}
