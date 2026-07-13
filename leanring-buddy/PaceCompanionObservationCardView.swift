//
//  PaceCompanionObservationCardView.swift
//  leanring-buddy
//
//  Shared silent-card rendering for grounded companion observations.
//

import SwiftUI

struct PaceCompanionObservationCardView: View {
    let content: PaceCompanionPresentationContent
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text("Companion observation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer(minLength: 0)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Dismiss")
            }

            Text(content.text)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(provenanceText)
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private var provenanceText: String {
        let confidencePercent = Int((content.provenance.confidence * 100).rounded())
        return "\(sourceName) · \(confidencePercent)% confidence · \(content.provenance.observedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var sourceName: String {
        switch content.provenance.source {
        case .camera: return "Camera"
        case .ambientVoice: return "Voice"
        case .screen: return "Screen"
        case .macOSContext: return "Mac context"
        case .userCorrection: return "User correction"
        }
    }
}
