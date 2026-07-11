# Infra & patterns — pace

Cross-cutting code mechanisms that back Pace's privacy and reliability claims: how a URL gets proven local, how a file write survives a crash, how third-party tools get bridged in, how the app updates and stores secrets, and how the menu-bar-only shell and Swift 6 concurrency hold together. Concepts with an external spec (loopback guard, MCP protocol) are explained once in [`new-things.md`](new-things.md) — this page documents the code that enforces them.

---

## Local endpoint guard
- What: A fail-closed validator that only lets a configured URL through if its host is `localhost`, `127.0.0.0/8`, or `::1` — anything else is rejected and the caller falls back to a hardcoded loopback default.
- Why here: The single choke point that makes "0 bytes off this Mac" true in code, not just in docs — every planner/VLM/TTS sidecar URL flows through it before a request is ever sent.
- Where: `PaceLocalEndpointGuard.swift` — `PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL` / `isLoopbackHost`. Two sibling validators intentionally live in the same file with different rules: `validatedCloudBridgeURL` (still loopback-only) and `validatedDirectAPIURL` (allows `https` to any host for consented BYO-key egress, but refuses plaintext `http` to a non-loopback host).
- Source: internal — no external spec; concept explained in [`new-things.md`](new-things.md#loopback-guard-tts-self-capture-prevention).

## Atomic temp-file + rename persistence
- What: Writing a new file version to a temp path in the same directory, then atomically renaming/replacing it over the real file, so a crash mid-write can never leave a half-written or corrupted file on disk.
- Why here: Every piece of durable local state Pace owns (flows, thread memory, MCP config, meeting-note profiles) uses this pattern instead of an in-place `write(to:)` — the app has no server-side backup to recover from a truncated file.
- Where: `PaceFlowStore.swift` — `save(_:)` writes to a sibling temp file (`FileManager.default.temporaryDirectory`-adjacent) then calls `FileManager.default.replaceItemAt(_:withItemAt:)`, falling back to `moveItem` when there's nothing to replace. `PaceThreadMemoryStore.swift` uses the simpler one-line form, `data.write(to:options:.atomic)`, which does the same temp-file-then-rename under the hood on the same volume. `PaceMCPCatalogInstaller.swift` (below) is the same pattern a third time, for JSON merges.
- Source: standard Unix atomic-write pattern (internal usage — no single canonical spec).

## MCP stdio bridge
- What: The concrete code that spawns a configured MCP server as a subprocess, speaks newline-delimited JSON-RPC to it (`initialize` → `notifications/initialized` → `tools/call`), and returns the result as a string observation.
- Why here: How Pace's approval/observation loop stays agnostic to which third-party tool actually ran — `PaceMCPStdioClient.callTool` is the one place a planner tool call becomes a real subprocess request.
- Where: `PaceMCPClient.swift` — `PaceMCPStdioClient.callTool`, `PaceMCPServerRegistry.loadConfiguredServers` (reads `~/.config/pace/mcp-servers.json` or `~/.pace/mcp-servers.json`, accepting either a `servers` or `mcpServers` root key). `PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment` layers a stored Keychain secret over an empty-string env sentinel at spawn time, so a server like Composio never needs its API key written into the JSON config file.
- Source: MCP protocol → pointer to [`new-things.md`](new-things.md#mcp-model-context-protocol).

## MCP catalog + installer
- What: A fixed list of ready-made MCP server entries the Settings UI can install with one click, plus a pure-file-I/O installer that merges a new entry into `mcp-servers.json` without disturbing anything already there.
- Why here: Removes the "hand-edit a JSON file" barrier for the common integrations users actually ask for, while keeping the merge safe for users who've already customized the file by hand.
- Where: `PaceMCPServerCatalog.swift` — `PaceMCPServerCatalog.bundledCatalog` (currently four entries: filesystem, fetch, applescript, composio — github/slack/linear were retired in favor of the Composio OAuth bridge, tracked in `PaceMCPServerCatalog.supersededBySlug`) and `PaceMCPCatalogInstaller.install`/`uninstall`, which decode the existing config, merge in one key, and call the same atomic temp-file + rename write described above (`atomicallyWriteMCPServers`).
- Source: internal — no external spec.

## Sparkle auto-updates
- What: Third-party Swift framework (Sparkle) that checks a hosted "appcast" XML feed for new versions, verifies each update's authenticity with an EdDSA signature, and drives the download/install UI.
- Why here: Pace ships outside the Mac App Store, so Sparkle is the update channel — no notarization-gated App Store review loop, but still a signed, verified update path rather than an unsigned binary swap.
- Where: `PaceAutoUpdateController.swift` — `PaceAutoUpdateController` wraps `SPUStandardUpdaterController(startingUpdater: true, ...)`, constructed lazily by `CompanionAppDelegate` at launch. `Info.plist` supplies `SUFeedURL` (a GitHub-hosted `appcast.xml`) and `SUPublicEDKey` (the public half of the release-machine-held signing key); the private key never ships in the app.
- Source: https://sparkle-project.org/

## Keychain storage for API keys
- What: Apple's Security framework API (`kSecClassGenericPassword`, `SecItemAdd`/`SecItemCopyMatching`) for storing small secrets in the macOS encrypted keychain instead of a plaintext file.
- Why here: Direct-API BYO-key planner turns need a real API key persisted somewhere — Pace's rule is that key never touches UserDefaults, a plist, or a log line, so Keychain is the only legal home for it.
- Where: `PaceKeychainStore.swift` — `PaceKeychainStore` (enum) wraps `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate` behind `storeAPIKey`/`loadAPIKey`-style calls, all keyed off `kSecClassGenericPassword`.
- Source: https://developer.apple.com/documentation/security/keychain-services

## Menu-bar-only app pattern
- What: `LSUIElement=true` in `Info.plist` removes the Dock icon and default menu bar entirely; the app then owns its own always-on-top, non-activating `NSPanel` windows instead of a standard `NSWindow` or `NSStatusItem`.
- Why here: Pace's entire visible surface (the black notch capsule, the floating companion panel, the cursor overlay) is these custom panels — there is deliberately no Dock icon and no main window to alt-tab to.
- Where: `PaceMenuBarOverlay.swift` — `PaceMenuBarOverlayManager` owns the capsule in a `PaceMenuBarOverlayPanel` (`NSPanel` subclass, `canBecomeKey` overridden to `false` so it never steals focus). `MenuBarPanelManager.swift` owns the floating companion panel in a `KeyablePanel` (`.nonactivatingPanel` style mask, `canBecomeKey` overridden to `true` so its text field can still receive keystrokes without activating the app).
- Source: https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement

## Swift 6 concurrency idioms
- What: Three recurring annotations that satisfy the Swift 6 strict-concurrency checker — `@MainActor` for UI-touching classes, `nonisolated` for pure value types with no shared mutable state, and `@unchecked Sendable` as an escape hatch when a class's thread-safety is proven by hand (a lock, a serial queue) rather than by the compiler.
- Why here: Pace's async/await-everywhere codebase (planner calls, TTS synthesis, MCP subprocess I/O) needs the compiler's data-race checking to actually pass, without forcing every small struct onto the main actor.
- Where: `PaceThreadMemory.swift` pairs `@MainActor final class PaceThreadMemory` (owns the live conversation state, mutated only from the main actor) with `nonisolated struct PaceThreadMemoryConfiguration` and `PaceThreadMemorySnapshot` (plain `Equatable`/`Codable` value types safely passed across actor boundaries for persistence). `PaceAPIAuditLog.swift` shows the escape hatch: `nonisolated final class PaceAPIAuditLog: @unchecked Sendable` guards its mutable `_currentTurnId` with an explicit `NSLock` instead of actor isolation, because the audit log is written from many concurrent subsystems (planner, VLM, TTS, MCP, executor) and actor-hopping there would add latency the audit path can't afford.
- Source: https://developer.apple.com/documentation/swift/concurrency

---

See also: [`README.md`](README.md).
