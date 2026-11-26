import Foundation
import MC1Services

// isra: Tools › CLI changes, called from one-line hooks in the upstream CLI files.
extension CLIToolViewModel {
  /// `set lat` / `set lon` on the paired radio: writes the coordinate only. Upstream
  /// switched the radio's GPS off first.
  func israSetCoordinate(latitude: Double? = nil, longitude: Double? = nil) async {
    guard let settingsService else { return israOutputError(L10n.Tools.Tools.Cli.notConnected) }
    do {
      try await IsraRadioWrites.setCoordinates(settingsService, latitude: latitude, longitude: longitude)
      israOutput(LocalCommandOutput.ok)
    } catch {
      israOutputError(error.localizedDescription)
    }
  }

  /// The error line for a refused CLI line (paired radio reboot, any OTA/DFU), or nil.
  func israRefusal(for line: String) -> String? {
    switch IsraCLIGuard.refusal(for: line, isLocal: activeSession?.isLocal ?? true) {
    case .localReboot: IsraL10n.tr("Isra.UI.Reboot.blocked")
    case .ota: IsraL10n.tr("Isra.UI.OTA.blocked")
    case nil: nil
    }
  }

  // MARK: - get / set of keys the app does not know

  /// `get <key>` for a key that is neither a typed key nor one of the radio's custom
  /// vars: sent to the radio CLI (cmd 66) instead of answering "Unknown var" locally,
  /// so firmware console keys (e.g. Solo's `telemetry.loc.phone`) work.
  func israGetVar(_ key: String) async {
    guard let settingsService else { return israOutputError(L10n.Tools.Tools.Cli.notConnected) }
    let vars = try? await settingsService.getCustomVars()
    if let vars {
      completionEngine.updateCustomVarKeys(Array(vars.keys))
      if let value = vars[key] { return israOutput(LocalCommandOutput.value(value)) }
    }
    if connectedDevice?.supportsRadioCLI == true {
      await runRadioCLI("get \(key)", intent: captureRadioCLIIntent())
    } else if vars != nil {
      israOutput(LocalCommandOutput.unknownVar(key))
    } else {
      israOutputError(L10n.Tools.Tools.Cli.notConnected)
    }
  }

  /// `set <key> <value>`: a custom var the radio lists is written as one; any other
  /// key goes to the radio CLI (cmd 66).
  func israSetVar(key: String, value: String) async {
    guard let settingsService else { return israOutputError(L10n.Tools.Tools.Cli.notConnected) }
    let vars = try? await settingsService.getCustomVars()
    if let vars { completionEngine.updateCustomVarKeys(Array(vars.keys)) }
    let isCustomVar = vars?[key] != nil
    if !isCustomVar, connectedDevice?.supportsRadioCLI == true {
      return await runRadioCLI("set \(key) \(value)", intent: captureRadioCLIIntent())
    }
    do {
      try await settingsService.setCustomVar(key: key, value: value)
      israOutput(LocalCommandOutput.customVarSet(key: key, value: value))
    } catch let SettingsServiceError.sessionError(meshError)
      where meshError.deviceErrorCode == .illegalArgument {
      israOutput(LocalCommandOutput.unknownCustomVar)
    } catch {
      israOutputError(error.localizedDescription)
    }
  }

  func israOutput(_ text: String) {
    guard !Task.isCancelled else { return }
    appendOutput(text, type: .response)
  }

  func israOutputError(_ text: String) {
    guard !Task.isCancelled else { return }
    appendOutput(text, type: .error)
  }
}
