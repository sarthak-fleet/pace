//
//  PaceModelMemoryBudget.swift
//  leanring-buddy
//
//  Pure, testable RAM-budget model for Pace's on-device model stack.
//
//  Why this exists
//  ---------------
//  Pace loads several models that all share the Mac's physical RAM at
//  once: the planner, the vision VLM, the ASR (speech-to-text) model,
//  the TTS (text-to-speech) model, and the semantic-memory embedder.
//  On a 16 GB Mac these can collide.
//
//  The single most useful lever is the planner. When the planner is
//  offloaded to the cloud (`.cliDirect` / `.cliBridge` / `.directAPI`)
//  or to Apple Foundation Models (which runs in-process, system-shared,
//  at roughly zero extra resident cost), the big local-planner RAM
//  (LM Studio Qwen3-30B ≈ 18.6 GB, or bundled MLX Qwen3-4B bf16 ≈ 8 GB)
//  is freed. That freed budget can be spent where Pace most needs
//  quality: a much larger local vision model.
//
//  This file is the ONE source of truth for the estimated resident-RAM
//  cost of each model role/variant, plus the pure math that turns a
//  selected configuration into a fit/over-budget verdict and the
//  "largest VLM that still fits" answer. No UI, no persistence, no
//  network — the only environment read is `ProcessInfo.physicalMemory`.
//
//  The GB numbers here are DOCUMENTED ESTIMATES of resident memory
//  while a model is loaded, not measured live values. They are used to
//  drive an advisory budget surface — they never gate or change the
//  actual model-loading paths.
//

import Foundation

// MARK: - Model roles

/// The five on-device model roles that share physical RAM. Each role is
/// filled by exactly one variant at a time (or none, when the role is
/// off or offloaded off-device).
nonisolated enum PaceModelRole: String, CaseIterable {
    case planner
    case visionModel
    case speechToText
    case textToSpeech
    case embedder

    /// Human-readable label for the per-model breakdown rows.
    var displayLabel: String {
        switch self {
        case .planner:       return "Planner"
        case .visionModel:   return "Vision model"
        case .speechToText:  return "Speech-to-text"
        case .textToSpeech:  return "Text-to-speech"
        case .embedder:      return "Memory embedder"
        }
    }
}

// MARK: - Planner memory variants

/// The distinct resident-RAM footprints the planner role can take. This
/// is a *memory-cost* classification, not the full planner-tier enum —
/// several cloud tiers collapse to the same "≈ 0 local RAM" bucket.
nonisolated enum PacePlannerMemoryVariant: Equatable {
    /// LM Studio `qwen3-30b-a3b` — the local default. Large resident set.
    case localLMStudioQwen3_30B
    /// Bundled in-process MLX `Qwen3-4B-Instruct-2507-bf16`.
    case localMLXQwen3_4BBF16
    /// Bundled in-process MLX 4-bit variant of the same 4B checkpoint.
    case localMLXQwen3_4B4Bit
    /// Apple Foundation Models — in-process, system-shared, ≈ 0 extra.
    case appleFoundationModels
    /// Any cloud tier (`.cliDirect` / `.cliBridge` / `.directAPI`) — the
    /// planner runs off this Mac, so ≈ 0 local RAM.
    case cloudOffDevice

    /// Estimated resident RAM in GB while this planner variant is loaded.
    var estimatedResidentRAMGB: Double {
        switch self {
        case .localLMStudioQwen3_30B:  return 18.6
        case .localMLXQwen3_4BBF16:    return 8.0
        case .localMLXQwen3_4B4Bit:    return 3.0
        case .appleFoundationModels:   return 0.0
        case .cloudOffDevice:          return 0.0
        }
    }

    /// Short label for the chosen-model column in the breakdown row.
    var displayLabel: String {
        switch self {
        case .localLMStudioQwen3_30B:  return "LM Studio Qwen3-30B"
        case .localMLXQwen3_4BBF16:    return "MLX Qwen3-4B (bf16)"
        case .localMLXQwen3_4B4Bit:    return "MLX Qwen3-4B (4-bit)"
        case .appleFoundationModels:   return "Apple Foundation Models"
        case .cloudOffDevice:          return "Cloud (off-device)"
        }
    }

    /// True when this planner variant runs off this Mac (cloud tiers or
    /// Apple FM's system-shared model). These are the cases that free the
    /// big local-planner RAM for a larger local vision model.
    var runsWithoutLocalPlannerRAM: Bool {
        switch self {
        case .appleFoundationModels, .cloudOffDevice:
            return true
        case .localLMStudioQwen3_30B, .localMLXQwen3_4BBF16, .localMLXQwen3_4B4Bit:
            return false
        }
    }
}

