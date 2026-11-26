import MC1Services
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mc1", category: "IsraLocationSettings")

/// isra: replaces LocationSettingsSection (a copy of upstream v1.7.1 with these changes):
/// - The advert location policy is shown read-only, as the radio reports it. The
///   "share location publicly" toggle is gone and nothing here writes the policy:
///   it is changed on the device only (Settings › All settings › Privacy › Advert pos).
/// - The app never switches the radio's GPS off: choosing the phone as source and
///   turning auto-update off leave the GPS as it is. Only the device GPS toggle
///   (an explicit choice) switches it.
struct IsraLocationSettingsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Binding var showingLocationPicker: Bool
  @State private var autoUpdateLocation = false
  @State private var gpsSource: GPSSource = .phone
  @State private var deviceHasGPS = false
  @State private var deviceGPSEnabled = false
  @State private var errorMessage: String?
  @State private var showLocationDeniedAlert = false
  @State private var retryAlert = RetryAlertState()
  @State private var isSaving = false

  private let devicePreferenceStore = DevicePreferenceStore()

  private var shouldPollDeviceGPS: Bool {
    autoUpdateLocation && gpsSource == .device && deviceGPSEnabled
  }

  /// The radio's advert location policy byte, as last read from SELF_INFO.
  private var advertPolicy: UInt8 {
    appState.connectedDevice?.advertLocationPolicy ?? 0
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
        .radioDisabled(for: appState.connectionState, or: isSaving || autoUpdateLocation)

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

        Toggle(isOn: $autoUpdateLocation) {
          TintedLabel(L10n.Settings.Location.autoUpdate, systemImage: "location.circle")
        }
        .onChange(of: autoUpdateLocation) { _, newValue in
          handleAutoUpdateChange(newValue)
        }
        .radioDisabled(for: appState.connectionState, or: isSaving)

        if autoUpdateLocation {
          if deviceHasGPS {
            Picker(L10n.Settings.Location.gpsSource, selection: $gpsSource) {
              Text(L10n.Settings.Location.GpsSource.phone).tag(GPSSource.phone)
              Text(L10n.Settings.Location.GpsSource.device).tag(GPSSource.device)
            }
            .onChange(of: gpsSource) { oldValue, newValue in
              handleGPSSourceChange(from: oldValue, to: newValue)
            }
            .radioDisabled(for: appState.connectionState, or: isSaving)
          } else {
            LabeledContent(L10n.Settings.Location.gpsSource) {
              Text(L10n.Settings.Location.GpsSource.phone)
                .foregroundStyle(.secondary)
            }
          }
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
      loadPreferences()
      guard appState.canRunSettingsStartupReads else {
        logger.debug("Deferring location settings startup reads until sync is less contended")
        return
      }
      await loadDeviceGPSState()
    }
    .task(id: shouldPollDeviceGPS) {
      guard shouldPollDeviceGPS,
            let settingsService = appState.services?.settingsService else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3))
        guard let device = appState.connectedDevice,
              device.latitude == 0, device.longitude == 0 else { break }
        try? await settingsService.refreshDeviceInfo()
      }
    }
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
    .alert(L10n.Onboarding.Permissions.LocationAlert.title, isPresented: $showLocationDeniedAlert) {
      Button(L10n.Onboarding.Permissions.LocationAlert.openSettings) {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          openURL(url)
        }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Onboarding.Permissions.LocationAlert.message)
    }
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

  private func loadPreferences() {
    if let device = appState.connectedDevice {
      autoUpdateLocation = devicePreferenceStore.isAutoUpdateLocationEnabled(deviceID: device.id)
      gpsSource = devicePreferenceStore.gpsSource(deviceID: device.id)
    }
  }

  private func loadDeviceGPSState() async {
    guard appState.canRunSettingsStartupReads, let settingsService = appState.services?.settingsService else { return }
    do {
      let state = try await settingsService.getDeviceGPSState()
      deviceHasGPS = state.isSupported
      deviceGPSEnabled = state.isEnabled
      if let deviceID = appState.connectedDevice?.id,
         state.isEnabled,
         !devicePreferenceStore.hasSetGPSSource(deviceID: deviceID) {
        gpsSource = .device
        devicePreferenceStore.setGPSSource(.device, deviceID: deviceID)
      }
      if state.isEnabled {
        try? await settingsService.refreshDeviceInfo()
      }
    } catch {
      deviceHasGPS = false
      deviceGPSEnabled = false
    }
  }

  /// isra: turning auto-update off no longer switches the radio's GPS off.
  private func handleAutoUpdateChange(_ newValue: Bool) {
    guard let deviceID = appState.connectedDevice?.id else { return }
    if newValue, gpsSource == .phone, appState.locationService.isLocationDenied {
      autoUpdateLocation = false
      showLocationDeniedAlert = true
      return
    }
    devicePreferenceStore.setAutoUpdateLocationEnabled(newValue, deviceID: deviceID)
    if newValue, gpsSource == .phone {
      appState.locationService.requestPermissionIfNeeded()
    }
    if gpsSource == .device, newValue, !deviceGPSEnabled {
      saveDeviceGPS(
        true,
        onFailure: {
          autoUpdateLocation = false
          devicePreferenceStore.setAutoUpdateLocationEnabled(false, deviceID: deviceID)
        }
      )
    }
  }

  /// isra: choosing the phone as source no longer switches the radio's GPS off.
  private func handleGPSSourceChange(from oldValue: GPSSource, to newValue: GPSSource) {
    guard let deviceID = appState.connectedDevice?.id else { return }
    if newValue == .phone, appState.locationService.isLocationDenied {
      gpsSource = oldValue
      showLocationDeniedAlert = true
      return
    }

    devicePreferenceStore.setGPSSource(newValue, deviceID: deviceID)
    if newValue == .phone {
      appState.locationService.requestPermissionIfNeeded()
    } else if autoUpdateLocation, !deviceGPSEnabled {
      saveDeviceGPS(
        true,
        onFailure: {
          gpsSource = oldValue
          devicePreferenceStore.setGPSSource(oldValue, deviceID: deviceID)
        }
      )
    }
  }

  /// The explicit device GPS toggle. isra: no advert policy write after it.
  private func updateDeviceGPSToggle(_ enabled: Bool) {
    guard let deviceID = appState.connectedDevice?.id else { return }
    let shouldDisableAutoUpdate = !enabled && autoUpdateLocation && gpsSource == .device
    saveDeviceGPS(enabled) {
      if shouldDisableAutoUpdate {
        autoUpdateLocation = false
        devicePreferenceStore.setAutoUpdateLocationEnabled(false, deviceID: deviceID)
      }
    }
  }

  private func saveDeviceGPS(
    _ enabled: Bool,
    onSuccess: (@MainActor () async throws -> Void)? = nil,
    onFailure: (@MainActor () -> Void)? = nil
  ) {
    guard let settingsService = appState.services?.settingsService else { return }

    let previousEnabled = deviceGPSEnabled
    isSaving = true

    Task {
      do {
        let state = try await settingsService.setDeviceGPSEnabledVerified(enabled)
        deviceHasGPS = state.isSupported
        deviceGPSEnabled = state.isEnabled
        if let onSuccess {
          try await onSuccess()
        }
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        deviceGPSEnabled = previousEnabled
        onFailure?()
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { saveDeviceGPS(enabled, onSuccess: onSuccess, onFailure: onFailure) },
          onMaxRetriesExceeded: { dismiss() }
        )
      } catch {
        deviceGPSEnabled = previousEnabled
        onFailure?()
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}
