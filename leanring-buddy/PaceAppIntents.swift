//
//  PaceAppIntents.swift
//  leanring-buddy
//
//  Surfaces Pace's external command set (chat, listen, watch mode,
//  show panel) through Apple's App Intents framework. Once these
//  exist, every command becomes:
//    - a Shortcuts action (drag-droppable into any Automator/Hazel
//      workflow, runnable from Stream Deck, Keyboard Maestro, etc.)
//    - a Siri voice phrase ("Hey Siri, ask Pace what's on my screen")
//    - a Spotlight result (typing "ask Pace …" surfaces the intent)
//    - a Focus filter target (a user can opt to silence Pace nudges
//      from inside a system Focus's "Allowed Apps" list)
//
//  All four intents route into the SAME `executePaceExternalCommand`
//  entry point as `pace://` deeplinks, so behavior is byte-identical
//  whether the user launched the command via URL scheme, App Intent,
//  or in-app surface. The 500-char cap on chat text matches the
//  deeplink cap for the same external-input reason.
//

import AppIntents
import AppKit

// MARK: - Errors

nonisolated enum PaceAppIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appDelegateUnavailable
    case messageEmpty
    case messageTooLong

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appDelegateUnavailable:
            return "Pace isn't ready yet. Try again in a moment."
        case .messageEmpty:
            return "Pace needs a message to send."
        case .messageTooLong:
            return "Message too long — keep it under 500 characters."
        }
    }
}

// MARK: - Intents

@available(macOS 13.0, *)
struct PaceConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Pace"
    static var description = IntentDescription(
        "Send a message to Pace. Pace runs entirely on your Mac — your message goes to the local planner, not the cloud."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Message",
        description: "What you want to ask or tell Pace.",
        inputOptions: String.IntentInputOptions(
            keyboardType: .default,
            capitalizationType: .sentences,
            multiline: true,
            autocorrect: true
        )
    )
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PaceAppIntentError.messageEmpty }
        // Same external-input cap as the deeplink parser. Reject
        // rather than truncate — truncation could silently change the
        // meaning of a long command.
        guard trimmed.count <= PaceDeepLinkParser.maximumChatTextCharacterCount else {
            throw PaceAppIntentError.messageTooLong
        }
        guard let appDelegate = NSApp.delegate as? CompanionAppDelegate else {
            throw PaceAppIntentError.appDelegateUnavailable
        }
        appDelegate.executePaceExternalCommand(.sendChatMessage(text: trimmed))
        return .result()
    }
}

@available(macOS 13.0, *)
struct PaceStartListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Pace: Start Listening"
    static var description = IntentDescription(
        "Begin a push-to-talk voice session with Pace."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appDelegate = NSApp.delegate as? CompanionAppDelegate else {
            throw PaceAppIntentError.appDelegateUnavailable
        }
        appDelegate.executePaceExternalCommand(.startListening)
        return .result()
    }
}

@available(macOS 13.0, *)
struct PaceShowPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Pace: Show Panel"
    static var description = IntentDescription(
        "Open Pace's companion panel."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appDelegate = NSApp.delegate as? CompanionAppDelegate else {
            throw PaceAppIntentError.appDelegateUnavailable
        }
        appDelegate.executePaceExternalCommand(.showPanel)
        return .result()
    }
}

@available(macOS 13.0, *)
struct PaceSetWatchModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Pace: Set Watch Mode"
    static var description = IntentDescription(
        "Turn Pace's screen-watch mode on or off."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Enabled",
        description: "Turn watch mode on (true) or off (false).",
        default: true
    )
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appDelegate = NSApp.delegate as? CompanionAppDelegate else {
            throw PaceAppIntentError.appDelegateUnavailable
        }
        appDelegate.executePaceExternalCommand(.setWatchMode(enabled: enabled))
        return .result()
    }
}

// MARK: - App Shortcuts provider

/// Spotlight + Siri-discoverable phrases. Each phrase MUST contain
/// `\(.applicationName)` so the system can resolve which app the
/// user is speaking to.
@available(macOS 13.0, *)
struct PaceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // String parameters can't be interpolated directly into Siri
        // phrases (the metadata processor only allows AppEntity /
        // AppEnum interpolation). The phrases below invoke the
        // intent's parameter-request flow — Siri hears the phrase,
        // confirms the intent, then prompts the user "What do you
        // want to say?" via the @Parameter's `requestValue`.
        AppShortcut(
            intent: PaceConversationIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Send a message to \(.applicationName)",
                "Tell \(.applicationName) something",
            ],
            shortTitle: "Ask Pace",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: PaceStartListeningIntent(),
            phrases: [
                "Start listening with \(.applicationName)",
                "Listen with \(.applicationName)",
            ],
            shortTitle: "Start Listening",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: PaceShowPanelIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Open \(.applicationName)",
            ],
            shortTitle: "Show Panel",
            systemImageName: "rectangle.on.rectangle"
        )
        AppShortcut(
            intent: PaceSetWatchModeIntent(),
            phrases: [
                "Toggle watch mode in \(.applicationName)",
                "Set \(.applicationName) watch mode",
            ],
            shortTitle: "Set Watch Mode",
            systemImageName: "eye"
        )
    }
}
