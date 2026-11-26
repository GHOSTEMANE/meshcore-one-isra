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

  func israOutput(_ text: String) {
    guard !Task.isCancelled else { return }
    appendOutput(text, type: .response)
  }

  func israOutputError(_ text: String) {
    guard !Task.isCancelled else { return }
    appendOutput(text, type: .error)
  }
}
