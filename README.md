# AI Fitness Tracker — iOS Apple Health Bridge

Native SwiftUI iPhone bridge between Apple Health / Apple Watch and the existing AI Fitness Tracker backend.

## Backend

- Base URL: `https://ai-fitness-tracker-backend-0a0k.onrender.com`
- Import route: `POST /api/v1/import/apple-health`
- Authentication header: `x-ingest-key`
- Profile ID: `8d553210-69a8-4f25-91be-000000000001`

## What this project reads

- Body mass
- Workouts
- Heart rate
- Step count
- Active energy burned
- Walking/running distance

## Open and run

1. Open `AI Fitness Tracker.xcodeproj` in Xcode.
2. Select the **AI Fitness Tracker** target → **Signing & Capabilities**.
3. Choose your Apple Development Team / personal team.
4. Confirm **HealthKit** capability is present.
5. Connect a real iPhone. HealthKit is not useful for this test in the Simulator.
6. Build and run.
7. Tap the gear icon.
8. Paste the same value you use as `APPLE_HEALTH_INGEST_API_KEY` on the backend and save it.
9. Tap **Sync Apple Health** and grant the requested read permissions.

The ingest key is stored in the iPhone Keychain, not in source control.

## Backend contract note

The existing backend was previously validated with `examples/apple-health-import.json`, but the exact contents of that file were not available while this downloadable project was assembled. The current request DTO is deliberately isolated in:

- `Models/AppleHealthImportModels.swift`
- `HealthKit/HealthKitMapper.swift`

If the backend responds with HTTP 400 because its existing JSON property names differ, align those two files with the backend's `examples/apple-health-import.json`; the HealthKit and UI layers do not need redesigning.

The app shows the backend response body on HTTP errors so contract mismatches are easy to diagnose.

## Current sync behaviour

The first successful sync reads the number of days selected in Settings (default 30). Later manual syncs start from the previous successful sync time with a 5-minute overlap to catch late-arriving samples.

The next project phase should replace this date-based incremental sync with persisted `HKAnchoredObjectQuery` anchors and then add `HKObserverQuery` + background delivery.

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

Before changing the backend schema for pace/HR analysis, inspect what one real adidas Running workout actually exposes through HealthKit.

1. Run the app on the physical iPhone that contains the adidas Running workout.
2. Grant the additional Health permissions requested by the app.
3. Tap **Inspect Latest adidas Run**.
4. The app finds the most recent running `HKWorkout` whose source, bundle identifier, or workout brand contains `adidas`.
5. It reports both:
   - samples explicitly associated with the workout via `HKQuery.predicateForObjects(from:)`; and
   - samples that exist only inside the workout time interval.
6. Tap **Share JSON Diagnostic** and save/share the generated JSON.

The report checks:
- heart rate;
- running speed;
- walking/running distance;
- active energy;
- step count;
- running power;
- stride length;
- vertical oscillation;
- ground contact time;
- workout route/GPS;
- workout events such as pause/resume/lap/segment/marker where present;
- source application/bundle, workout brand, device and metadata.

The JSON preserves original sample start/end timestamps. Route output includes every available route point and preserves each original GPS timestamp so we can test route-based pace reconstruction against the real adidas workout.

### What to send back

Upload the generated `healthkit-adidas-workout-diagnostic-*.json` file. That output determines whether the detailed importer should prefer:

1. native `runningSpeed` samples;
2. distance samples + timestamps;
3. GPS route points + timestamps; or
4. a controlled combination of interval HR plus another pace source.

Do not create the new Supabase migration until this diagnostic has been inspected. This prevents us from locking the database to HealthKit fields that adidas Running does not actually write.