// MARK: - Vision model size tiers

/// The vision-model (VLM) size tiers Pace can offer, ordered smallest to
/// largest by resident RAM. `largestVLMThatFits(...)` walks these from
/// biggest to smallest to pick the best one a given budget can afford.
nonisolated enum PaceVisionModelSizeTier: String, CaseIterable, Equatable {
    /// VLM disabled — no screen-analysis model loaded.
    case off
    /// `ui-venus-1.5-2b` — the 2B GUI specialist (LM Studio default).
    case uiVenus2B
    /// `Qwen3-VL-4B-Instruct-4bit` — the bundled MLX default.
    case qwen3VL4B
    /// `qwen3-vl-8b-instruct` — meaningfully stronger screen reasoning.
    case qwen3VL8B
    /// A 30B-class VLM — best quality, needs a lot of free RAM.
    case qwen3VL30BClass

    /// Estimated resident RAM in GB while this VLM tier is loaded.
    var estimatedResidentRAMGB: Double {
        switch self {
        case .off:              return 0.0
        case .uiVenus2B:        return 2.0
        case .qwen3VL4B:        return 3.0
        case .qwen3VL8B:        return 6.0
        case .qwen3VL30BClass:  return 18.0
        }
    }

    /// Short human-readable size label used in the VLM size picker.
    var displayLabel: String {
        switch self {
        case .off:              return "Off"
        case .uiVenus2B:        return "2B (UI-Venus)"
        case .qwen3VL4B:        return "4B (Qwen3-VL)"
        case .qwen3VL8B:        return "8B (Qwen3-VL)"
        case .qwen3VL30BClass:  return "30B-class (needs lots of RAM)"
        }
    }

    /// The model identifier this tier writes through the existing
    /// `PaceBundledModelsSettings` VLM-identifier setter when the user
    /// picks it. Kept here so the picker has one place to map size →
    /// identifier. `.off` returns nil (no identifier change; the VLM
    /// enable/disable toggle owns that state).
    var vlmModelIdentifier: String? {
        switch self {
        case .off:              return nil
        case .uiVenus2B:        return "ui-venus-1.5-2b"
        case .qwen3VL4B:        return "mlx-community/Qwen3-VL-4B-Instruct-4bit"
        case .qwen3VL8B:        return "mlx-community/Qwen3-VL-8B-Instruct-4bit"
        case .qwen3VL30BClass:  return "mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit"
        }
    }

    /// Resolve a stored VLM model-identifier string back to the size tier
    /// it represents, so the picker can pre-select the user's current
    /// choice. Matching is case-insensitive and tolerant of the
    /// `org/Model` prefix. Falls back to `.qwen3VL4B` (the bundled MLX
    /// default) for identifiers we don't recognize, since an unknown
    /// custom identifier is most likely a 4B-class model.
    static func tier(forVLMModelIdentifier identifier: String) -> PaceVisionModelSizeTier {
        let lowercasedIdentifier = identifier.lowercased()
        if lowercasedIdentifier.contains("venus") {
            return .uiVenus2B
        }
        if lowercasedIdentifier.contains("30b") {
            return .qwen3VL30BClass
        }
        if lowercasedIdentifier.contains("8b") {
            return .qwen3VL8B
        }
        if lowercasedIdentifier.contains("4b") || lowercasedIdentifier.contains("2b") {
            // A bare "2b" that isn't UI-Venus still reads as a small
            // 4B-class bucket rather than the dedicated UI-Venus tier.
            return lowercasedIdentifier.contains("2b") && !lowercasedIdentifier.contains("4b")
                ? .uiVenus2B
                : .qwen3VL4B
        }
        return .qwen3VL4B
    }
}

