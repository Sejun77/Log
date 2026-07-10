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

    /// Bodyweight is stored as an optional Double in `AppSettings`, which
    /// `@AppStorage` can't bind directly — so it's edited through a free-text
    /// field seeded on appear and written back (normalized) on change.
    @State private var bodyweightText: String = ""

    /// Anchors the Bodyweight field in SwiftUI's focus system so the keyboard
    /// accessory (`.keyboard` toolbar) attaches reliably — a `.decimalPad`
    /// field with no `@FocusState` shows the Done button only intermittently.
    @FocusState private var bodyweightFocused: Bool

    private var autoregMode: AutoregMode {
        AutoregMode(rawValue: autoregModeRaw) ?? .rir
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                unitsSection
                bodyweightSection
                autoregSection
                defaultsSection
                dataSection
                showcaseSection
            }
            .navigationTitle("Settings")
            .onAppear {
                bodyweightText =
                    AppSettings.userBodyweight.map { Units.formatWeight($0) } ?? ""
            }
            // Scrolling the Settings form dismisses the bodyweight keyboard.
            // `.immediately` matches HistoryView's existing dismissal style.
            // The `.keyboard`-placement toolbar accessory proved unreliable in
            // this Form, so the visible Done control lives inline in the
            // bodyweight row instead (see `bodyweightSection`).
            .scrollDismissesKeyboard(.immediately)
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

    private var bodyweightSection: some View {
        Section {
            HStack {
                Text("Bodyweight")
                Spacer()
                TextField("Not set", text: $bodyweightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .focused($bodyweightFocused)
                Text(weightIsKg ? "kg" : "lb")
                    .foregroundStyle(.secondary)
                // Inline focus-gated dismiss — the `.decimalPad` has no Return
                // key and the `.keyboard` toolbar accessory is unreliable in
                // this Form, so this checkmark is the dependable Done control.
                if bodyweightFocused {
                    Button {
                        bodyweightFocused = false
                    } label: {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Done")
                }
            }
            .onChange(of: bodyweightText) { _, newValue in
                AppSettings.userBodyweight = normalizedBodyweight(newValue)
            }
        } header: {
            Text("Bodyweight")
        } footer: {
            // `LocalizedStringKey(_:)` is required here: concatenating string
            // literals with `+` yields a `String`, which binds `Text`'s
            // non-localizing `init(_ verbatim:)` overload — so the footer would
            // always render in English regardless of the string catalog. Wrapping
            // the concatenation in `LocalizedStringKey` restores catalog lookup.
            Text(LocalizedStringKey(
                "Used for bodyweight-inclusive exercises (e.g. pull-ups, dips) "
                + "in History load metrics. Leave empty if not set. Stored in the "
                + "unit shown above."))
                .font(.caption)
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

    private var dataSection: some View {
        Section {
            ExerciseCSVImportButton()
            RoutineJSONImportButton()
            DataExportButtons()
        } header: {
            Text("Data")
        } footer: {
            // See the bodyweight footer above: the `+`-concatenated literals
            // produce a `String`, so this must be wrapped in `LocalizedStringKey`
            // to localize instead of binding `Text`'s verbatim initializer.
            Text(LocalizedStringKey(
                "Import a CSV of exercises (name,bodyPart,equipmentType,setupDefaults,"
                + "isTimeBased,notes). New names are added as custom exercises; existing "
                + "names are skipped. Import a routine JSON to add it as a new routine "
                + "(existing routines are never overwritten; missing exercises are created "
                + "as custom). Nothing is overwritten or deleted. Export saves your "
                + "exercise library or workout history as CSV."))
                .font(.caption)
        }
    }

    private var showcaseSection: some View {
        Section {
            NavigationLink {
                AnalyticsView()
            } label: {
                Label("Calculus Analytics", systemImage: "function")
            }
        } header: {
            Text("Showcase")
        } footer: {
            Text("AP Calculus AB demo using in-memory sample workout data. Does not touch your history.")
                .font(.caption)
        }
    }

    private func formatted(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.1f", v)
    }
}
