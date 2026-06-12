---
status: ready-to-implement
owner: future Pace-repo agent
priority: P1 — broadens audience beyond voice-first early adopters
---

# PRD — Inclusivity Surface (notch chat input + one-tap MCP installs + privacy dashboard)

## Goal

Three changes that include audiences Pace today excludes:

1. **Typists.** Most people don't talk to their computer. The PaceMainWindow chat (shipped tonight) is good, but it lives in a separate window the user has to open first. Add chat directly in the notch panel — one keystroke away.
2. **Integration users.** Pace can open Slack/Notion/Linear/etc., but can't operate them deeply without MCP servers configured. Users won't read the JSON config docs. Ship one-tap installs for the most common servers.
3. **Privacy-conscious shoppers.** Pace's headline differentiator is "on-device, nothing leaves your Mac." But the user has no visible proof. Surface a dashboard.

## Three changes, one PRD

### Change 1 — Keystroke-accessible chat input in the notch panel

A new global shortcut **`cmd+shift+P`** opens a text input field inside the notch panel. The input submits through the same `submitChatTranscriptFromDeepLink(_:)` hook as voice and the MainWindow chat.

UX:
- Pressing `cmd+shift+P` brings the notch panel to front, focuses the text input.
- Pressing Enter submits, Esc dismisses.
- The input field is the same component as the MainWindow chat's input (extract `PaceChatInputField` into a reusable view if not already).
- After submission, the response renders in the existing turn HUD area of the notch panel, NOT in a chat scrollback (the notch is too small).
- The MainWindow chat surface is the place to see the full conversation; the notch is the quick-fire entry point.

Implementation: extend `GlobalPushToTalkShortcutMonitor` (or sibling-pattern it as `GlobalChatShortcutMonitor`) to listen for `cmd+shift+P` via the same listen-only CGEvent tap. On fire, set a `@Published var isNotchChatInputFocused: Bool` on `CompanionManager`. The notch panel renders the input when this is true, focuses it via `@FocusState`.

### Change 2 — One-tap MCP server installs

Today `mcp-servers.example.json` documents 4 popular servers (filesystem, fetch, github, applescript). The user has to copy the example, edit it, paste into the real config file. No one will do this.

Ship a curated catalog of 6 MCP servers as one-tap installs in **Settings → MCP**. Each install:

