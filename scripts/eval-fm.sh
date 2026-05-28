#!/usr/bin/env bash
#
# eval-fm.sh — directly exercise Apple Foundation Models with the
# same system prompt + element map shape Pace sends, and print what
# the model emits.
#
# Why this exists
# ---------------
# The existing eval-pace.sh hits LM Studio over HTTP. It can't test
# the FoundationModels framework path because that runs in-process,
# requires macOS 26 + Apple Intelligence on the host, and isn't
# reachable via curl.
#
# Without an FM-direct test loop, every "did this fix actually work?"
# question costs a user rebuild. This script closes that loop:
# compile a tiny Swift program against the Pace source, run it
# through Foundation Models with whichever fixture, print the raw
# response. Lets us verify hallucination fixes, sampling changes,
# and prompt tweaks empirically before asking anyone to Cmd+R.
#
# Usage:
#   ./scripts/eval-fm.sh              # run all fixtures
#   ./scripts/eval-fm.sh click-file   # one fixture by name
#
# Fixtures live in evals/fm-fixtures/<name>.txt — a simple text
# format: lines starting "USER:" set the transcript, "ELEMENT:"
# lines are appended verbatim to the element map.

set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$PROJECT_DIR/evals/fm-fixtures"
SINGLE_FIXTURE_NAME="${1:-}"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo "❌ Fixtures directory not found: $FIXTURES_DIR" >&2
    exit 2
fi

EVAL_SOURCE_FILE="$(mktemp -t pace-fm-eval.XXXXXX).swift"
cat > "$EVAL_SOURCE_FILE" <<'SWIFT_EOF'
import Foundation
import FoundationModels

// Typed schema — mirrors PaceFMTurnResponse in the Pace source. The
// whole point of this eval is to verify the typed path's behavior;
// can't reach into the Pace module from a one-shot Swift script so
// the schema is duplicated here intentionally.
@available(macOS 26.0, *)
@Generable
struct EvalFMTurnResponse {
    @Guide(description: "What to say to the user, read aloud by text-to-speech. One or two short casual sentences. Lowercase, no markdown.")
    let spokenText: String

    @Guide(description: "ID of an element from the on-screen list to point the cursor at. Use the integer in brackets from the element list. Use -1 if no element should be pointed at (pure knowledge questions, or target not in list).")
    let pointAtElementId: Int

    @Guide(description: "ID of an element to click. Use the integer in brackets from the element list. Use -1 if no click is requested or if the target is not in the element list. Only emit a non-negative value when the user explicitly asked to click, tap, or press something.")
    let clickElementId: Int
}

// Match the lean system prompt Pace ships today. Kept in sync with
// CompanionSystemPrompt.swift via the README; drift acceptable since
// this is a diagnostic tool, not a regression gate.
let baseVoiceRules = """
you're pace, a voice companion in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen. your reply is read aloud, so write the way you'd actually talk.

rules:
- default to one or two sentences. be direct.
- all lowercase, casual, warm. no emojis.
- write for the ear. no lists, no bullets, no markdown.
- if the question relates to what's on screen, reference what you see. otherwise just answer the question.
"""

let pointingRules = """
pointing:
you have a cursor that can fly to and point at things on screen. when you point, append [POINT:x,y:label] at the very end. if pointing wouldn't help, append [POINT:none].

COORDINATES MUST COME FROM THE ELEMENT LIST. NEVER INVENT COORDINATES.

decide which case the user's request falls into:

A. pure knowledge question (not about anything on screen): answer it in one or two casual sentences, then append [POINT:none]. example: "html is the markup language that structures every web page. [POINT:none]"

B. user named a target that IS in the element list: emit a tag using THAT element's coordinates verbatim. example: if the list contains `button|548,40|save button|Save Draft` and the user said "save", emit [POINT:548,40:save] (and [CLICK:548,40] in agent mode).

C. user named a target that is NOT in the element list: name what they asked for back, say you can't see it, append [POINT:none], and do NOT emit any CLICK/TYPE/KEY/SCROLL tags. example: "i can't see a [thing the user said] on this screen. [POINT:none]"

case C is critical. picking a wrong but nearby element from the list is FORBIDDEN. picking screen corners or screen edges is FORBIDDEN. the only acceptable response when the target is missing is to refuse cleanly.
"""

let agentRules = """
agent mode — when the user asks you to *do* something, emit inline action tags. tags get stripped before TTS and executed in order.

available tags:
- [CLICK:x,y]               left-click at (x,y).
- [TYPE:exact text]         types into focused field.
- [KEY:Return]              press a named key. modifiers chain with +.
- [SCROLL:up:3]             scroll up 3 lines.

only emit action tags when the user clearly asked you to *do* something.
"""

