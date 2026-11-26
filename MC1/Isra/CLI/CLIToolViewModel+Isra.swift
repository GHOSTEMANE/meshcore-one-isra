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

  func israOutput(_ text: String) {
    guard !Task.isCancelled else { return }
    appendOutput(text, type: .response)
  }

  func israOutputError(_ text: String) {
    guard !Task.isCancelled else { return }
    appendOutput(text, type: .error)
  }
}
