import MC1Services
import SwiftUI

/// isra: replaces TelemetrySettingsSection. One picker per category
/// (status/battery, location, sensors), each Nobody / Authorized contacts / Everyone,
/// and each writes only its own mode. Upstream's single "trusted only" toggle wrote
/// all three modes at once.
struct IsraTelemetrySection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var isSaving = false

  enum Category {
    case base, location, environment
  }

  private var device: DeviceDTO? {
    appState.connectedDevice
  }

  var body: some View {
    Section {
      modePicker(IsraL10n.tr("Isra.UI.Telemetry.base"), category: .base)
      modePicker(IsraL10n.tr("Isra.UI.Telemetry.location"), category: .location)
      modePicker(IsraL10n.tr("Isra.UI.Telemetry.environment"), category: .environment)

      NavigationLink(value: SettingsSubpage.trustedContacts) {
        Text(IsraL10n.tr("Isra.UI.Telemetry.authorizedContacts"))
      }
    } header: {
      Text(L10n.Settings.Telemetry.header)
    } footer: {
      Text(IsraL10n.tr("Isra.UI.Telemetry.footer"))
    }
    .themedRowBackground(theme)
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  private func modePicker(_ title: String, category: Category) -> some View {
    let current = currentMode(category)
    return Picker(title, selection: binding(category)) {
      ForEach(IsraTelemetryMode.allCases, id: \.rawValue) { mode in
        Text(Self.label(mode)).tag(mode.rawValue)
      }
      if IsraTelemetryMode(raw: current) == nil {
        Text(IsraL10n.tr("Isra.UI.Telemetry.mode.other", Int(current))).tag(current)
      }
    }
    .radioDisabled(for: appState.connectionState, or: isSaving)
  }

  static func label(_ mode: IsraTelemetryMode) -> String {
    switch mode {
    case .nobody: IsraL10n.tr("Isra.UI.Telemetry.mode.nobody")
    case .authorizedContacts: IsraL10n.tr("Isra.UI.Telemetry.mode.authorized")
    case .everyone: IsraL10n.tr("Isra.UI.Telemetry.mode.everyone")
    }
  }

  private func currentMode(_ category: Category) -> UInt8 {
    guard let device else { return 0 }
    return switch category {
    case .base: device.telemetryModeBase
    case .location: device.telemetryModeLoc
    case .environment: device.telemetryModeEnv
    }
  }

  private func binding(_ category: Category) -> Binding<UInt8> {
    Binding(
      get: { currentMode(category) },
      set: { newValue in
        guard newValue != currentMode(category), IsraTelemetryMode(raw: newValue) != nil else { return }
        save(category, newValue)
      }
    )
  }

  // MARK: - Save

  /// Writes only `category`'s mode; the other two are re-read from the radio.
  private func save(_ category: Category, _ mode: UInt8) {
    guard let settingsService = appState.services?.settingsService else { return }

    isSaving = true
    Task {
      do {
        switch category {
        case .base:
          try await IsraRadioWrites.otherParams(settingsService, telemetryModeBase: mode)
        case .location:
          try await IsraRadioWrites.otherParams(settingsService, telemetryModeLocation: mode)
        case .environment:
          try await IsraRadioWrites.otherParams(settingsService, telemetryModeEnvironment: mode)
        }
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { save(category, mode) },
          onMaxRetriesExceeded: { dismiss() }
        )
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}
