import CoreLocation
import Foundation
import HealthKit

struct WorkoutDiagnosticsReport: Codable {
    let generatedAt: Date
    let workout: WorkoutDiagnosticsWorkout
    let quantityTypes: [WorkoutQuantityDiagnostics]
    let workoutEvents: [WorkoutEventDiagnostics]
    let routes: [WorkoutRouteDiagnostics]

    var associatedHeartRateCount: Int {
        quantityTypes.first(where: { $0.identifier == HKQuantityTypeIdentifier.heartRate.rawValue })?.associatedSampleCount ?? 0
    }

    var associatedRunningSpeedCount: Int {
        quantityTypes.first(where: { $0.identifier == HKQuantityTypeIdentifier.runningSpeed.rawValue })?.associatedSampleCount ?? 0
    }

    var associatedDistanceCount: Int {
        quantityTypes.first(where: { $0.identifier == HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue })?.associatedSampleCount ?? 0
    }

    var intervalHeartRateCount: Int {
        quantityTypes.first(where: { $0.identifier == HKQuantityTypeIdentifier.heartRate.rawValue })?.intervalSampleCount ?? 0
    }

    var intervalRunningSpeedCount: Int {
        quantityTypes.first(where: { $0.identifier == HKQuantityTypeIdentifier.runningSpeed.rawValue })?.intervalSampleCount ?? 0
    }

    var intervalDistanceCount: Int {
        quantityTypes.first(where: { $0.identifier == HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue })?.intervalSampleCount ?? 0
    }

    var routePointCount: Int {
        routes.reduce(0) { $0 + $1.pointCount }
    }
}

struct WorkoutDiagnosticsWorkout: Codable {
    let healthKitUUID: String
    let activityType: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let totalDistanceMeters: Double?
    let totalActiveEnergyKcal: Double?
    let sourceName: String
    let sourceBundleIdentifier: String
    let sourceVersion: String?
    let workoutBrandName: String?
    let deviceName: String?
    let deviceManufacturer: String?
    let deviceModel: String?
    let deviceHardwareVersion: String?
    let deviceSoftwareVersion: String?
    let metadata: [String: String]
}

struct WorkoutQuantityDiagnostics: Codable {
    let identifier: String
    let unit: String
    let associatedSampleCount: Int
    let intervalSampleCount: Int
    let associatedSources: [String: Int]
    let intervalSources: [String: Int]
    let associatedSamples: [WorkoutQuantitySampleDiagnostics]
    let intervalSamplesPreview: [WorkoutQuantitySampleDiagnostics]
}

struct WorkoutQuantitySampleDiagnostics: Codable {
    let healthKitUUID: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let value: Double
    let unit: String
    let sourceName: String
    let sourceBundleIdentifier: String
}

struct WorkoutEventDiagnostics: Codable {
    let type: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let metadata: [String: String]
}

struct WorkoutRouteDiagnostics: Codable {
    let healthKitUUID: String
    let sourceName: String
    let sourceBundleIdentifier: String
    let pointCount: Int
    let calculatedDistanceMeters: Double
    let firstPointAt: Date?
    let lastPointAt: Date?
    let points: [WorkoutRoutePointDiagnostics]
}

struct WorkoutRoutePointDiagnostics: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double
    let horizontalAccuracyMeters: Double
    let verticalAccuracyMeters: Double
    let speedMetersPerSecond: Double
}

enum WorkoutDiagnosticsError: LocalizedError {
    case noRunningWorkouts
    case noAdidasRunningWorkout(recentSources: [String])

    var errorDescription: String? {
        switch self {
        case .noRunningWorkouts:
            return "No running workouts were found in the selected HealthKit history."
        case let .noAdidasRunningWorkout(recentSources):
            let sources = recentSources.isEmpty ? "none" : recentSources.joined(separator: ", ")
            return "No adidas Running workout was found. Recent running workout sources: \(sources)."
        }
    }
}

final class WorkoutDiagnosticsInspector {
    private struct QuantityProbe {
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let unitName: String
    }

    private let healthStore: HKHealthStore
    private let reader: HealthKitReader

    init(
        healthStore: HKHealthStore = HealthKitManager.shared.healthStore,
        reader: HealthKitReader = HealthKitReader()
    ) {
        self.healthStore = healthStore
        self.reader = reader
    }

