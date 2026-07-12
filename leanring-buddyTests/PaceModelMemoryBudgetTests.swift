//
//  PaceModelMemoryBudgetTests.swift
//  leanring-buddyTests
//
//  Covers the pure RAM-budget math: cloud/Apple-FM planners free the
//  budget for a bigger local vision model, over-budget detection, and
//  the largest-VLM-that-fits search at a couple of RAM sizes.
//

import Foundation
import Testing
@testable import Pace

struct PaceModelMemoryBudgetTests {

    // MARK: - Fixtures

    /// A minimal-footprint non-planner, non-VLM stack: Apple Speech (0),
    /// AVSpeechSynthesizer (0), Apple NaturalLanguage (0). Isolates the
    /// planner + VLM interaction the feature is about.
    private func configuration(
        planner: PacePlannerMemoryVariant,
        vision: PaceVisionModelSizeTier
    ) -> PaceModelMemoryConfiguration {
        PaceModelMemoryConfiguration(
            plannerVariant: planner,
            visionTier: vision,
            speechToTextVariant: .appleSpeech,
            textToSpeechVariant: .appleAVSpeechSynthesizer,
            embedderVariant: .appleNaturalLanguage
        )
    }

    // MARK: - Cloud planner frees budget for a bigger VLM

    @Test func cloudPlannerLetsAnEightBVLMFitWhereLocalThirtyBDoesNot() async throws {
        // A 32 GB Mac → 26 GB usable budget (32 - 6 reserved).
        let usableBudgetGB = PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 32)
        #expect(usableBudgetGB == 26)

        // With the local LM Studio 30B planner (18.6 GB) + an 8B VLM
        // (6 GB) the total is 24.6 GB — that actually still fits at 26.
        // Push the planner + VLM into collision by adding WhisperKit +
        // Kokoro so the honest "big local planner crowds out a big VLM"
        // story is visible.
        let localHeavyConfig = PaceModelMemoryConfiguration(
            plannerVariant: .localLMStudioQwen3_30B,
            visionTier: .qwen3VL8B,
            speechToTextVariant: .whisperKitLarge,
            textToSpeechVariant: .kokoroSidecar,
            embedderVariant: .mlxNomic
        )
        let localResult = PaceModelMemoryBudget.evaluate(
            configuration: localHeavyConfig,
            usableBudgetGB: usableBudgetGB
        )
        // 18.6 + 6 + 1.5 + 0.4 + 0.25 = 26.75 > 26 → over budget.
        #expect(localResult.fits == false)

