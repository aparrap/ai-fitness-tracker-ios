# AI Fitness Tracker — iOS Apple Health Bridge

Native SwiftUI iPhone bridge between Apple Health / Apple Watch and the AI Fitness Tracker backend.

## Backend

- Base URL: `https://ai-fitness-tracker-backend-0a0k.onrender.com`
- Import route: `POST /api/v1/import/apple-health`
- Authentication header: `x-ingest-key`

## What this project reads

- Body mass
- Workouts
- Heart rate
- Step count
- Active energy burned
- Walking/running distance
- Running speed
- Running power
- Running stride length
- Running vertical oscillation
- Running ground contact time
- Workout route/events for diagnostics

## Open and run

1. Open `AI Fitness Tracker.xcodeproj` in Xcode.
2. Select the **AI Fitness Tracker** target → **Signing & Capabilities**.
3. Choose your Apple Development Team / personal team.
4. Confirm **HealthKit** capability is present.
5. Connect a real iPhone.
6. Build and run.
7. Tap the gear icon.
8. Paste the same value you use as `APPLE_HEALTH_INGEST_API_KEY` on the backend and save it.
9. Tap **Sync Apple Health** and grant the requested read permissions.

The ingest key is stored in the iPhone Keychain, not in source control.

## Backend contract

The iOS DTO is aligned with backend v0.3.0. Each workout is sent with its workout-level summary plus a nested `samples` array. Raw sample timestamps are preserved; heart rate, speed and distance are not forced into artificial fixed intervals on the phone.

For each workout metric the bridge first queries samples explicitly associated with the workout via `HKQuery.predicateForObjects(from:)`. If none are available, it falls back to the workout time window and marks those samples as `time_window` rather than pretending they were directly associated.

Key files:

- `Models/AppleHealthImportModels.swift`
- `HealthKit/HealthKitReader.swift`
- `HealthKit/HealthKitMapper.swift`

The backend remains responsible for kilometre splits, HR/pace alignment and statistical analysis.

## Current sync behaviour

The first successful sync reads the number of days selected in Settings (default 30). Later manual syncs start from the previous successful sync time with a 5-minute overlap to catch late-arriving samples. Backend record IDs make retry/overlap imports idempotent.

The next sync-infrastructure phase can replace date-based incremental sync with persisted `HKAnchoredObjectQuery` anchors and then add `HKObserverQuery` + background delivery.

## Project structure

```text
AI Fitness Tracker/
├── App/
├── Features/Sync/
├── HealthKit/
├── Models/
├── Networking/
├── Storage/
├── Resources/
├── Info.plist
└── AI_Fitness_Tracker.entitlements
```

## Phase 2.1 — Detailed workout diagnostics

The diagnostic remains useful for determining what adidas Running actually contributes to HealthKit for an individual run.

1. Run the app on the physical iPhone containing the adidas Running workout.
2. Grant the additional Health permissions requested by the app.
3. Tap **Inspect Latest adidas Run**.
4. The app finds the most recent running `HKWorkout` whose source, bundle identifier, or workout brand contains `adidas`.
5. It reports both explicitly associated samples and same-time-window samples.
6. Tap **Share JSON Diagnostic** and save/share the generated JSON.

The report checks heart rate, running speed, distance, energy, steps, running dynamics, workout route/GPS and workout events while preserving original timestamps and source metadata.

Route/GPS is currently diagnostic-only. Persisting route points in the backend is intentionally deferred until a real adidas diagnostic shows that native running speed and distance samples are insufficient for reliable pace reconstruction.
