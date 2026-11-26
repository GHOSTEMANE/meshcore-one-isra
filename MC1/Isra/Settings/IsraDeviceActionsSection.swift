import MC1Services
import SwiftUI

/// isra: replaces DeviceActionsSection. The paired radio is never rebooted by
/// software: the button only explains how to restart it (a MeshCore Solo can hang at
/// boot after a soft reboot until its switch is off for 15 s). Power off is unchanged.
struct IsraDeviceActionsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var showingRebootInfo = false
  @State private var showingPowerOffAlert = false
  @State private var isPoweringOff = false
  @State private var errorMessage: String?

  var body: some View {
    Section {
      Button {
        showingRebootInfo = true
      } label: {
        Label(L10n.Settings.DeviceActions.rebootDevice, systemImage: "arrow.clockwise")
          .foregroundStyle(.secondary)
      }

      if appState.connectedDevice?.supportsRadioCLI == true {
        Button(role: .destructive) {
          showingPowerOffAlert = true
        } label: {
          if isPoweringOff {
            HStack {
              ProgressView()
              Text(L10n.Settings.DeviceActions.powerOff)
            }
          } else {
            Label(L10n.Settings.DeviceActions.powerOff, systemImage: "power")
          }
        }
        .radioDisabled(for: appState.connectionState, or: isPoweringOff)
      }
    } header: {
      Text(L10n.Settings.DeviceActions.header)
    } footer: {
      Text(IsraL10n.tr("Isra.UI.Reboot.blocked"))
    }
    .themedRowBackground(theme)
    .alert(L10n.Settings.DeviceActions.rebootDevice, isPresented: $showingRebootInfo) {
      Button(L10n.Localizable.Common.ok, role: .cancel) {}
    } message: {
      Text(IsraL10n.tr("Isra.UI.Reboot.blocked"))
    }
    .alert(L10n.Settings.DeviceActions.Alert.PowerOff.title, isPresented: $showingPowerOffAlert) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.DeviceActions.Alert.PowerOff.confirm, role: .destructive) {
        powerOffDevice()
      }
    } message: {
      Text(L10n.Settings.DeviceActions.Alert.PowerOff.message)
    }
    .errorAlert($errorMessage)
  }

  private func powerOffDevice() {
    isPoweringOff = true
    Task {
      defer { isPoweringOff = false }
      do {
        try await appState.powerOffRadio()
      } catch is PowerOffSuperseded {
        return
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}
