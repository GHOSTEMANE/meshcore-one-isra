import CoreLocation
import MC1Services

extension LocationPickerView {
  /// isra: replaces `forLocalDevice`. Saving a position on the map writes only the
  /// coordinates: the radio's GPS stays as it is (upstream switched it off first) and
  /// the advert location policy is never written (upstream moved policy 2 to 1).
  static func israForLocalDevice(appState: AppState) -> LocationPickerView {
    let device = appState.connectedDevice
    let initialCoord = device.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    return LocationPickerView(initialCoordinate: initialCoord) { coordinate in
      guard let settingsService = appState.services?.settingsService else {
        throw SettingsServiceError.notConnected
      }
      try await IsraRadioWrites.setCoordinates(
        settingsService,
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      )
    }
  }
}