let systemPrompt = baseVoiceRules + "\n\n" + pointingRules + "\n\n" + agentRules

// CLI args: fixture path + transcript + element map (the latter
// two come from the fixture file, parsed by the shell wrapper and
// passed through env vars to avoid argv length limits).
guard let transcript = ProcessInfo.processInfo.environment["PACE_FIXTURE_TRANSCRIPT"],
      let elementMap = ProcessInfo.processInfo.environment["PACE_FIXTURE_ELEMENT_MAP"] else {
    print("missing PACE_FIXTURE_TRANSCRIPT or PACE_FIXTURE_ELEMENT_MAP env vars")
    exit(2)
}

let userPrompt = """
On-device screen analysis (auto-extracted by a local vision model + native OCR):

=== primary focus ===
\(elementMap)

User said: \(transcript)
"""

// Check FM is actually available — same logic Pace uses to fall back
// gracefully when AI is off.
let modelAvailability = SystemLanguageModel.default.availability
switch modelAvailability {
case .available:
    break
case .unavailable(.appleIntelligenceNotEnabled):
    print("❌ Apple Intelligence is not enabled. Open System Settings → Apple Intelligence & Siri.")
    exit(3)
case .unavailable(.modelNotReady):
    print("⏳ Apple Intelligence model still downloading. Try again in a few minutes.")
    exit(3)
case .unavailable(.deviceNotEligible):
    print("❌ This Mac is not eligible for Apple Intelligence.")
    exit(3)
@unknown default:
    print("❓ Unknown FM availability: \(modelAvailability)")
    exit(3)
}

// Match Pace's planner config exactly so the eval reflects real behavior.
let session = LanguageModelSession(
    model: SystemLanguageModel.default,
    instructions: { systemPrompt }
)
let options = GenerationOptions(
    sampling: .greedy,
    temperature: 0,
    maximumResponseTokens: 400
)

let startedAt = Date()
let typedResponse: LanguageModelSession.Response<EvalFMTurnResponse>
do {
    typedResponse = try await session.respond(
        to: userPrompt,
        generating: EvalFMTurnResponse.self,
        options: options
    )
} catch {
    print("❌ FM error: \(error)")
    exit(4)
}

let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
print("─── PACE FM EVAL ───")
print("user said: \(transcript)")
print("element map:")
for line in elementMap.split(separator: "\n") {
    print("  \(line)")
}
print("───")
print("elapsed: \(elapsedMs)ms")
print("FM typed response:")
print("  spokenText      : \(typedResponse.content.spokenText)")
print("  pointAtElementId: \(typedResponse.content.pointAtElementId)")
print("  clickElementId  : \(typedResponse.content.clickElementId)")
print("─── END ───")
SWIFT_EOF

# Compile once; we'll re-run per fixture so the model warms.
COMPILED_EVAL_BIN="$(mktemp -t pace-fm-eval-bin.XXXXXX)"
xcrun swiftc \
    -target arm64-apple-macos26.0 \
    -O \
    -o "$COMPILED_EVAL_BIN" \
    "$EVAL_SOURCE_FILE"

run_one_fixture() {
    local fixture_path="$1"
    local fixture_name
    fixture_name=$(basename "$fixture_path" .txt)

    # Parse fixture: USER: line is the transcript, ELEMENT: lines
    # are appended (without prefix) to the element map.
    local transcript
    transcript=$(grep -m1 '^USER: ' "$fixture_path" | sed 's/^USER: //')
    local element_map
    element_map=$(grep '^ELEMENT: ' "$fixture_path" | sed 's/^ELEMENT: //')

    if [[ -z "$transcript" ]]; then
        echo "⚠️  Fixture $fixture_name has no USER: line — skipping"
        return
    fi

    echo
    echo "▶ Fixture: $fixture_name"
    PACE_FIXTURE_TRANSCRIPT="$transcript" \
        PACE_FIXTURE_ELEMENT_MAP="$element_map" \
        "$COMPILED_EVAL_BIN"
}

if [[ -n "$SINGLE_FIXTURE_NAME" ]]; then
    FIXTURE_PATH="$FIXTURES_DIR/$SINGLE_FIXTURE_NAME.txt"
    if [[ ! -f "$FIXTURE_PATH" ]]; then
        echo "❌ Fixture not found: $FIXTURE_PATH"
        exit 2
    fi
    run_one_fixture "$FIXTURE_PATH"
else
    for fixture_path in "$FIXTURES_DIR"/*.txt; do
        [[ -e "$fixture_path" ]] || continue
        run_one_fixture "$fixture_path"
    done
fi

rm -f "$EVAL_SOURCE_FILE" "$COMPILED_EVAL_BIN"
