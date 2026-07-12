//
//  PaceBundledModelsSettingsTab.swift
//  leanring-buddy
//
//  Settings → Models tab. Toggles + model identifiers for the
//  in-process MLX runtime. Default state is OFF — existing users
//  must explicitly opt in. The runtime-status row at the top
//  surfaces whether the `mlx-swift-examples` SPM dependency is
//  actually linked, so users aren't left guessing.
//
//  First inference call after enabling the toggle triggers a one-
//  time HuggingFace download via the Hub package built into
//  mlx-swift-examples (~2-3 GB for the 4B planner, ~250 MB for the
//  nomic embedder). No progress UI in this view — the download is
//  blocking on the first turn, and the panel HUD's "thinking…"
//  state already covers that wait visually.
//

import AppKit
import SwiftUI

struct PaceBundledModelsSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var downloadManager = PaceModelDownloadManager.shared

    @State private var isUsingMLXPlanner: Bool = false
    @State private var isUsingMLXEmbedder: Bool = false
    @State private var isUsingMLXVLM: Bool = false
    @State private var isUsingQwen3TTS: Bool = false
    @State private var plannerModelIdentifier: String = ""
    @State private var embedderModelIdentifier: String = ""
    @State private var vlmModelIdentifier: String = ""
    @State private var isPaceTunedTurnExportEnabled: Bool = PaceUserPreferencesStore
        .bool(.isPaceTunedTurnExportEnabled, default: true)

    // Prefetch state — drives the "Download now" UX so users can
    // warm the model on wifi before the first PTT pays the cost.
    @State private var isPlannerPrefetchInFlight: Bool = false
    @State private var plannerPrefetchProgressFraction: Double = 0
    @State private var lastPlannerPrefetchOutcome: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            runtimeStatusSection
            Divider().background(DS.Colors.borderSubtle)
            memoryBudgetSection
            Divider().background(DS.Colors.borderSubtle)
            plannerSection
            Divider().background(DS.Colors.borderSubtle)
            embedderSection
            Divider().background(DS.Colors.borderSubtle)
            vlmSection
            Divider().background(DS.Colors.borderSubtle)
            ttsSection
            Divider().background(DS.Colors.borderSubtle)
            paceTunedExportSection
            Divider().background(DS.Colors.borderSubtle)
            qualityCaveatSection
        }
        .onAppear {
            loadCurrentSettings()
            downloadManager.refreshStates()
        }
    }

    // MARK: - Memory budget section (RAM-aware provider budget)
    //
    // Pace loads several models that share physical RAM at once. The
    // planner is the biggest lever: offloading it to the cloud or to
    // Apple Foundation Models frees its RAM for a larger local vision
    // model — exactly where Pace most needs quality. This section makes
    // that budget + tradeoff visible and lets the user pick a VLM size
    // whose fit math updates live. It is advisory only — it never
    // changes model defaults or the actual loading paths; the one thing
    // it writes is the chosen VLM identifier through the existing
    // PaceBundledModelsSettings setter.

    private var memoryBudgetSection: some View {
        let configuration = currentMemoryConfiguration
        let usableBudgetGB = PaceModelMemoryBudget.usableBudgetGBForThisMachine
        let budgetResult = PaceModelMemoryBudget.evaluate(
            configuration: configuration,
            usableBudgetGB: usableBudgetGB
        )
        let plannerVariant = configuration.plannerVariant

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory budget")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("These on-device models share your Mac's RAM. Estimates are for resident memory while each model is loaded — advisory only, they don't change what runs.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            memoryTotalRAMRow(usableBudgetGB: usableBudgetGB)
            memoryPerModelBreakdown(budgetResult: budgetResult)
            memoryTotalVersusBudgetRow(budgetResult: budgetResult)

            if plannerVariant.runsWithoutLocalPlannerRAM {
                offDevicePlannerCallout(
                    configuration: configuration,
                    usableBudgetGB: usableBudgetGB,
                    plannerVariant: plannerVariant
                )
            } else {
                localPlannerConsumesBudgetCallout(plannerVariant: plannerVariant)
            }

            vlmSizePicker(
                configuration: configuration,
                usableBudgetGB: usableBudgetGB
            )
        }
    }

    /// Total physical RAM + usable-budget headline row.
    private func memoryTotalRAMRow(usableBudgetGB: Double) -> some View {
        let totalPhysicalRAMGB = PaceModelMemoryBudget.totalPhysicalRAMGB
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
            Text("\(formatGB(totalPhysicalRAMGB)) total RAM")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            Text("· \(formatGB(usableBudgetGB)) spendable on models")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
        }
    }

    /// Per-model breakdown: role → chosen model → GB.
    private func memoryPerModelBreakdown(budgetResult: PaceModelMemoryBudgetResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(budgetResult.perModelBreakdown, id: \.role) { lineItem in
                HStack(spacing: 8) {
                    Text(lineItem.role.displayLabel)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 120, alignment: .leading)
                    Text(lineItem.chosenModelLabel)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text(formatGB(lineItem.estimatedResidentRAMGB))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(
                            lineItem.estimatedResidentRAMGB > 0
                                ? DS.Colors.textPrimary
                                : DS.Colors.textTertiary
                        )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    /// Total-vs-budget bar + fits/over-budget verdict.
    private func memoryTotalVersusBudgetRow(budgetResult: PaceModelMemoryBudgetResult) -> some View {
        let fits = budgetResult.fits
        let verdictColor = fits ? DS.Colors.success : DS.Colors.warning
        // Fraction of the usable budget the total occupies, clamped to
        // [0, 1] so the fill never overruns the track when over budget.
        let fillFraction = budgetResult.usableBudgetGB > 0
            ? min(max(budgetResult.totalGB / budgetResult.usableBudgetGB, 0), 1)
            : 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: fits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(verdictColor)
                Text(fits ? "Fits" : "Over budget")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(verdictColor)
                Spacer()
                Text("\(formatGB(budgetResult.totalGB)) / \(formatGB(budgetResult.usableBudgetGB))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(DS.Colors.textSecondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(verdictColor.opacity(0.85))
                        .frame(width: geometry.size.width * fillFraction)
                }
            }
            .frame(height: 8)
            Text(
                fits
                    ? "\(formatGB(budgetResult.headroomGB)) headroom"
                    : "\(formatGB(-budgetResult.headroomGB)) over — shrink the vision model or offload the planner"
            )
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textSecondary)
        }
    }

    /// The key callout: planner runs off-device, so the freed RAM is
    /// available for a bigger local vision model.
    private func offDevicePlannerCallout(
        configuration: PaceModelMemoryConfiguration,
        usableBudgetGB: Double,
        plannerVariant: PacePlannerMemoryVariant
    ) -> some View {
        // How much a larger VLM can now claim: the budget minus the
        // non-VLM footprint (the VLM's own share of the spendable RAM).
        let nonVLMFootprintGB = PaceModelMemoryBudget.nonVLMFootprintGB(configuration: configuration)
        let freeForVLMGB = max(usableBudgetGB - nonVLMFootprintGB, 0)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Planner runs off-device")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("\(plannerVariant.displayLabel) uses ~0 GB of local RAM, so about \(formatGB(freeForVLMGB)) is free for a larger local vision model — where quality matters most.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DS.Colors.accent.opacity(0.10))
        )
    }

    /// The honest tradeoff when the planner is local: it's consuming the
    /// budget, so a big VLM won't fit alongside it.
    private func localPlannerConsumesBudgetCallout(
        plannerVariant: PacePlannerMemoryVariant
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Local planner is using the budget")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("\(plannerVariant.displayLabel) holds ~\(formatGB(plannerVariant.estimatedResidentRAMGB)) resident. Switch the planner to a cloud tier or Apple Foundation Models (Settings → Planner) to free that RAM for a larger vision model.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
    }

    /// Vision-model size picker. Updates the fit math live and writes the
    /// chosen VLM identifier through PaceBundledModelsSettings. Each tier
    /// button shows the tier's own fit verdict against the current budget,
    /// and the largest-that-fits tier is called out as the recommendation.
    private func vlmSizePicker(
        configuration: PaceModelMemoryConfiguration,
        usableBudgetGB: Double
    ) -> some View {
        let nonVLMFootprintGB = PaceModelMemoryBudget.nonVLMFootprintGB(configuration: configuration)
        let recommendedTier = PaceModelMemoryBudget.largestVLMThatFits(
            givenNonVLMFootprintGB: nonVLMFootprintGB,
            usableBudgetGB: usableBudgetGB
        )
        let selectedTier = configuration.visionTier
        // Only the tiers that map to a concrete identifier are pickable —
        // `.off` is owned by the VLM enable toggle above, not this picker.
        let pickableTiers = PaceVisionModelSizeTier.allCases.filter { $0 != .off }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Vision model size")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("Recommended: \(recommendedTier.displayLabel)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)
            }
            HStack(spacing: 8) {
                ForEach(pickableTiers, id: \.self) { visionTier in
                    vlmSizeButton(
                        visionTier: visionTier,
                        selectedTier: selectedTier,
                        nonVLMFootprintGB: nonVLMFootprintGB,
                        usableBudgetGB: usableBudgetGB
                    )
                }
                Spacer()
            }
        }
    }

    private func vlmSizeButton(
        visionTier: PaceVisionModelSizeTier,
        selectedTier: PaceVisionModelSizeTier,
        nonVLMFootprintGB: Double,
        usableBudgetGB: Double
    ) -> some View {
        let isSelected = visionTier == selectedTier
        let tierFits = (nonVLMFootprintGB + visionTier.estimatedResidentRAMGB) <= usableBudgetGB + 0.0001
        let borderColor = isSelected ? DS.Colors.accent : DS.Colors.borderSubtle
        return Button(action: { selectVisionTier(visionTier) }) {
            VStack(spacing: 3) {
                Text(visionTier.displayLabel)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                HStack(spacing: 3) {
                    Image(systemName: tierFits ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(tierFits ? DS.Colors.success : DS.Colors.warning)
                    Text(formatGB(visionTier.estimatedResidentRAMGB))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.14) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(
            tierFits
                ? "Fits in the current budget"
                : "Larger than the current budget — offload the planner first"
        )
    }

    /// Write the picked VLM size tier's identifier through the existing
    /// PaceBundledModelsSettings setter and refresh the local field so the
    /// VLM section's text field stays in sync.
    private func selectVisionTier(_ visionTier: PaceVisionModelSizeTier) {
        guard let identifier = visionTier.vlmModelIdentifier else { return }
        PaceBundledModelsSettings.setVLMModelIdentifier(identifier)
        vlmModelIdentifier = PaceBundledModelsSettings.vlmModelIdentifier()
    }

    /// Build the live memory configuration from the current planner tier
    /// (read from the published CompanionManager state so the section
    /// reacts to tier changes without a reload) and the bundled-model +
    /// provider settings.
    private var currentMemoryConfiguration: PaceModelMemoryConfiguration {
        let plannerVariant = PaceModelMemoryBudget.plannerMemoryVariant(
            forTier: companionManager.activePlannerTier,
            usesBundledMLXPlanner: isUsingMLXPlanner,
            bundledMLXPlannerModelIdentifier: plannerModelIdentifier
        )
        // Vision tier: off when the VLM path is disabled, otherwise
        // derived from the chosen VLM identifier so the picker and the
        // breakdown agree on the current size.
        let visionTier: PaceVisionModelSizeTier = isUsingMLXVLM
            ? PaceVisionModelSizeTier.tier(forVLMModelIdentifier: vlmModelIdentifier)
            : .off
        // ASR / TTS / embedder: honest estimates from the active provider
        // choices. WhisperKit is the declared transcription provider (it
        // currently falls back to Apple Speech at runtime, but we cost it
        // as WhisperKit-large since that's the model it will load once the
        // streaming bridge lands). TTS is the Qwen3 TTSKit variant when
        // the in-process toggle is on, else the Kokoro sidecar default.
        let speechToTextVariant: PaceSpeechToTextMemoryVariant = currentTranscriptionUsesWhisperKit
            ? .whisperKitLarge
            : .appleSpeech
        let textToSpeechVariant: PaceTextToSpeechMemoryVariant = {
            if isUsingQwen3TTS { return .ttsKitQwen3 }
            return currentTTSUsesAppleDirectly ? .appleAVSpeechSynthesizer : .kokoroSidecar
        }()
        let embedderVariant: PaceEmbedderMemoryVariant = isUsingMLXEmbedder ? .mlxNomic : .appleNaturalLanguage

        return PaceModelMemoryConfiguration(
            plannerVariant: plannerVariant,
            visionTier: visionTier,
            speechToTextVariant: speechToTextVariant,
            textToSpeechVariant: textToSpeechVariant,
            embedderVariant: embedderVariant
        )
    }

    /// True when the declared transcription provider is WhisperKit (the
    /// Info.plist default). Read here so the budget reflects the model the
    /// ASR path is configured to load.
    private var currentTranscriptionUsesWhisperKit: Bool {
        let provider = (Bundle.main.object(forInfoDictionaryKey: "TranscriptionProvider") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return provider == "whisperkit"
    }

    /// True when the TTS provider is `apple` (always AVSpeechSynthesizer).
    /// Otherwise the Kokoro sidecar default is assumed.
    private var currentTTSUsesAppleDirectly: Bool {
        let provider = (Bundle.main.object(forInfoDictionaryKey: "TTSProvider") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return provider == "apple"
    }

    /// Format a GB value for display: one decimal, dropping a trailing
    /// ".0" so "8 GB" reads cleaner than "8.0 GB" while "18.6 GB" keeps
    /// its precision.
    private func formatGB(_ gigabytes: Double) -> String {
        let rounded = (gigabytes * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f GB", rounded)
        }
        return String(format: "%.1f GB", rounded)
    }

    // MARK: - VLM section (Phase C)

    private var vlmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXVLM) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX vision model")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run Qwen3-VL screen analysis via mlx-swift in-process. Drops LM Studio's max-loaded-models requirement for the VLM path. Same model as the LM Studio default — quality unchanged, latency improves by removing the HTTP loopback.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXScreenAnalysisClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXVLM) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessVLM(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "mlx-community/Qwen3-VL-4B-Instruct-4bit",
                    text: $vlmModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXVLM)
                .onSubmit { commitVLMModelIdentifier() }
                Button("Apply") { commitVLMModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXVLM)
            }
            Text("~2.5 GB download on first use. Memory cost ~3 GB resident while the VLM is loaded.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - TTS section (Phase D)

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingQwen3TTS) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process Qwen3 TTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run text-to-speech via WhisperKit's TTSKit instead of the Kokoro Python sidecar. Drops the start-tts-server.sh dependency. ANE-accelerated, sub-200 ms first-audio-out.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceQwen3TTSClient.isRuntimeAvailable)
            .onChange(of: isUsingQwen3TTS) { _, newValue in
                PaceBundledModelsSettings.setUsingQwen3TTSInProcess(newValue)
            }
            Text("~300 MB download on first use. Voice + language are auto-resolved by TTSKit's defaults; per-voice configuration UI is a follow-up.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Runtime status

    private var runtimeStatusSection: some View {
        let plannerLinked = PaceMLXPlannerClient.isRuntimeAvailable
        let embedderLinked = PaceMLXEmbeddingClient.isRuntimeAvailable
        let summaryText = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: plannerLinked,
            embedderRuntimeAvailable: embedderLinked
        )
        let isHealthy = plannerLinked && embedderLinked
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isHealthy ? .green : .yellow)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("MLX Runtime")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(summaryText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Planner section

    private var plannerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXPlanner) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX planner")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run the planner via mlx-swift in-process. Drops the LM Studio install dependency for new users. Default ships with Qwen3-4B-Instruct-2507 bf16 + a plan-then-execute prompt scaffold — high-precision, opt-in.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXPlannerClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXPlanner) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessPlanner(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "mlx-community/Qwen3-4B-Instruct-2507-bf16",
                    text: $plannerModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXPlanner)
                .onSubmit { commitPlannerModelIdentifier() }
                Button("Apply") { commitPlannerModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXPlanner)
            }
            // Fast Mode preset — swaps the bf16 identifier for the
            // 4-bit variant of the same checkpoint. ~2x faster
            // inference, ~3x less RAM, ~1-2 points lower on the
            // FM-fixture eval set. Right call on 16 GB Macs.
            HStack(spacing: 10) {
                Button(action: applyFastModePlannerPreset) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text("Fast mode (4-bit)")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!isUsingMLXPlanner || isOnFastModeIdentifier)
                Button(action: applyHighQualityPlannerPreset) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("High quality (bf16)")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!isUsingMLXPlanner || isOnHighQualityIdentifier)
                Spacer()
            }
            Text("On first use, ~8 GB is downloaded into the HuggingFace cache (~/.cache/huggingface). bf16 trades disk + RAM for materially better accuracy than the 4-bit variant; on 16 GB Macs use Fast mode instead. Subsequent launches load from cache.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Prefetch button — lets the user warm the model on
            // wifi instead of paying the multi-GB download wait on
            // their first PTT.
            HStack(spacing: 10) {
                Button(action: triggerPlannerPrefetch) {
                    HStack(spacing: 6) {
                        if isPlannerPrefetchInFlight {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(isPlannerPrefetchInFlight ? "Downloading…" : "Download now")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPlannerPrefetchInFlight || !PaceMLXPlannerClient.isRuntimeAvailable)
                if isPlannerPrefetchInFlight {
                    ProgressView(value: plannerPrefetchProgressFraction)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.0f%%", plannerPrefetchProgressFraction * 100))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
            }
            if let lastPlannerPrefetchOutcome {
                Text(lastPlannerPrefetchOutcome)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func triggerPlannerPrefetch() {
        guard !isPlannerPrefetchInFlight else { return }
        isPlannerPrefetchInFlight = true
        plannerPrefetchProgressFraction = 0
        lastPlannerPrefetchOutcome = nil
        let modelIdentifierSnapshot = PaceBundledModelsSettings.plannerModelIdentifier()
        Task { @MainActor in
            do {
                try await PaceMLXPlannerClient.prefetchModel(
                    modelIdentifier: modelIdentifierSnapshot,
                    progressHandler: { progress in
                        Task { @MainActor in
                            plannerPrefetchProgressFraction = progress.fractionCompleted
                        }
                    }
                )
                lastPlannerPrefetchOutcome = "Downloaded — model ready for first PTT"
                plannerPrefetchProgressFraction = 1.0
            } catch {
                lastPlannerPrefetchOutcome = "Download failed: \(error.localizedDescription)"
            }
            isPlannerPrefetchInFlight = false
        }
    }

    // MARK: - Embedder section

    private var embedderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXEmbedder) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX embedder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run semantic-memory embeddings via mlx-swift in-process. Falls back to Apple NaturalLanguage when the model isn't downloaded yet — safe to flip on.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXEmbeddingClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXEmbedder) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessEmbedder(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "nomic-ai/nomic-embed-text-v1.5",
                    text: $embedderModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXEmbedder)
                .onSubmit { commitEmbedderModelIdentifier() }
                Button("Apply") { commitEmbedderModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXEmbedder)
            }
            Text("~250 MB download on first use. Lower recall than LM Studio's nomic model but works offline with zero install steps.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Pausable download row — shows current state + cancel/
            // resume buttons. Inspired by ORB's pausable model
            // downloads.
            if isUsingMLXEmbedder, let entry = embedderDownloadEntry {
                embedderDownloadRow(entry: entry)
            }
        }
    }

    /// The MLX embedder's download entry from the shared download
    /// manager, if it exists.
    private var embedderDownloadEntry: PaceModelDownloadEntry? {
        PaceModelDownloadManager.shared.entries.first(where: { $0.id == "mlx-embedder" })
    }

    /// Download state row with cancel/resume buttons.
    private func embedderDownloadRow(entry: PaceModelDownloadEntry) -> some View {
        HStack(spacing: 10) {
            switch entry.state {
            case .idle:
                Button("Download now") {
                    PaceModelDownloadManager.shared.startDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
                Text("Not downloaded yet — first use will fetch it.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            case .downloading:
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                Text("Downloading…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Cancel") {
                    PaceModelDownloadManager.shared.cancelDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
            case .cancelled:
                Text("Download cancelled — partial cache saved.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Resume") {
                    PaceModelDownloadManager.shared.startDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
            case .ready:
                Text("Model ready")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.success)
            case .failed(let message):
                Text("Download failed: \(message)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                Spacer()
                Button("Retry") {
                    PaceModelDownloadManager.shared.startDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Pace-tuned dataset export

    private var paceTunedExportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isPaceTunedTurnExportEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Contribute anonymized planner turns")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("On by default. Planner turns — including cloud ones like Codex — append to ~/Library/Application Support/Pace/pace-tuned-turns.jsonl after emails, phone numbers, and home paths are redacted; each turn is tagged with which brain produced it. The file never leaves your Mac. Copy into the repo with bash scripts/export-pace-tuned-turns.sh before training. Turn off to stop collecting.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: isPaceTunedTurnExportEnabled) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isPaceTunedTurnExportEnabled)
                if !newValue {
                    PaceTunedTurnExportTrace.clear()
                }
            }
        }
    }

    // MARK: - Quality caveat

    private var qualityCaveatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Bundled MLX is the right choice when you don't have LM Studio installed and don't want to install it. The 4B planner scores ~3-4 points below qwen3-30b-a3b on Pace's FM-fixture eval set, mostly affecting multi-step agent reasoning. For day-to-day voice turns the gap is small. The embedder is a cleaner swap — Apple NaturalLanguage fallback keeps recall working when the MLX model isn't loaded yet.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings IO

    private func loadCurrentSettings() {
        isUsingMLXPlanner = PaceBundledModelsSettings.isUsingMLXInProcessPlanner()
        isUsingMLXEmbedder = PaceBundledModelsSettings.isUsingMLXInProcessEmbedder()
        isUsingMLXVLM = PaceBundledModelsSettings.isUsingMLXInProcessVLM()
        isUsingQwen3TTS = PaceBundledModelsSettings.isUsingQwen3TTSInProcess()
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
        embedderModelIdentifier = PaceBundledModelsSettings.embedderModelIdentifier()
        vlmModelIdentifier = PaceBundledModelsSettings.vlmModelIdentifier()
    }

    private func commitVLMModelIdentifier() {
        PaceBundledModelsSettings.setVLMModelIdentifier(vlmModelIdentifier)
        vlmModelIdentifier = PaceBundledModelsSettings.vlmModelIdentifier()
    }

    private func commitPlannerModelIdentifier() {
        PaceBundledModelsSettings.setPlannerModelIdentifier(plannerModelIdentifier)
        // Reload in case the setter refused an empty/whitespace value
        // — keeps the field in sync with what was actually persisted.
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }

    private func commitEmbedderModelIdentifier() {
        PaceBundledModelsSettings.setEmbedderModelIdentifier(embedderModelIdentifier)
        embedderModelIdentifier = PaceBundledModelsSettings.embedderModelIdentifier()
    }

    // MARK: - Fast Mode preset helpers (Lever #4)

    /// True when the user's current planner identifier matches the
    /// 4-bit Fast Mode preset. Drives the "Fast mode" button's
    /// disabled state.
    private var isOnFastModeIdentifier: Bool {
        plannerModelIdentifier == PaceBundledModelsSettings.fastModePlannerModelIdentifier
    }

    /// True when the current planner identifier is the bf16
    /// "High quality" preset (the Info.plist shipping default).
    private var isOnHighQualityIdentifier: Bool {
        plannerModelIdentifier == PaceBundledModelsSettings.defaultPlannerModelIdentifier
    }

    private func applyFastModePlannerPreset() {
        let fastIdentifier = PaceBundledModelsSettings.fastModePlannerModelIdentifier
        PaceBundledModelsSettings.setPlannerModelIdentifier(fastIdentifier)
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }

    private func applyHighQualityPlannerPreset() {
        let bf16Identifier = PaceBundledModelsSettings.defaultPlannerModelIdentifier
        PaceBundledModelsSettings.setPlannerModelIdentifier(bf16Identifier)
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }
}
