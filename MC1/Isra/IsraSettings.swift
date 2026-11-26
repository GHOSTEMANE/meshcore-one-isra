import Foundation
import MeshCore

/// Per-device switches of the isra fork, in UserDefaults (thread-safe, so the session's
/// host-caps provider can read them off the main actor).
enum IsraSettings {
  private static func key(_ name: String, devicePublicKey: Data) -> String {
    "isra.\(name).\(devicePublicKey.prefix(8).hexString)"
  }

  /// "Phone position for telemetry" for this device (off by default).
  static func phonePositionEnabled(devicePublicKey: Data) -> Bool {
    UserDefaults.standard.bool(forKey: key("phonePos", devicePublicKey: devicePublicKey))
  }

  static func setPhonePositionEnabled(_ enabled: Bool, devicePublicKey: Data) {
    UserDefaults.standard.set(enabled, forKey: key("phonePos", devicePublicKey: devicePublicKey))
  }

  /// Host caps announced in HELLO: device-sent messages always, the phone position only
  /// when the user turned it on for this device.
  static func hostCaps(devicePublicKey: Data) -> IsraProtocol.Caps {
    var caps: IsraProtocol.Caps = .sentMessages
    if phonePositionEnabled(devicePublicKey: devicePublicKey) {
      caps.insert(.phonePosition)
    }
    return caps
  }
}
