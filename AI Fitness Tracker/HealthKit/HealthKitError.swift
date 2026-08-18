import Foundation

enum HealthKitError: LocalizedError {
    case healthDataUnavailable
    case unsupportedType(String)
    case authorizationFailed
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is not available on this device. Run the app on an iPhone."
        case let .unsupportedType(type):
            return "HealthKit type is not available: \(type)."
        case .authorizationFailed:
            return "HealthKit authorization or background delivery could not be enabled."
        case let .queryFailed(message):
            return message
        }
    }
}
