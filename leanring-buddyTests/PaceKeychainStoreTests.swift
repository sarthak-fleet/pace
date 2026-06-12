//
//  PaceKeychainStoreTests.swift
//  leanring-buddyTests
//
//  Round-trip tests for the keychain-backed API key store. These tests
//  clean up after themselves so they never leave key material in the real
//  Pace keychain across runs.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceKeychainStoreTests {

    /// Wipes every Pace API-key entry before AND after each test runs so
    /// no test depends on the order of execution. The teardown also
    /// guarantees the real Pace keychain stays clean even if the test
    /// process is interrupted.
    private func wipeAllStoredPaceAPIKeysOnce() {
        for provider in PaceDirectAPIProvider.allCases {
            _ = PaceKeychainStore.deleteAPIKey(for: provider)
        }
    }

    @Test
    func keychainAccountNameIncludesProviderRawValue() {
        for provider in PaceDirectAPIProvider.allCases {
            let accountNameForProvider = PaceKeychainStore.keychainAccountName(for: provider)
            #expect(accountNameForProvider.contains(provider.rawValue))
            #expect(accountNameForProvider.hasPrefix("directAPI."))
            #expect(accountNameForProvider.hasSuffix(".apiKey"))
        }
    }

    @Test
    func storingAKeyRoundTripsThroughLoadAPIKey() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        let providerUnderTest = PaceDirectAPIProvider.anthropic
        let testOnlyAPIKeyValue = "sk-ant-test-\(UUID().uuidString)"

        let didStore = PaceKeychainStore.storeAPIKey(testOnlyAPIKeyValue, for: providerUnderTest)
        #expect(didStore == true)

        let loadedKeyValue = PaceKeychainStore.loadAPIKey(for: providerUnderTest)
        #expect(loadedKeyValue == testOnlyAPIKeyValue)
    }

    @Test
    func storingAKeyTwiceForTheSameProviderOverwritesInPlace() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        let providerUnderTest = PaceDirectAPIProvider.openai

        let firstStoredKeyValue = "sk-original-\(UUID().uuidString)"
        let secondStoredKeyValue = "sk-overwritten-\(UUID().uuidString)"

        _ = PaceKeychainStore.storeAPIKey(firstStoredKeyValue, for: providerUnderTest)
        _ = PaceKeychainStore.storeAPIKey(secondStoredKeyValue, for: providerUnderTest)

        let loadedKeyValue = PaceKeychainStore.loadAPIKey(for: providerUnderTest)
        #expect(loadedKeyValue == secondStoredKeyValue)
    }

    @Test
    func deletingAStoredKeyRemovesItFromLoadAPIKey() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        let providerUnderTest = PaceDirectAPIProvider.openrouter
        _ = PaceKeychainStore.storeAPIKey("sk-or-\(UUID().uuidString)", for: providerUnderTest)
        #expect(PaceKeychainStore.loadAPIKey(for: providerUnderTest) != nil)

        let didDelete = PaceKeychainStore.deleteAPIKey(for: providerUnderTest)
        #expect(didDelete == true)
        #expect(PaceKeychainStore.loadAPIKey(for: providerUnderTest) == nil)
    }

    @Test
    func deletingAMissingKeyReturnsTrueIdempotently() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        // No key was ever stored — the delete should still succeed.
        let didDelete = PaceKeychainStore.deleteAPIKey(for: PaceDirectAPIProvider.custom)
        #expect(didDelete == true)
    }

    @Test
    func storingAKeyForOneProviderDoesNotAffectAnotherProvider() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        let anthropicKeyValue = "sk-ant-\(UUID().uuidString)"
        let openaiKeyValue = "sk-oai-\(UUID().uuidString)"

        _ = PaceKeychainStore.storeAPIKey(anthropicKeyValue, for: .anthropic)
        _ = PaceKeychainStore.storeAPIKey(openaiKeyValue, for: .openai)

        #expect(PaceKeychainStore.loadAPIKey(for: .anthropic) == anthropicKeyValue)
        #expect(PaceKeychainStore.loadAPIKey(for: .openai) == openaiKeyValue)
    }

    @Test
    func providersWithStoredKeysReflectsCurrentStorageState() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        #expect(PaceKeychainStore.providersWithStoredKeys().isEmpty)

        _ = PaceKeychainStore.storeAPIKey("sk-test", for: .anthropic)
        _ = PaceKeychainStore.storeAPIKey("sk-test", for: .openrouter)

        let providersWithKeys = PaceKeychainStore.providersWithStoredKeys()
        #expect(providersWithKeys.contains(.anthropic))
        #expect(providersWithKeys.contains(.openrouter))
        #expect(!providersWithKeys.contains(.openai))
        #expect(!providersWithKeys.contains(.custom))
    }

    @Test
    func storingAnEmptyKeyReturnsFalseAndDoesNotPersist() {
        wipeAllStoredPaceAPIKeysOnce()
        defer { wipeAllStoredPaceAPIKeysOnce() }

        let didStoreEmpty = PaceKeychainStore.storeAPIKey("", for: .anthropic)
        #expect(didStoreEmpty == false)

        let didStoreWhitespaceOnly = PaceKeychainStore.storeAPIKey("   ", for: .anthropic)
        #expect(didStoreWhitespaceOnly == false)

        #expect(PaceKeychainStore.loadAPIKey(for: .anthropic) == nil)
    }
}