    func inspectLatestAdidasRun(lookbackDays: Int = 180) async throws -> WorkoutDiagnosticsReport {
        let startDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? .distantPast
        let workouts = try await reader.workouts(from: startDate)
            .filter { $0.workoutActivityType == .running }
            .sorted { $0.startDate > $1.startDate }

        guard !workouts.isEmpty else {
            throw WorkoutDiagnosticsError.noRunningWorkouts
        }

        guard let workout = workouts.first(where: isAdidasWorkout) else {
            let sources = Array(Set(workouts.prefix(20).map { sourceDescriptor(for: $0) })).sorted()
            throw WorkoutDiagnosticsError.noAdidasRunningWorkout(recentSources: sources)
        }

        let probes: [QuantityProbe] = [
            .init(
                identifier: .heartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                unitName: "bpm"
            ),
            .init(
                identifier: .runningSpeed,
                unit: HKUnit.meter().unitDivided(by: .second()),
                unitName: "m/s"
            ),
            .init(
                identifier: .distanceWalkingRunning,
                unit: .meter(),
                unitName: "m"
            ),
            .init(
                identifier: .activeEnergyBurned,
                unit: .kilocalorie(),
                unitName: "kcal"
            ),
            .init(
                identifier: .stepCount,
                unit: .count(),
                unitName: "count"
            ),
            .init(
                identifier: .runningPower,
                unit: .watt(),
                unitName: "W"
            ),
            .init(
                identifier: .runningStrideLength,
                unit: .meter(),
                unitName: "m"
            ),
            .init(
                identifier: .runningVerticalOscillation,
                unit: .meter(),
                unitName: "m"
            ),
            .init(
                identifier: .runningGroundContactTime,
                unit: .second(),
                unitName: "s"
            )
        ]

        var quantityTypes: [WorkoutQuantityDiagnostics] = []
        for probe in probes {
            quantityTypes.append(try await inspectQuantity(probe, workout: workout))
        }

        let routeSamples = try await workoutRoutes(for: workout)
        var routeDiagnostics: [WorkoutRouteDiagnostics] = []
        for route in routeSamples {
            routeDiagnostics.append(try await inspectRoute(route))
        }

        let workoutDiagnostics = WorkoutDiagnosticsWorkout(
            healthKitUUID: workout.uuid.uuidString.lowercased(),
            activityType: "running",
            startedAt: workout.startDate,
            endedAt: workout.endDate,
            durationSeconds: workout.duration,
            totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
            totalActiveEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            sourceName: workout.sourceRevision.source.name,
            sourceBundleIdentifier: workout.sourceRevision.source.bundleIdentifier,
            sourceVersion: workout.sourceRevision.version,
            workoutBrandName: workout.metadata?[HKMetadataKeyWorkoutBrandName] as? String,
            deviceName: workout.device?.name,
            deviceManufacturer: workout.device?.manufacturer,
            deviceModel: workout.device?.model,
            deviceHardwareVersion: workout.device?.hardwareVersion,
            deviceSoftwareVersion: workout.device?.softwareVersion,
            metadata: stringifyMetadata(workout.metadata)
        )

        let events = (workout.workoutEvents ?? []).map { event in
            WorkoutEventDiagnostics(
                type: String(describing: event.type),
                startedAt: event.dateInterval.start,
                endedAt: event.dateInterval.end,
                durationSeconds: event.dateInterval.duration,
                metadata: stringifyMetadata(event.metadata)
            )
        }

        return WorkoutDiagnosticsReport(
            generatedAt: Date(),
            workout: workoutDiagnostics,
            quantityTypes: quantityTypes,
            workoutEvents: events,
            routes: routeDiagnostics
        )
    }

