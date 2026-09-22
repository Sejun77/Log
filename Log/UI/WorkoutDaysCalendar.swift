import SwiftUI
import UIKit

// ======================================================
// MARK: - Workout day derivation
// ======================================================

/// The set of calendar days on which a workout was logged, in the
/// `[.year, .month, .day]` `DateComponents` form both `MultiDatePicker` and
/// `UICalendarView` match selections against.
///
/// Pure, and deliberately parameterized on the `Calendar`: day bucketing is a
/// timezone/locale decision, and a test that pins the calendar is the only way
/// to assert normalization without depending on the machine's region. The
/// caller passes `.current` so the highlighted day always matches the day the
/// grid draws.
///
/// Duplicates collapse by construction — two workouts on the same day yield one
/// member, because the components of both normalize to the same value.
func workoutDayComponents(
    for dates: [Date],
    calendar: Calendar = .current
) -> Set<DateComponents> {
    Set(
        dates.map {
            calendar.dateComponents([.year, .month, .day], from: $0)
        }
    )
}

// ======================================================
// MARK: - Workout Days Calendar
// ======================================================

/// A month grid that highlights the days a workout was logged, and **cannot be
/// edited by the user**.
///
/// History's calendar is a visual record of `Workout.date`, not a selection
/// control. It previously used `MultiDatePicker(selection:)`, which owns its
/// binding: tapping a highlighted day wrote the picker's edited set into the
/// one piece of state driving the highlight, so the day stayed dark until the
/// next `workouts` change re-derived it. The highlight drifted away from the
/// data it was supposed to report.
///
/// `MultiDatePicker` has no read-only mode. `.disabled`/`.allowsHitTesting`
/// would fix the drift but also kill the month chevrons and the month-year
/// menu, leaving History able to show only the current month; ignoring writes
/// in a custom `Binding` changes no state, so SwiftUI never re-applies the
/// selection and the day stays visually deselected anyway.
///
/// So this drops to the component `MultiDatePicker` is itself built on and uses
/// the API UIKit provides for exactly this case: a `UICalendarSelectionMultiDate`
/// whose delegate refuses every `canSelectDate` / `canDeselectDate`. Selection
/// is therefore settable only in code, the highlight is the system's own (same
/// accent-tinted circles, same light/dark behavior), and month navigation keeps
/// working.
struct WorkoutDaysCalendar: UIViewRepresentable {
    /// Days to highlight. A plain `let`, not a `Binding` — nothing downstream
    /// of here can write back to History's derived state.
    let days: Set<DateComponents>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        // No `calendar`/`locale`/`tintColor` overrides: the defaults are what
        // `MultiDatePicker` renders with, and the app's asset-catalog
        // AccentColor already reaches UIKit through the window tint.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let selection = UICalendarSelectionMultiDate(delegate: context.coordinator)
        selection.setSelectedDates(Array(days), animated: false)
        view.selectionBehavior = selection

        return view
    }

    func updateUIView(_ uiView: UICalendarView, context: Context) {
        guard
            let selection = uiView.selectionBehavior
                as? UICalendarSelectionMultiDate
        else { return }

        // Re-assert from the derived set on every update. Because the user can
        // never change it, this only ever runs for a real data change.
        guard Set(selection.selectedDates) != days else { return }
        selection.setSelectedDates(Array(days), animated: false)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UICalendarView,
        context: Context
    ) -> CGSize? {
        // A `UICalendarView` lays out to the width it is given and reports the
        // month grid's height for it. Without this it collapses to its
        // compressed height inside a `List` row.
        let width = proposal.width ?? uiView.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        ).width
        let fitted = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: fitted.height)
    }

    /// Refuses every user-initiated selection change. The `didSelect`/
    /// `didDeselect` callbacks are required by the protocol but unreachable —
    /// the `can…` pair is consulted first and always says no.
    final class Coordinator: NSObject, UICalendarSelectionMultiDateDelegate {
        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            canSelectDate dateComponents: DateComponents
        ) -> Bool { false }

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            canDeselectDate dateComponents: DateComponents
        ) -> Bool { false }

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            didSelectDate dateComponents: DateComponents
        ) {}

        func multiDateSelection(
            _ selection: UICalendarSelectionMultiDate,
            didDeselectDate dateComponents: DateComponents
        ) {}
    }
}