// MARK: - Speech-to-text variants

nonisolated enum PaceSpeechToTextMemoryVariant: Equatable {
    /// WhisperKit large — on-device streaming ASR.
    case whisperKitLarge
    /// Apple Speech (`SFSpeechRecognizer`) — OS-provided, ≈ 0 extra.
    case appleSpeech

    var estimatedResidentRAMGB: Double {
        switch self {
        case .whisperKitLarge:  return 1.5
        case .appleSpeech:      return 0.0
        }
    }

    var displayLabel: String {
        switch self {
        case .whisperKitLarge:  return "WhisperKit (large)"
        case .appleSpeech:      return "Apple Speech"
        }
    }
}

// MARK: - Text-to-speech variants

nonisolated enum PaceTextToSpeechMemoryVariant: Equatable {
    /// Kokoro-82M served by the loopback mlx-audio sidecar.
    case kokoroSidecar
    /// In-process Qwen3 TTS via WhisperKit's TTSKit.
    case ttsKitQwen3
    /// `AVSpeechSynthesizer` — OS-provided, ≈ 0 extra.
    case appleAVSpeechSynthesizer

    var estimatedResidentRAMGB: Double {
        switch self {
        case .kokoroSidecar:            return 0.4
        case .ttsKitQwen3:              return 0.5
        case .appleAVSpeechSynthesizer: return 0.0
        }
    }

    var displayLabel: String {
        switch self {
        case .kokoroSidecar:            return "Kokoro sidecar"
        case .ttsKitQwen3:              return "Qwen3 TTS (TTSKit)"
        case .appleAVSpeechSynthesizer: return "AVSpeechSynthesizer"
        }
    }
}

// MARK: - Embedder variants

nonisolated enum PaceEmbedderMemoryVariant: Equatable {
    /// In-process MLX nomic embedder.
    case mlxNomic
    /// Apple NaturalLanguage fallback — OS-provided, ≈ 0 extra.
    case appleNaturalLanguage

    var estimatedResidentRAMGB: Double {
        switch self {
        case .mlxNomic:             return 0.25
        case .appleNaturalLanguage: return 0.0
        }
    }

    var displayLabel: String {
        switch self {
        case .mlxNomic:             return "MLX nomic"
        case .appleNaturalLanguage: return "Apple NaturalLanguage"
        }
    }
}

// MARK: - Selected configuration

/// A snapshot of which variant fills each model role right now. This is
/// what the budget math consumes. It carries no UI or persistence state
/// — the caller builds it from the live tier + settings.
nonisolated struct PaceModelMemoryConfiguration: Equatable {
    let plannerVariant: PacePlannerMemoryVariant
    let visionTier: PaceVisionModelSizeTier
    let speechToTextVariant: PaceSpeechToTextMemoryVariant
    let textToSpeechVariant: PaceTextToSpeechMemoryVariant
    let embedderVariant: PaceEmbedderMemoryVariant
}

// MARK: - Per-model line item

/// One row in the budget breakdown: a role, the chosen variant's label,
/// and its estimated resident RAM in GB.
nonisolated struct PaceModelMemoryLineItem: Equatable {
    let role: PaceModelRole
    let chosenModelLabel: String
    let estimatedResidentRAMGB: Double
}

// MARK: - Budget verdict

/// The full result of evaluating a configuration against the machine's
/// usable budget: the per-model breakdown, the total, the budget, and a
/// fit verdict with signed headroom.
nonisolated struct PaceModelMemoryBudgetResult: Equatable {
    let perModelBreakdown: [PaceModelMemoryLineItem]
    let totalGB: Double
    let usableBudgetGB: Double
    /// True when the total footprint stays within the usable budget.
    let fits: Bool
    /// Usable budget minus total. Positive = spare RAM; negative = over
    /// budget by this much.
    let headroomGB: Double
}

