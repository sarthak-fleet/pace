//
//  PaceKeychainStore.swift
//  leanring-buddy
//
//  Minimal wrapper over Security framework `kSecClassGenericPassword`.
//  Pace's ONLY API-key entry point — nothing else in the codebase may
//  read or write API key material. Keys live here so they never
//  touch UserDefaults, Info.plist, Application Support, or any log line.
//
//  Storage rules (locked down by PRD):
//    - `kSecAttrSynchronizable = false`         — never syncs via iCloud Keychain.
//    - `kSecAttrAccessible = kSecAttrAccessibleWhenUnlocked` — unavailable while
//      the Mac is locked. Pace turns can't fire then anyway.
//    - Service identifier is Pace-scoped so revoking these keys never
//      touches the user's other apps.
//    - The returned API key string is held in-process only. Callers must
//      NEVER write it to disk, plist, log, or audit-log entry.
//
//  See PRD: docs/prds/planner-tier-picker.md
//

import Foundation
import Security

enum PaceKeychainStore {

    /// Pace-scoped service identifier. Distinct from any other keychain
    /// entries on the user's Mac so revoking Pace's keys never touches
    /// their other apps.
    static let serviceIdentifier = "com.pace.app.plannerAPIKeys"

    /// Account names follow `directAPI.<provider>.apiKey` so additional
    /// future key categories (e.g. embeddings) get their own namespace.
    static func keychainAccountName(for provider: PaceDirectAPIProvider) -> String {
        return "directAPI.\(provider.rawValue).apiKey"
    }

    /// Stores `apiKey` under the Pace service identifier + provider account.
    /// Overwrites in place via `SecItemUpdate` when an entry already exists
    /// (the only legal write path), otherwise adds via `SecItemAdd`.
    ///
    /// Returns true on success; false on any keychain error. Error status
    /// codes are logged but the API key value itself is NEVER logged.
    @discardableResult
    static func storeAPIKey(_ apiKey: String, for provider: PaceDirectAPIProvider) -> Bool {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { return false }
        guard let apiKeyData = trimmedAPIKey.data(using: .utf8) else { return false }

        let accountName = keychainAccountName(for: provider)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: apiKeyData
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            updateAttributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            print("⚠️ PaceKeychainStore.storeAPIKey: SecItemUpdate failed status=\(updateStatus)")
            return false
        }

        var addItemAttributes: [String: Any] = baseQuery
        addItemAttributes[kSecValueData as String] = apiKeyData
        // Never sync to iCloud Keychain — keys are local-to-this-Mac.
        addItemAttributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        // Available only while the Mac is unlocked — Pace turns can't fire
        // when the screen is locked anyway, so this gives no extra cost.
        addItemAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addItemAttributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("⚠️ PaceKeychainStore.storeAPIKey: SecItemAdd failed status=\(addStatus)")
            return false
        }
        return true
    }

    /// Returns the stored API key for this provider, or nil if none is set.
    /// Callers must keep the returned string in-process only — never write
    /// it to disk, plist, log, or audit-log entry. This function does NOT
    /// log the returned value under any condition.
    static func loadAPIKey(for provider: PaceDirectAPIProvider) -> String? {
        let accountName = keychainAccountName(for: provider)

        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var retrievedItemReference: AnyObject?
        let lookupStatus = SecItemCopyMatching(lookupQuery as CFDictionary, &retrievedItemReference)

        guard lookupStatus == errSecSuccess else {
            if lookupStatus != errSecItemNotFound {
                print("⚠️ PaceKeychainStore.loadAPIKey: SecItemCopyMatching status=\(lookupStatus)")
            }
            return nil
        }

        guard let retrievedKeyData = retrievedItemReference as? Data,
              let recoveredAPIKey = String(data: retrievedKeyData, encoding: .utf8) else {
            return nil
        }
        return recoveredAPIKey
    }

    /// Removes the stored key for this provider. Returns true on success
    /// OR if no entry existed (idempotent delete). Returns false only on a
    /// genuine keychain error.
    @discardableResult
    static func deleteAPIKey(for provider: PaceDirectAPIProvider) -> Bool {
        let accountName = keychainAccountName(for: provider)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound {
            return true
        }
        print("⚠️ PaceKeychainStore.deleteAPIKey: SecItemDelete status=\(deleteStatus)")
        return false
    }

    /// Convenience for Settings UI: returns the set of providers that
    /// currently have a stored key, so the panel can show a green
    /// checkmark next to a saved provider.
    static func providersWithStoredKeys() -> Set<PaceDirectAPIProvider> {
        var providersWithKeys: Set<PaceDirectAPIProvider> = []
        for provider in PaceDirectAPIProvider.allCases {
            if loadAPIKey(for: provider) != nil {
                providersWithKeys.insert(provider)
            }
        }
        return providersWithKeys
    }
}
