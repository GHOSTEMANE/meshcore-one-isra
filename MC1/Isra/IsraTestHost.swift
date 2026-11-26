import Foundation

/// isra: whether upstream's test bundle (MC1Tests) is loaded in this process. True only
/// while the bundle's marker class `IsraUpstreamTestsMarker` exists
/// (`MC1Tests/Isra/IsraUpstreamTestsMarker.swift`); the app itself never has it.
enum IsraTestHost {
  static var upstreamTestsLoaded: Bool {
    NSClassFromString("IsraUpstreamTestsMarker") != nil
  }
}
