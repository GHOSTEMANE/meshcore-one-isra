import MC1Services

/// isra: the app's writes of the radio's "other params" record.
///
/// CMD_SET_OTHER_PARAMS always carries all six fields (manual add, the three
/// telemetry modes, advert location policy, multi-acks). The session merges the
/// field being changed into its cached SELF_INFO and sends the whole record, so a
/// value changed on the device since that copy (e.g. Advert pos) would be written
/// back. Re-reading SELF_INFO first makes the untouched fields the radio's real
/// values. No caller here ever passes an advert location policy: that one is
/// changed on the device only.
enum IsraRadioWrites {
  static func otherParams(
    _ settingsService: SettingsService,
    autoAddContacts: Bool? = nil,
    telemetryModeBase: UInt8? = nil,
    telemetryModeLocation: UInt8? = nil,
    telemetryModeEnvironment: UInt8? = nil,
    multiAcks: UInt8? = nil
  ) async throws {
    _ = try await settingsService.getSelfInfo()
    try await settingsService.setOtherParamsVerified(
      autoAddContacts: autoAddContacts,
      telemetryModeBase: telemetryModeBase,
      telemetryModeLocation: telemetryModeLocation,
      telemetryModeEnvironment: telemetryModeEnvironment,
      multiAcks: multiAcks
    )
  }

  /// A manual coordinate write that leaves the radio's GPS as it is (upstream's
  /// manual-location setters switch the GPS off first). With the GPS on, its next
  /// fix replaces the value.
  static func setCoordinates(
    _ settingsService: SettingsService,
    latitude: Double? = nil,
    longitude: Double? = nil
  ) async throws {
    let current = try await settingsService.getSelfInfo()
    _ = try await settingsService.setLocationVerified(
      latitude: latitude ?? current.latitude,
      longitude: longitude ?? current.longitude
    )
  }
}
