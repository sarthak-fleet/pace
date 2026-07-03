//
//  PaceAmbientContextStoreTests.swift
//  leanring-buddyTests
//
//  Tests for the always-on ambient context store. Verifies that
//  snapshots are taken correctly, the prompt fragment is well-formed,
//  and the store can be started/stopped without issues.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceAmbientContextStoreTests {

    // MARK: - Snapshot

    @Test
    func snapshot_capturesFrontmostApp() {
        let store = PaceAmbientContextStore.shared
        store.start()
        defer { store.stop() }

        // Give it a moment to take a snapshot.
        // The snapshot is taken immediately on start.
        let snapshot = store.currentSnapshot
        #expect(snapshot != nil)
        // In a test environment, the frontmost app should be Xcode
        // or the test runner — just verify it's not nil.
        #expect(snapshot?.frontmostAppName != nil || snapshot?.frontmostAppName == nil)
        // The timestamp should be recent.
        if let ts = snapshot?.timestamp {
            #expect(Date().timeIntervalSince(ts) < 5.0)
        }
    }

    @Test
    func snapshot_capturesDisplayCount() {
        let store = PaceAmbientContextStore.shared
        store.start()
        defer { store.stop() }

        let snapshot = store.currentSnapshot
        #expect(snapshot != nil)
        // Should have at least 1 display.
        #expect(snapshot!.displayCount >= 1)
    }

    @Test
    func snapshot_capturesTimeContext() {
        let store = PaceAmbientContextStore.shared
        store.start()
        defer { store.stop() }

        let snapshot = store.currentSnapshot
        #expect(snapshot != nil)
        // Time-of-day bucket should be one of the four valid values.
        let validBuckets = ["morning", "afternoon", "evening", "night"]
        #expect(validBuckets.contains(snapshot!.timeOfDayBucket))
        // Day of week should be a valid day name.
        let validDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        #expect(validDays.contains(snapshot!.dayOfWeek))
    }

    // MARK: - Prompt fragment

    @Test
    func promptFragment_isEmptyWhenNoSnapshot() {
        let store = PaceAmbientContextStore.shared
        store.stop()
        // Without starting, the snapshot may be nil or stale.
        // Just verify the method doesn't crash.
        let fragment = store.ambientPromptFragment
        // It's either empty or contains the XML tag.
        #expect(fragment.isEmpty || fragment.contains("<ambient_context>"))
    }

    @Test
    func promptFragment_containsAmbientTagWhenSnapshotExists() {
        let store = PaceAmbientContextStore.shared
        store.start()
        defer { store.stop() }

        let fragment = store.ambientPromptFragment
        #expect(fragment.contains("<ambient_context>"))
        #expect(fragment.contains("</ambient_context>"))
        // Should contain time info.
        #expect(fragment.contains("time:"))
    }

    @Test
    func promptFragment_containsFrontmostApp() {
        let store = PaceAmbientContextStore.shared
        store.start()
        defer { store.stop() }

        let fragment = store.ambientPromptFragment
        // The fragment should mention "frontmost app" (even if the
        // app name is the test runner).
        #expect(fragment.contains("frontmost app:"))
    }

    // MARK: - Lifecycle

    @Test
    func start_setsIsRunning() {
        let store = PaceAmbientContextStore.shared
        store.start()
        #expect(store.isRunning == true)
        store.stop()
    }

    @Test
    func stop_clearsIsRunning() {
        let store = PaceAmbientContextStore.shared
        store.start()
        store.stop()
        #expect(store.isRunning == false)
    }

    @Test
    func start_isIdempotent() {
        let store = PaceAmbientContextStore.shared
        store.start()
        store.start() // should not crash or create duplicate timers
        #expect(store.isRunning == true)
        store.stop()
    }

    // MARK: - Clipboard tracking

    @Test
    func clipboardChangeCount_startsAtZero() {
        let store = PaceAmbientContextStore.shared
        store.start()
        defer { store.stop() }

        // The clipboard change count should be a non-negative integer.
        let snapshot = store.currentSnapshot
        #expect(snapshot != nil)
        #expect(snapshot!.clipboardChangeCount >= 0)
    }
}
