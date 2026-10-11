import CoreLocation
import Observation
import Foundation

@MainActor @Observable
final class UserLocation: NSObject, CLLocationManagerDelegate {
    private(set) var point: GridPoint?
    private(set) var isUnavailable = false
    var message: String?
    private let manager = CLLocationManager()
    private var requested = false
    private var userRequestedHome = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate(jumpHome: Bool = false) {
        requested = true
        userRequestedHome = jumpHome
        if jumpHome { point = nil }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            isUnavailable = false
            manager.requestLocation()
        case .denied, .restricted:
            isUnavailable = true
            if jumpHome { message = "Allow location access in Settings to jump to your current location." }
        @unknown default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: isUnavailable = false; manager.requestLocation()
        case .denied, .restricted: isUnavailable = true
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        point = GridPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        isUnavailable = false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if userRequestedHome { message = "Your location is unavailable right now. Try again in a moment." }
    }
}

nonisolated struct MapCameraRequest {
    enum Target { case home, largest }
    let id = UUID()
    let target: Target
}