// MARK: - PaceModelMemoryBudget

/// Pure budget calculator. Static, `nonisolated`, no stored state beyond
/// the documented estimate registry encoded in the variant enums above.
nonisolated enum PaceModelMemoryBudget {

    // MARK: Physical / usable RAM

    /// Total physical RAM on this Mac in GB, read from
    /// `ProcessInfo.physicalMemory` (bytes) and converted using the
    /// binary GB (1024^3) so a "16 GB" Mac reports 16, not 17.2.
    nonisolated static var totalPhysicalRAMGB: Double {
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        return Double(physicalMemoryBytes) / (1024.0 * 1024.0 * 1024.0)
    }

    /// RAM we reserve for macOS + Pace's own non-model footprint. Models
    /// are only ever advised to spend the physical RAM MINUS this
    /// headroom — spending right up to physical RAM would swap the
    /// machine to a crawl.
    nonisolated static let reservedSystemHeadroomGB: Double = 6.0

    /// Absolute floor for the usable budget. Even on an 8 GB Mac we
    /// report at least this much spendable so the UI never shows a zero
    /// or negative budget (which would read as "nothing works").
    nonisolated static let minimumUsableBudgetGB: Double = 2.0

    /// The RAM safely spendable on models: physical minus the reserved
    /// system headroom, floored so tiny machines still get a sensible,
    /// non-negative number.
    nonisolated static func usableBudgetGB(totalPhysicalRAMGB: Double) -> Double {
        let spendable = totalPhysicalRAMGB - reservedSystemHeadroomGB
        return max(spendable, minimumUsableBudgetGB)
    }

    /// Convenience: usable budget for THIS machine.
    nonisolated static var usableBudgetGBForThisMachine: Double {
        usableBudgetGB(totalPhysicalRAMGB: totalPhysicalRAMGB)
    }

    // MARK: Budget evaluation

    /// The core pure function: given a selected configuration and a
    /// usable budget, return the per-model breakdown, total, fit verdict,
    /// and signed headroom.
    nonisolated static func evaluate(
        configuration: PaceModelMemoryConfiguration,
        usableBudgetGB: Double
    ) -> PaceModelMemoryBudgetResult {
        let perModelBreakdown: [PaceModelMemoryLineItem] = [
            PaceModelMemoryLineItem(
                role: .planner,
                chosenModelLabel: configuration.plannerVariant.displayLabel,
                estimatedResidentRAMGB: configuration.plannerVariant.estimatedResidentRAMGB
            ),
            PaceModelMemoryLineItem(
                role: .visionModel,
                chosenModelLabel: configuration.visionTier.displayLabel,
                estimatedResidentRAMGB: configuration.visionTier.estimatedResidentRAMGB
            ),
            PaceModelMemoryLineItem(
                role: .speechToText,
                chosenModelLabel: configuration.speechToTextVariant.displayLabel,
                estimatedResidentRAMGB: configuration.speechToTextVariant.estimatedResidentRAMGB
            ),
            PaceModelMemoryLineItem(
                role: .textToSpeech,
                chosenModelLabel: configuration.textToSpeechVariant.displayLabel,
                estimatedResidentRAMGB: configuration.textToSpeechVariant.estimatedResidentRAMGB
            ),
            PaceModelMemoryLineItem(
                role: .embedder,
                chosenModelLabel: configuration.embedderVariant.displayLabel,
                estimatedResidentRAMGB: configuration.embedderVariant.estimatedResidentRAMGB
            )
        ]

        let totalGB = perModelBreakdown.reduce(0.0) { runningTotal, lineItem in
            runningTotal + lineItem.estimatedResidentRAMGB
        }
        let headroomGB = usableBudgetGB - totalGB
        // A tiny positive epsilon so a total that lands exactly on the
        // budget (headroom == 0) still reads as "fits", not "over".
        let fits = headroomGB >= -0.0001

        return PaceModelMemoryBudgetResult(
            perModelBreakdown: perModelBreakdown,
            totalGB: totalGB,
            usableBudgetGB: usableBudgetGB,
            fits: fits,
            headroomGB: headroomGB
        )
    }

    // MARK: Largest-VLM-that-fits

    /// The RAM cost of everything EXCEPT the vision model, for a given
    /// configuration. This is the fixed footprint the VLM has to share
    /// the budget with — the "non-VLM footprint" the largest-fit search
    /// is measured against.
    nonisolated static func nonVLMFootprintGB(
        configuration: PaceModelMemoryConfiguration
    ) -> Double {
        return configuration.plannerVariant.estimatedResidentRAMGB
            + configuration.speechToTextVariant.estimatedResidentRAMGB
            + configuration.textToSpeechVariant.estimatedResidentRAMGB
            + configuration.embedderVariant.estimatedResidentRAMGB
    }

    /// Given the RAM already spoken for by everything except the vision
    /// model, return the LARGEST vision tier whose total (non-VLM
    /// footprint + this VLM's RAM) still fits inside the usable budget.
    ///
    /// Walks the size tiers from biggest to smallest and returns the
    /// first that fits. Always returns at least `.off` (0 GB), which fits
    /// as long as the non-VLM footprint alone is within budget — and even
    /// when it isn't, `.off` is still the honest "smallest possible"
    /// answer, so the picker never returns nil.
    nonisolated static func largestVLMThatFits(
        givenNonVLMFootprintGB nonVLMFootprintGB: Double,
        usableBudgetGB: Double
    ) -> PaceVisionModelSizeTier {
        // `.allCases` is declared smallest-to-largest above; reverse so we
        // check the most capable tier first and take the first that fits.
        let tiersLargestFirst = PaceVisionModelSizeTier.allCases.reversed()
        for visionTier in tiersLargestFirst {
            let totalWithThisVLM = nonVLMFootprintGB + visionTier.estimatedResidentRAMGB
            if totalWithThisVLM <= usableBudgetGB + 0.0001 {
                return visionTier
            }
        }
        return .off
    }

    /// Convenience over `largestVLMThatFits(givenNonVLMFootprintGB:...)`
    /// that derives the non-VLM footprint straight from a configuration.
    nonisolated static func largestVLMThatFits(
        givenConfiguration configuration: PaceModelMemoryConfiguration,
        usableBudgetGB: Double
    ) -> PaceVisionModelSizeTier {
        return largestVLMThatFits(
            givenNonVLMFootprintGB: nonVLMFootprintGB(configuration: configuration),
            usableBudgetGB: usableBudgetGB
        )
    }

    // MARK: Planner-tier → memory-variant mapping

    /// Map the user's selected `PacePlannerTier` (plus the "planner uses
    /// bundled in-process MLX" flag and the bundled-MLX model identifier)
    /// to the planner memory variant that drives the budget math.
    ///
    /// - `.local` with the bundled-MLX planner ON resolves to the MLX
    ///   4B variant (bf16 or 4-bit, read from the identifier). With the
    ///   bundled-MLX planner OFF it resolves to LM Studio Qwen3-30B, the
    ///   local default.
    /// - `.appleFoundationModels` → the ≈ 0 in-process variant.
    /// - Every cloud tier (`.cliDirect` / `.cliBridge` / `.directAPI`) →
    ///   the ≈ 0 off-device variant.
    nonisolated static func plannerMemoryVariant(
        forTier tier: PacePlannerTier,
        usesBundledMLXPlanner: Bool,
        bundledMLXPlannerModelIdentifier: String
    ) -> PacePlannerMemoryVariant {
        switch tier {
        case .appleFoundationModels:
            return .appleFoundationModels
        case .cliBridge, .cliDirect, .directAPI:
            return .cloudOffDevice
        case .local:
            guard usesBundledMLXPlanner else {
                return .localLMStudioQwen3_30B
            }
            let lowercasedIdentifier = bundledMLXPlannerModelIdentifier.lowercased()
            if lowercasedIdentifier.contains("4bit") || lowercasedIdentifier.contains("4-bit") {
                return .localMLXQwen3_4B4Bit
            }
            return .localMLXQwen3_4BBF16
        }
    }
}
