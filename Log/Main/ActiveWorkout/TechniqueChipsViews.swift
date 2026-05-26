import SwiftUI

// MARK: - Phase 3.6: Technique indicators

/// Displays technique badges snapshotted at plan-build time.
/// Read-only — never touches the live SlotPrescription or TechniquePlan models.
struct TechniqueIndicatorRow: View {
    let labels: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.dsCaption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(Color.orange)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Phase 3.8: Per-set technique chips + detail sheet

/// Horizontal strip of tappable technique chips. Embedded **inside** the
/// applicable set's card (directly below the set row) so the chips read as
/// attached to that set rather than as a separate row floating in the gap
/// between set cards. Dropset techniques are excluded by the caller
/// (`buildTechniqueChips`) — those render via the unified dropset card
/// (inline summary label + drop sub-rows), never as a chip.
struct SetTechniqueChipsRow: View {
    let techniques: [TechniquePlanSnapshot]
    let onTap: (TechniquePlanSnapshot) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(techniques.indices, id: \.self) { i in
                    let snap = techniques[i]
                    Button {
                        onTap(snap)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: iconName(for: snap.type))
                                .font(.system(size: 10, weight: .semibold))
                            Text(snap.setAttachedLabel)
                                .font(.dsCaption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(Color.orange)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)
        }
        // No `.listRow*` modifiers: this strip is embedded inside a set card
        // (a VStack), not rendered as a standalone List row.
    }

    private func iconName(for type: TechniqueType) -> String {
        switch type {
        case .dropset:       return "arrow.down.circle"
        case .partialReps:   return "chart.bar.fill"
        case .restPause:     return "pause.circle"
        case .amrap:         return "infinity"
        case .toFailure:     return "flame"
        case .cluster:       return "square.grid.2x2"
        case .tempoOverride: return "metronome"
        }
    }
}

// MARK: - Technique Detail Sheet

/// Read-only detail sheet for a TechniquePlanSnapshot. No template mutation.
struct TechniqueDetailSheet: View {
    let snap: TechniquePlanSnapshot

    var body: some View {
        NavigationStack {
            List {
                Section("Applies To") {
                    let indices = snap.appliesToSetIndices
                    if !indices.isEmpty {
                        let nums = indices.sorted().map { "Set \($0 + 1)" }.joined(separator: ", ")
                        Text(nums)
                    } else {
                        Text(snap.appliesTo.displayLabel)
                    }
                }
                switch snap.type {
                case .dropset:
                    Section("Drop Set") {
                        if let n = snap.dropCount { LabeledContent("Drops", value: "\(n)") }
                        if let p = snap.dropPercent { LabeledContent("Weight reduction", value: "\(Int(p))%") }
                        if let r = snap.restSeconds, r > 0 { LabeledContent("Rest between drops", value: "\(r)s") }
                        switch snap.dropsetEffort {
                        case .amrap:             LabeledContent("Effort", value: "AMRAP")
                        case .fixedReps(let n):  LabeledContent("Reps per drop", value: "\(n)")
                        }
                    }
                case .restPause:
                    Section("Rest-Pause") {
                        if let n = snap.rounds { LabeledContent("Rounds", value: "\(n)") }
                        if let r = snap.restSeconds, r > 0 { LabeledContent("Rest", value: "\(r)s") }
                    }
                case .cluster:
                    Section("Cluster") {
                        if let n = snap.reps { LabeledContent("Reps per cluster", value: "\(n)") }
                        if let c = snap.rounds { LabeledContent("Clusters", value: "\(c)") }
                        if let r = snap.restSeconds, r > 0 { LabeledContent("Rest between clusters", value: "\(r)s") }
                    }
                case .partialReps:
                    Section("Partial Reps") {
                        if let region = snap.partialRangeNote, !region.isEmpty {
                            LabeledContent("Range", value: region)
                        }
                        if let n = snap.reps, n > 0 { LabeledContent("Partial reps", value: "\(n)") }
                    }
                case .tempoOverride:
                    Section("Tempo") {
                        if let t = snap.note, !t.isEmpty { LabeledContent("Tempo", value: t) }
                    }
                case .amrap:
                    Section("AMRAP") {
                        Text("As many reps as possible on this set.")
                            .foregroundStyle(.secondary)
                    }
                case .toFailure:
                    Section("To Failure") {
                        Text("Push to technical failure on this set.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(snap.type.displayName)
            .navigationBarTitleDisplayMode(.inline)
            // Read-only sheet: no explicit Done/close button — dismiss via the
            // drag gesture (and the system accessibility dismiss action).
            // Nothing to commit here, so an explicit close is redundant.
        }
        .presentationDetents([.medium, .large])
    }
}
