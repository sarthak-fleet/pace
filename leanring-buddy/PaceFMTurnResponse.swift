//
//  PaceFMTurnResponse.swift
//  leanring-buddy
//
//  Typed output schema for Apple Foundation Models' planner path.
//
//  Why typed
//  ---------
//  The string-tag protocol ([CLICK:x,y], [POINT:x,y:label]) let the
//  3B model hallucinate coordinates — the most reliable failure mode
//  was "user asked to click X, X not in element list, model emits
//  [CLICK:1728,NNN] at the screen edge anyway." No amount of prompt
//  threatening fixed it because the model could ALWAYS write two
//  integers.
//
//  Here we replace the freeform integer fields with element IDs. The
//  prompt lists elements as `[N] role|x,y|label|text`. The model
//  picks integer IDs from that list (or -1 for "none"). The planner
//  looks the ID up in its own copy of the element list and resolves
//  to real coordinates. Coordinates can no longer be hallucinated
//  because the model never writes coordinates — only indices.
//
//  Streaming caveat
//  ----------------
//  We were using `streamResponse(to: ..., generating: String.self)`
//  to get incremental Snapshot.content for the TTS pipeline. Typed
//  Generable streaming exposes `PartiallyGenerated` which is much
//  harder to feed into our existing sentence-streaming pipeline.
//  For this first cut we use non-streaming `respond(to:generating:)`
//  and TTS the whole `spokenText` at once. TTFSW gets a bit worse
//  but correctness gets dramatically better — and we re-introduce
//  streaming as a follow-up once we know the schema is right.
//

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct PaceFMTurnResponse {
    @Guide(description: "What to say to the user, read aloud by text-to-speech. One or two short casual sentences. Lowercase, no markdown.")
    let spokenText: String

    @Guide(description: "ID of an element from the on-screen list to point the cursor at. Use the integer in brackets from the element list. Use -1 if no element should be pointed at (pure knowledge questions, or target not in list).")
    let pointAtElementId: Int

    @Guide(description: "ID of an element to click. Use the integer in brackets from the element list. Use -1 if no click is requested or if the target is not in the element list. Only emit a non-negative value when the user explicitly asked to click, tap, or press something.")
    let clickElementId: Int
}
