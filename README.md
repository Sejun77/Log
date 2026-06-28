# Log

Log is a personal iOS gym logging app built with **SwiftUI** and **SwiftData**.

It helps users create exercises, build workout routines, log active workouts, and review progress over time.

This project is currently a **personal/internal milestone**, not a public App Store release.

---

## Overview

Log is built around a simple workout flow:

1. **Create exercises**
2. **Build routines**
3. **Start a workout**
4. **Log sets**
5. **Review history and progress**

The goal is to make structured workout tracking easier during real training.

Instead of only storing loose notes, Log keeps exercise details, routine prescriptions, active workout data, and finished workout history in a more organized way.

---

## Core Features

### Exercise Library

Exercises can store information such as:

- exercise name
- equipment type
- setup notes
- exercise notes
- bodyweight-related settings
- time-based exercise options

This makes each exercise more useful during an active workout because important setup information can be shown when it is needed.

---

### Routine Builder

Routines are planned workout templates.

A routine can include:

- normal exercise blocks
- supersets
- warm-up steps
- working sets
- set prescriptions
- rest times
- reps and weight targets
- RIR targets
- tempo notes
- exercise techniques

The routine editor is designed to separate the planned workout from the completed workout record. Starting a workout from a routine does not permanently change the routine itself.

---

### Set Prescriptions and Techniques

Log supports detailed set planning.

A set can include information such as:

- reps
- weight
- duration
- rest time
- RIR
- tempo
- notes

The app also supports training techniques such as:

- warm-up sets
- working sets
- drop sets
- AMRAP
- to-failure work
- rest-pause
- cluster-style work

Some technique combinations are restricted so the routine stays clear and valid.

---

### Supersets

Routines can include supersets, where multiple exercises are grouped together.

Supersets support:

- multiple exercises in one block
- rest after a superset round
- exercise reordering
- minimum exercise-count rules
- uneven set counts

For example, one exercise in a superset can have 3 sets while another has 2. The app does not create fake sets or force both exercises to match.

---

### Active Workout

The Active Workout screen is where the workout is actually logged.

It supports:

- starting from a routine
- logging warm-up sets
- logging working sets
- last-performance prefill
- rest timer behavior
- set notes
- switching exercises during a workout
- Save & Exit
- Resume
- finishing the workout into History

Prefill values are only suggestions. A set is not saved until the user taps **Log**.

---

### Switch Exercise

During a workout, an exercise can be switched if the original exercise is not available or no longer fits the session.

Switch Exercise updates:

- exercise name
- equipment behavior
- setup information
- prefill source
- input fields where needed

The original routine template is not mutated by the switch.

---

### Recovery / Deload Prefill Control

Some workouts should be saved in History but not used as the next prefill source.

For example, a lighter recovery workout should not necessarily replace normal training numbers.

Log includes a **Use for future prefill** option so recovery or deload sessions can stay in History while being skipped by future prefill.

---

### History and Progress

Finished workouts are saved to History.

History supports:

- completed workout records
- logged set review
- exercise grouping
- progress charts
- metric selection
- recent workout rows

Progress metrics can include:

- e1RM
- volume
- best weight
- reps
- best reps
- duration

Available metrics depend on the type of exercise and the data that was logged.

---

## Current Status

Log has reached a personal/internal milestone.

At this stage:

- the core workout flow works on device
- real workouts have been tested on an iPhone
- the automated test suite passes
- known limitations are documented
- TestFlight and public release work are deferred

Current validation:

- **916 automated tests passing**
- **0 failures**
- real-device workout testing completed

---

## Showcase

The final showcase demonstrates:

- exercise setup
- routine creation
- set prescriptions
- supersets
- active workout logging
- last-performance prefill
- rest timer behavior
- Switch Exercise
- Save & Exit / Resume
- Finish Workout → History
- progress charts

The showcase presents Log as a personal project milestone, not as a public App Store product.

---

## How to Run Locally

This project is intended to be run from Xcode.

### Requirements

- macOS
- Xcode
- iPhone Simulator or physical iPhone
- Apple ID for code signing if running on a physical iPhone

### Steps

1. Clone the repository.

```bash
git clone https://github.com/Sejun77/Log.git
```

2. Open the project in Xcode.

3. Select the `Log` app target.

4. Choose a simulator or connected iPhone.

5. If running on a physical iPhone:
   - open **Signing & Capabilities**
   - select your development team
   - let Xcode manage signing automatically

6. Press **Run**.

---

## Running on a Personal iPhone

The app can be installed on a personal iPhone through Xcode for local testing.

If using a free Apple Developer account, the app may need to be rebuilt and reinstalled after about a week.

This is acceptable for personal development, but it is not a good distribution method for regular users.

For future peer testing, TestFlight would be a better option.

---

## Project Scope

This repository is shared as a development and portfolio project.

It is not currently:

- an App Store release
- a production-ready commercial app
- a finished public product

The current goal is to show the design, implementation, testing, and iteration process behind a working personal iOS app.

---

## Known Limitations

Some work is intentionally deferred.

Current known limitations include:

- TestFlight is not completed yet
- public App Store readiness is not claimed
- full Active Workout redesign is deferred
- weight/rep field-switching friction is being monitored until it is reproducible
- future UI polish may still be needed after more real use

---

## Tech Stack

- Swift
- SwiftUI
- SwiftData
- XCTest
- Xcode

---

## Testing

The project includes automated tests for core app behavior.

Current test status:

- **916 tests passing**
- **0 failures**

Test coverage includes areas such as:

- routine editing
- set prescriptions
- active workout logging
- bodyweight exercise behavior
- last-performance prefill
- recovery/deload prefill exclusion
- Switch Exercise behavior
- uneven superset set counts
- History behavior
- progress metrics

---

## Future Plans

Possible future work includes:

- more real-device testing
- TestFlight testing with a small group
- additional UI polish
- improved Active Workout visual hierarchy
- continued fixes based on real workout use

---

## License

No license has been selected yet.

Until a license is added, this project is shared for viewing and portfolio purposes only.