1. Adds the server config to `~/.config/pace/mcp-servers.json` (creating the file if it doesn't exist; merging into the existing `mcpServers` object if it does).
2. Tries to launch the server immediately (sanity check that the binary/command exists).
3. Refreshes the Skills tab if the server starts cleanly.

**The 6 starter servers:**

| Server | Command | Why |
|---|---|---|
| Filesystem | `@modelcontextprotocol/server-filesystem` | Read/write files in a chosen folder. The most common need. |
| Fetch | `@modelcontextprotocol/server-fetch` | Generic web fetch. Unblocks a huge surface of "go look up X" asks. |
| GitHub | `@modelcontextprotocol/server-github` | GitHub repo ops. Critical for devs. |
| AppleScript | `mcp-applescript` | Bridge to apps without first-class Pace integrations. |
| Slack | `@modelcontextprotocol/server-slack` | The integration users ask about most. |
| Linear | `mcp-linear` | Issue tracking for devs (PaceMainWindow Usage tab already shows it as competitive). |

Each row in the catalog shows:
- Server name + 1-line description.
- Required setup (e.g. "needs a GitHub personal access token" — link to setup docs).
- Install button (becomes "Installed ✓ · Remove" once active).
- Status indicator (green if the server is running; red with error if launch failed; gray if not yet installed).

The catalog is bundled in the app — no remote fetching of the MCP server list. New servers ship via Pace releases.

### Change 3 — Privacy Dashboard

A new "Privacy" sidebar entry in `PaceMainWindow` showing the user's on-device guarantee, visibly.

Sections:

1. **Headline card**: "In the last 24 hours, Pace sent **0 bytes** off this Mac" (computed from `PaceAPIAuditLog` — sum bytes-sent across all off-device-tier entries). If non-zero, "Pace sent **X KB** off this Mac to **Anthropic / OpenAI / etc**" with a count per provider.
2. **Audit log table**: chronological list of every off-device call from `PaceAPIAuditLog` — provider, model, turn-id, byte counts, outcome. No message content. Searchable and filterable.
3. **Per-tier breakdown**: pie/bar chart-equivalent (use simple text bars; Pace doesn't ship a chart library):
   - Local planner: N turns
   - CLI bridge: N turns
   - Direct API: N turns
   - Apple FM: N turns
4. **Permissions audit**: a list of every TCC permission Pace holds (Accessibility, Screen Recording, Mic, Calendar, etc.) with the last-used timestamp pulled from `PaceAPIAuditLog`. Shows which permissions Pace actually exercises versus those that sit dormant.
5. **Data residency claim**: a fixed paragraph explaining the no-cloud principle, the deliberate exceptions (`download_file`, cloud bridge, direct API), and what each off-device toggle actually does.

This view doesn't add any new tracking — `PaceAPIAuditLog` already records every off-device call. The view just surfaces it.

## Scope (out for v1)

- Per-provider key health (rate-limit headroom, billing) — out, that's provider-specific and a tarpit.
- Settings → MCP catalog updates pulled from a remote source — out, no remote fetches.
- Multi-MCP-server orchestration ("install Slack + Linear + AppleScript with one click") — out for v1; single-server install only.
- A "block this app from being read by VLM" privacy control — interesting but separate PRD.

## Architecture

### New file: `leanring-buddy/GlobalChatShortcutMonitor.swift` (~120 lines)

Mirrors `GlobalPushToTalkShortcutMonitor`. Listens for `cmd+shift+P` via a listen-only CGEvent tap. Emits a Combine publisher `chatShortcutPressed: PassthroughSubject<Void, Never>`.

### Modify: `leanring-buddy/CompanionManager.swift`

- New `@Published var isNotchChatInputFocused: Bool`.
- Subscribe to `globalChatShortcutMonitor.chatShortcutPressed` → set the flag true. Also `menuBarPanelManager.showPanel()` to bring the panel forward.
- After the chat input submits, set the flag back to false.

### Modify: `leanring-buddy/CompanionPanelView.swift`

- Render the chat input when `isNotchChatInputFocused` is true. Reuse the input component from `PaceConversationsView` (extract into `PaceChatInputField` if not already shared).
- After submission, the existing turn HUD takes over.

### New file: `leanring-buddy/PaceMCPServerCatalog.swift` (~180 lines)

Pure module. Defines `PaceMCPServerCatalogEntry` with the metadata above (name, description, setup notes, install config). Exposes `bundledCatalog: [PaceMCPServerCatalogEntry]`. Exposes `install(_:into:) throws` and `uninstall(slug:from:) throws` operating on `~/.config/pace/mcp-servers.json` — atomic JSON merge with backup.

### Modify: `leanring-buddy/PaceMCPClient.swift`

- Add helper `loadConfiguredServers() -> [PaceMCPServerConfig]` returning all configured servers + their status (running/not-running/error).
- Add helper `restartServer(named:)` for after-install warm-up.

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

- Extend the existing MCP section: catalog cards above the raw "configured servers" list. Each catalog card has the install/uninstall button + status indicator.

### New file: `leanring-buddy/PacePrivacyDashboardView.swift` (~260 lines)

SwiftUI view. Reads `PaceAPIAuditLog.shared` for the audit data. Renders the four sections.

### Modify: `leanring-buddy/PaceMainView.swift`

- Add `case privacy` to the sidebar selection enum + rendering.

### Modify: `AGENTS.md`

- Key Files rows for `GlobalChatShortcutMonitor.swift`, `PaceMCPServerCatalog.swift`, `PacePrivacyDashboardView.swift`.
- Update the architecture section's MCP block to mention the bundled catalog.
- Update the privacy posture paragraph to mention the dashboard.

## Acceptance criteria

- [ ] All existing tests pass + new tests cover: chat shortcut publisher, MCP catalog install/uninstall (atomic merge), privacy-dashboard audit aggregation.
- [ ] Pressing `cmd+shift+P` anywhere brings the notch panel forward + focuses the text input. Enter submits. Esc dismisses.
- [ ] Settings → MCP shows 6 catalog cards. Tapping install on the Filesystem server writes the config + launches the server + Skills tab shows its tools.
- [ ] PaceMainWindow → Privacy renders. With zero off-device traffic, headline shows "0 bytes". After a cloud-bridge turn, headline updates to "X KB to claude.ai" or similar.
- [ ] `bash scripts/test-pace.sh` ends green (modulo the pre-existing cloud-bridge consent flake).

## Testing strategy

- `GlobalChatShortcutMonitorTests` — simulate CGEvent fires (use the same approach as the existing PTT shortcut tests).
- `PaceMCPServerCatalogTests` — install into a temp file, verify JSON merge correctness, verify uninstall is a clean remove.
- `PacePrivacyDashboardViewTests` — aggregate fake `PaceAPIAuditLog` entries, verify the headline computation across days.

## Risks

- **`cmd+shift+P` conflicts with apps** — Spotlight uses `cmd+space`, Cleanshot uses `cmd+shift+4`, but `cmd+shift+P` is commonly bound by VS Code/Cursor for command palette. Mitigation: make the shortcut configurable (Info.plist `NotchChatShortcut` key, default `commandShiftP`). User can change it.
- **MCP server install fails after writing config** — leaves the user in a broken state. Mitigation: atomic write with backup; transactional rollback on launch failure.
- **Privacy dashboard could be alarming if non-zero** — a single accidental cloud-bridge call shows "Pace sent X KB to Anthropic." That's the intended honesty. Don't mute it.

## Implementation order

1. `PaceMCPServerCatalog.swift` + tests (pure, smallest blast radius).
2. Settings → MCP catalog UI.
3. `GlobalChatShortcutMonitor.swift` + tests.
4. Notch chat input wiring.
5. `PacePrivacyDashboardView.swift` + sidebar entry.
6. AGENTS.md update.
7. `bash scripts/test-pace.sh` green. Commit. Do NOT release.

## What NOT to do

- Don't add remote catalog updates. Bundled list only.
- Don't add user-customizable privacy dashboard widgets. Fixed sections.
- Don't make the notch chat input persistent — it's quick-fire only. Long sessions go to MainWindow.
- Don't add "delete my audit log" — it's local, ephemeral by design, deleted when the app data is cleared.