        // Offload the planner to the cloud (0 GB) — the same rest-of-stack
        // now fits comfortably.
        let cloudConfig = PaceModelMemoryConfiguration(
            plannerVariant: .cloudOffDevice,
            visionTier: .qwen3VL8B,
            speechToTextVariant: .whisperKitLarge,
            textToSpeechVariant: .kokoroSidecar,
            embedderVariant: .mlxNomic
        )
        let cloudResult = PaceModelMemoryBudget.evaluate(
            configuration: cloudConfig,
            usableBudgetGB: usableBudgetGB
        )
        // 0 + 6 + 1.5 + 0.4 + 0.25 = 8.15 ≤ 26 → fits.
        #expect(cloudResult.fits == true)
        #expect(cloudResult.headroomGB > localResult.headroomGB)
    }

    // MARK: - Over-budget detection

    @Test func localThirtyBPlannerPlus30BClassVLMIsOverBudgetOn16GB() async throws {
        // A 16 GB Mac → 10 GB usable budget (16 - 6 reserved).
        let usableBudgetGB = PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 16)
        #expect(usableBudgetGB == 10)

        let config = configuration(planner: .localLMStudioQwen3_30B, vision: .qwen3VL30BClass)
        let result = PaceModelMemoryBudget.evaluate(
            configuration: config,
            usableBudgetGB: usableBudgetGB
        )
        // 18.6 + 18 = 36.6, way over 10.
        #expect(result.fits == false)
        #expect(result.headroomGB < 0)
        // Over by 36.6 - 10 = 26.6 GB.
        #expect(abs(result.headroomGB - (-26.6)) < 0.001)
        #expect(result.totalGB == 36.6)
    }

    @Test func exactlyOnBudgetStillCountsAsFits() async throws {
        // Construct a budget that the total lands on exactly. Cloud
        // planner (0) + 8B VLM (6) + WhisperKit (1.5) + Kokoro (0.4) +
        // nomic (0.25) = 8.15.
        let config = PaceModelMemoryConfiguration(
            plannerVariant: .cloudOffDevice,
            visionTier: .qwen3VL8B,
            speechToTextVariant: .whisperKitLarge,
            textToSpeechVariant: .kokoroSidecar,
            embedderVariant: .mlxNomic
        )
        let result = PaceModelMemoryBudget.evaluate(configuration: config, usableBudgetGB: 8.15)
        #expect(result.fits == true)
        #expect(abs(result.headroomGB) < 0.001)
    }

    // MARK: - largestVLMThatFits

    @Test func largestVLMThatFitsPicksEightBWithCloudPlannerOn16GB() async throws {
        // 16 GB → 10 GB usable. Cloud planner frees the budget: non-VLM
        // footprint is just the tiny always-on models.
        let usableBudgetGB = PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 16)
        let cloudConfig = configuration(planner: .cloudOffDevice, vision: .off)
        // Non-VLM footprint here is 0 (Apple everything). 8B VLM (6) fits
        // under 10; 30B-class (18) does not.
        let largest = PaceModelMemoryBudget.largestVLMThatFits(
            givenConfiguration: cloudConfig,
            usableBudgetGB: usableBudgetGB
        )
        #expect(largest == .qwen3VL8B)
    }

    @Test func largestVLMThatFitsPicks30BClassWithCloudPlannerOn64GB() async throws {
        // 64 GB → 58 GB usable. Plenty of room for the 30B-class VLM.
        let usableBudgetGB = PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 64)
        #expect(usableBudgetGB == 58)
        let cloudConfig = configuration(planner: .cloudOffDevice, vision: .off)
        let largest = PaceModelMemoryBudget.largestVLMThatFits(
            givenConfiguration: cloudConfig,
            usableBudgetGB: usableBudgetGB
        )
        #expect(largest == .qwen3VL30BClass)
    }

    @Test func largestVLMThatFitsShrinksWhenLocalThirtyBPlannerConsumesBudget() async throws {
        // 32 GB → 26 GB usable. Local 30B planner eats 18.6 → only 7.4
        // left for the VLM. 8B (6) fits, 30B-class (18) does not.
        let usableBudgetGB = PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 32)
        let localConfig = configuration(planner: .localLMStudioQwen3_30B, vision: .off)
        let largest = PaceModelMemoryBudget.largestVLMThatFits(
            givenConfiguration: localConfig,
            usableBudgetGB: usableBudgetGB
        )
        #expect(largest == .qwen3VL8B)

        // Contrast: same machine, cloud planner → the 30B-class VLM fits.
        let cloudConfig = configuration(planner: .cloudOffDevice, vision: .off)
        let largestWithCloud = PaceModelMemoryBudget.largestVLMThatFits(
            givenConfiguration: cloudConfig,
            usableBudgetGB: usableBudgetGB
        )
        #expect(largestWithCloud == .qwen3VL30BClass)
    }

    @Test func largestVLMThatFitsFallsBackToOffWhenNothingFits() async throws {
        // A pathologically small budget where even the 2B VLM (2 GB)
        // overruns the non-VLM footprint. largestVLMThatFits must never
        // return nil — it returns `.off`.
        let largest = PaceModelMemoryBudget.largestVLMThatFits(
            givenNonVLMFootprintGB: 1.5,
            usableBudgetGB: 2.0
        )
        // 1.5 + 2 (smallest real VLM) = 3.5 > 2 → nothing real fits.
        #expect(largest == .off)
    }

    // MARK: - Apple FM planner ≈ 0

    @Test func appleFoundationModelsPlannerCostsZeroLocalRAM() async throws {
        #expect(PacePlannerMemoryVariant.appleFoundationModels.estimatedResidentRAMGB == 0)
        #expect(PacePlannerMemoryVariant.appleFoundationModels.runsWithoutLocalPlannerRAM == true)

        let config = configuration(planner: .appleFoundationModels, vision: .qwen3VL8B)
        let result = PaceModelMemoryBudget.evaluate(configuration: config, usableBudgetGB: 10)
        // Only the 8B VLM (6) counts; everything else is Apple/off = 0.
        #expect(result.totalGB == 6)
        #expect(result.fits == true)
    }

    @Test func cloudTiersAndAppleFMBothReportFreeingLocalPlannerRAM() async throws {
        #expect(PacePlannerMemoryVariant.cloudOffDevice.runsWithoutLocalPlannerRAM == true)
        #expect(PacePlannerMemoryVariant.cloudOffDevice.estimatedResidentRAMGB == 0)
        // Local variants must NOT report as freeing local RAM.
        #expect(PacePlannerMemoryVariant.localLMStudioQwen3_30B.runsWithoutLocalPlannerRAM == false)
        #expect(PacePlannerMemoryVariant.localMLXQwen3_4BBF16.runsWithoutLocalPlannerRAM == false)
        #expect(PacePlannerMemoryVariant.localMLXQwen3_4B4Bit.runsWithoutLocalPlannerRAM == false)
    }

    // MARK: - Planner-tier → memory-variant mapping

    @Test func plannerTierMappingResolvesCloudAndAppleFMToZeroRAMVariants() async throws {
        #expect(
            PaceModelMemoryBudget.plannerMemoryVariant(
                forTier: .appleFoundationModels,
                usesBundledMLXPlanner: false,
                bundledMLXPlannerModelIdentifier: ""
            ) == .appleFoundationModels
        )
        for cloudTier in [PacePlannerTier.cliBridge, .cliDirect, .directAPI] {
            #expect(
                PaceModelMemoryBudget.plannerMemoryVariant(
                    forTier: cloudTier,
                    usesBundledMLXPlanner: false,
                    bundledMLXPlannerModelIdentifier: ""
                ) == .cloudOffDevice
            )
        }
    }

    @Test func localTierMapsToLMStudio30BWhenBundledMLXIsOff() async throws {
        let variant = PaceModelMemoryBudget.plannerMemoryVariant(
            forTier: .local,
            usesBundledMLXPlanner: false,
            bundledMLXPlannerModelIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-bf16"
        )
        #expect(variant == .localLMStudioQwen3_30B)
    }

    @Test func localTierWithBundledMLXReadsBF16VersusFourBitFromIdentifier() async throws {
        let bf16Variant = PaceModelMemoryBudget.plannerMemoryVariant(
            forTier: .local,
            usesBundledMLXPlanner: true,
            bundledMLXPlannerModelIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-bf16"
        )
        #expect(bf16Variant == .localMLXQwen3_4BBF16)
        #expect(bf16Variant.estimatedResidentRAMGB == 8)

        let fourBitVariant = PaceModelMemoryBudget.plannerMemoryVariant(
            forTier: .local,
            usesBundledMLXPlanner: true,
            bundledMLXPlannerModelIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        )
        #expect(fourBitVariant == .localMLXQwen3_4B4Bit)
        #expect(fourBitVariant.estimatedResidentRAMGB == 3)
    }

    // MARK: - Vision-tier identifier round-trip

    @Test func visionTierResolvesFromKnownModelIdentifiers() async throws {
        #expect(PaceVisionModelSizeTier.tier(forVLMModelIdentifier: "ui-venus-1.5-2b") == .uiVenus2B)
        #expect(PaceVisionModelSizeTier.tier(forVLMModelIdentifier: "mlx-community/Qwen3-VL-4B-Instruct-4bit") == .qwen3VL4B)
        #expect(PaceVisionModelSizeTier.tier(forVLMModelIdentifier: "qwen3-vl-8b-instruct") == .qwen3VL8B)
        #expect(PaceVisionModelSizeTier.tier(forVLMModelIdentifier: "mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit") == .qwen3VL30BClass)
    }

    @Test func visionTierIdentifiersAreNonEmptyForPickableTiers() async throws {
        for visionTier in PaceVisionModelSizeTier.allCases where visionTier != .off {
            let identifier = try #require(visionTier.vlmModelIdentifier)
            #expect(!identifier.isEmpty)
        }
        #expect(PaceVisionModelSizeTier.off.vlmModelIdentifier == nil)
    }

    // MARK: - Usable-budget floor

    @Test func usableBudgetNeverGoesBelowFloorOnTinyMachines() async throws {
        // An 8 GB Mac: 8 - 6 = 2, which equals the floor. A 4 GB Mac:
        // 4 - 6 = -2 → clamped up to the 2 GB floor.
        #expect(PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 8) == 2)
        #expect(PaceModelMemoryBudget.usableBudgetGB(totalPhysicalRAMGB: 4) == 2)
    }
}
