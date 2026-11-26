import MC1Services
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "IsraLocationSettings")

/// isra: replaces LocationSettingsSection (a copy of upstream v1.7.1 with these changes):
/// - The advert location policy is shown read-only, as the radio reports it. The
///   "share location publicly" toggle is gone and nothing here writes the policy:
///   it is changed on the device only (Settings › All settings › Privacy › Advert pos).
/// - No "update location automatically" / "GPS source" rows: they only fed the
///   refresh before an advert, which the isra build never does (an advert never
///   writes the phone position nor switches the radio GPS on; see
///   `IsraRadioWrites.advertRefreshesLocation`).
/// - The app never switches the radio's GPS: only the device GPS toggle (an
///   explicit choice) turns it on or off.
struct IsraLocationSettingsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Binding var showingLocationPicker: Bool
  @State private var deviceHasGPS = false
  @State private var deviceGPSEnabled = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()
  @State private var isSaving = false

  /// The radio's advert location policy byte: live from the isra firmware (HELLO reply,
  /// STATE push on every change on the device); otherwise as last read from SELF_INFO.
  private var advertPolicy: UInt8 {
    let device = appState.connectedDevice
    return IsraCenter.shared.liveAdvertPolicy(devicePublicKey: device?.publicKey)
      ?? device?.advertLocationPolicy ?? 0
  }

  var body: some View {
    Group {
      Section {
        Button {
          showingLocationPicker = true
        } label: {
          HStack {
            TintedLabel(L10n.Settings.Node.setLocation, systemImage: "mappin.and.ellipse")
            Spacer()
            if let device = appState.connectedDevice,
               device.latitude != 0 || device.longitude != 0 {
              Text(L10n.Settings.Node.locationSet)
                .foregroundStyle(.secondary)
            } else {
              Text(L10n.Settings.Node.locationNotSet)
                .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        .foregroundStyle(.primary)
        .radioDisabled(for: appState.connectionState, or: isSaving)

        LabeledContent {
          Text(IsraL10n.tr(advertPolicy == 0 ? "Isra.UI.Location.advertPos.off" : "Isra.UI.Location.advertPos.on"))
            .foregroundStyle(advertPolicy == 0 ? Color.secondary : Color.orange)
        } label: {
          TintedLabel(IsraL10n.tr("Isra.UI.Location.advertPos"), systemImage: "location")
        }

        if advertPolicy != 0 {
          Label(IsraL10n.tr("Isra.UI.Location.advertPos.warning"), systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
        }
      } header: {
        Text(L10n.Settings.Location.header)
      } footer: {
        Text(IsraL10n.tr("Isra.UI.Location.footer"))
      }
      .themedRowBackground(theme)

      if deviceHasGPS {
        Section {
          Toggle(isOn: deviceGPSBinding) {
            TintedLabel(L10n.Settings.Location.DeviceGps.toggle, systemImage: "location.circle")
          }
          .radioDisabled(for: appState.connectionState, or: isSaving)
        } header: {
          Text(L10n.Settings.Location.DeviceGps.header)
        } footer: {
          Text(IsraL10n.tr("Isra.UI.Location.gpsFooter"))
        }
        .themedRowBackground(theme)
      }
    }
    .task(id: startupTaskID) {
      guard appState.canRunSettingsStartupReads else {
        logger.debug("Deferring location settings startup reads until sync is less contended")
        return
      }
      await loadDeviceGPSState()
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  private var startupTaskID: String {
    let deviceID = appState.connectedDevice?.id.uuidString ?? "none"
    let syncPhase = appState.connectionUI.currentSyncPhase.map { String(describing: $0) } ?? "none"
    return "\(deviceID)-\(String(describing: appState.connectionState))-\(syncPhase)-picker:\(showingLocationPicker)"
  }

  private var deviceGPSBinding: Binding<Bool> {
    Binding(
      get: { deviceGPSEnabled },
      set: { updateDeviceGPSToggle($0) }
    )
  }

  private func loadDeviceGPSState() async {
    guard appState.canRunSettingsStartupReads, let settingsService = appState.services?.settingsService else { return }
    do {
      let state = try await settingsService.getDeviceGPSState()
      deviceHasGPS = state.isSupported
      deviceGPSEnabled = state.isEnabled
      if state.isEnabled {
        try? await settingsService.refreshDeviceInfo()
      }
    } catch {
      deviceHasGPS = false
      deviceGPSEnabled = false
    }
  }

  /// The explicit device GPS toggle. isra: no advert policy write after it.
  private func updateDeviceGPSToggle(_ enabled: Bool) {
    saveDeviceGPS(enabled)
  }

  private func saveDeviceGPS(_ enabled: Bool) {
    guard let settingsService = appState.services?.settingsService else { return }

    let previousEnabled = deviceGPSEnabled
    isSaving = true

    Task {
      do {
        let state = try await settingsService.setDeviceGPSEnabledVerified(enabled)
        deviceHasGPS = state.isSupported
        deviceGPSEnabled = state.isEnabled
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        deviceGPSEnabled = previousEnabled
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { saveDeviceGPS(enabled) },
          onMaxRetriesExceeded: { dismiss() }
        )
      } catch {
        deviceGPSEnabled = previousEnabled
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}