    func writeJSONReport(_ report: WorkoutDiagnosticsReport) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let filename = "healthkit-adidas-workout-diagnostic-\(formatter.string(from: report.generatedAt)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    private func inspectQuantity(
        _ probe: QuantityProbe,
        workout: HKWorkout
    ) async throws -> WorkoutQuantityDiagnostics {
        let associated = try await quantitySamples(identifier: probe.identifier, associatedWith: workout)
        let interval = try await quantitySamples(
            identifier: probe.identifier,
            from: workout.startDate,
            to: workout.endDate
        )

        return WorkoutQuantityDiagnostics(
            identifier: probe.identifier.rawValue,
            unit: probe.unitName,
            associatedSampleCount: associated.count,
            intervalSampleCount: interval.count,
            associatedSources: countSources(associated),
            intervalSources: countSources(interval),
            associatedSamples: associated.map { mapQuantitySample($0, unit: probe.unit, unitName: probe.unitName) },
            intervalSamplesPreview: preview(interval, maximum: 40).map {
                mapQuantitySample($0, unit: probe.unit, unitName: probe.unitName)
            }
        )
    }

    private func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        associatedWith workout: HKWorkout
    ) async throws -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return []
        }

        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await executeSampleQuery(sampleType: type, predicate: predicate, castTo: HKQuantitySample.self)
    }

    private func quantitySamples(
        identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HKQuantitySample] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: [.strictStartDate, .strictEndDate]
        )
        return try await executeSampleQuery(sampleType: type, predicate: predicate, castTo: HKQuantitySample.self)
    }

    private func workoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await executeSampleQuery(sampleType: routeType, predicate: predicate, castTo: HKWorkoutRoute.self)
    }

    private func inspectRoute(_ route: HKWorkoutRoute) async throws -> WorkoutRouteDiagnostics {
        let points = try await routeLocations(for: route).sorted { $0.timestamp < $1.timestamp }

        var distanceMeters = 0.0
        for index in 1..<points.count {
            distanceMeters += points[index].distance(from: points[index - 1])
        }

        let routePoints = points.map { point in
            WorkoutRoutePointDiagnostics(
                timestamp: point.timestamp,
                latitude: point.coordinate.latitude,
                longitude: point.coordinate.longitude,
                altitudeMeters: point.altitude,
                horizontalAccuracyMeters: point.horizontalAccuracy,
                verticalAccuracyMeters: point.verticalAccuracy,
                speedMetersPerSecond: point.speed
            )
        }

        return WorkoutRouteDiagnostics(
            healthKitUUID: route.uuid.uuidString.lowercased(),
            sourceName: route.sourceRevision.source.name,
            sourceBundleIdentifier: route.sourceRevision.source.bundleIdentifier,
            pointCount: points.count,
            calculatedDistanceMeters: distanceMeters,
            firstPointAt: points.first?.timestamp,
            lastPointAt: points.last?.timestamp,
            points: routePoints
        )
    }

    private func routeLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            var didResume = false

            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                if let locations {
                    collected.append(contentsOf: locations)
                }

                if done && !didResume {
                    didResume = true
                    continuation.resume(returning: collected)
                }
            }

            healthStore.execute(query)
        }
    }

    private func executeSampleQuery<T: HKSample>(
        sampleType: HKSampleType,
        predicate: NSPredicate?,
        castTo: T.Type
    ) async throws -> [T] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: samples as? [T] ?? [])
            }

            healthStore.execute(query)
        }
    }

    private func mapQuantitySample(
        _ sample: HKQuantitySample,
        unit: HKUnit,
        unitName: String
    ) -> WorkoutQuantitySampleDiagnostics {
        WorkoutQuantitySampleDiagnostics(
            healthKitUUID: sample.uuid.uuidString.lowercased(),
            startedAt: sample.startDate,
            endedAt: sample.endDate,
            durationSeconds: sample.endDate.timeIntervalSince(sample.startDate),
            value: sample.quantity.doubleValue(for: unit),
            unit: unitName,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier
        )
    }

    private func countSources(_ samples: [HKQuantitySample]) -> [String: Int] {
        Dictionary(grouping: samples) { sample in
            "\(sample.sourceRevision.source.name) [\(sample.sourceRevision.source.bundleIdentifier)]"
        }
        .mapValues { $0.count }
    }

    private func isAdidasWorkout(_ workout: HKWorkout) -> Bool {
        let source = workout.sourceRevision.source.name.lowercased()
        let bundle = workout.sourceRevision.source.bundleIdentifier.lowercased()
        let brand = (workout.metadata?[HKMetadataKeyWorkoutBrandName] as? String)?.lowercased() ?? ""
        return source.contains("adidas") || bundle.contains("adidas") || brand.contains("adidas")
    }

    private func sourceDescriptor(for workout: HKWorkout) -> String {
        let brand = workout.metadata?[HKMetadataKeyWorkoutBrandName] as? String
        if let brand, !brand.isEmpty {
            return "\(workout.sourceRevision.source.name) / \(brand)"
        }
        return workout.sourceRevision.source.name
    }

    private func stringifyMetadata(_ metadata: [String: Any]?) -> [String: String] {
        guard let metadata else { return [:] }
        return metadata.reduce(into: [:]) { result, item in
            result[item.key] = String(describing: item.value)
        }
    }

    private func preview<T>(_ values: [T], maximum: Int) -> [T] {
        guard values.count > maximum, maximum >= 2 else { return values }
        let firstCount = maximum / 2
        let lastCount = maximum - firstCount
        return Array(values.prefix(firstCount)) + Array(values.suffix(lastCount))
    }
}
