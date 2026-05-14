import SwiftUI

struct SettingsView: View {

    // MARK: - Stored Settings (backed by UserDefaults via @AppStorage)

    @AppStorage(AppSettings.Keys.weightIsKg)
    private var weightIsKg: Bool = true

    @AppStorage(AppSettings.Keys.autoregMode)
    private var autoregModeRaw: String = AutoregMode.rir.rawValue

    @AppStorage(AppSettings.Keys.defaultSets)
    private var defaultSets: Int = 3

    @AppStorage(AppSettings.Keys.defaultRepMin)
    private var defaultRepMin: Int = 8

    @AppStorage(AppSettings.Keys.defaultRepMax)
    private var defaultRepMax: Int = 12

    @AppStorage(AppSettings.Keys.defaultRestBetweenSets)
    private var defaultRestBetweenSets: Int = 90

    @AppStorage(AppSettings.Keys.defaultRestAfterExercise)
    private var defaultRestAfterExercise: Int = 0

    @AppStorage(AppSettings.Keys.defaultRIR)
    private var defaultRIR: Double = 2.0

    @AppStorage(AppSettings.Keys.defaultRPE)
    private var defaultRPE: Double = 8.0

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                unitsSection
                autoregSection
                defaultsSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    private var unitsSection: some View {
        Section("Units") {
            Picker("Weight unit", selection: $weightIsKg) {
                Text("kg").tag(true)
                Text("lb").tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    private var autoregSection: some View {
        Section {
            Picker("Mode", selection: $autoregModeRaw) {
                Text("RIR").tag(AutoregMode.rir.rawValue)
                Text("RPE").tag(AutoregMode.rpe.rawValue)
                Text("None").tag(AutoregMode.none.rawValue)
            }
            .pickerStyle(.segmented)

            switch autoregMode {
            case .rir:
                Stepper(
                    "Default RIR: \(formatted(defaultRIR))",
                    value: $defaultRIR, in: 0...5, step: 0.5
                )
                .onChange(of: defaultRIR) { _, new in defaultRPE = 10 - new }
            case .rpe:
                Stepper(
                    "Default RPE: \(formatted(defaultRPE))",
                    value: $defaultRPE, in: 5...10, step: 0.5
                )
                .onChange(of: defaultRPE) { _, new in defaultRIR = 10 - new }
            case .none:
                EmptyView()
            }
        } header: {
            Text("Autoregulation")
        } footer: {
            Text("Applies to new slots and the intensity field in active workouts.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var defaultsSection: some View {
        Section("New Slot Defaults") {
            Stepper("Sets: \(defaultSets)", value: $defaultSets, in: 1...10)

            Stepper("Rep min: \(defaultRepMin)", value: $defaultRepMin, in: 1...30)
                .onChange(of: defaultRepMin) { _, new in
                    if new > defaultRepMax { defaultRepMax = new }
                }

            Stepper("Rep max: \(defaultRepMax)", value: $defaultRepMax, in: 1...30)
                .onChange(of: defaultRepMax) { _, new in
                    if new < defaultRepMin { defaultRepMin = new }
                }

            Stepper(
                "Rest between sets: \(defaultRestBetweenSets)s",
                value: $defaultRestBetweenSets, in: 0...300, step: 15
            )

            Stepper(
                defaultRestAfterExercise == 0
                    ? "Rest after exercise: none"
                    : "Rest after exercise: \(defaultRestAfterExercise)s",
                value: $defaultRestAfterExercise, in: 0...300, step: 15
            )
        }
    }

    private func formatted(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }
}
