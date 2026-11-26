import MC1Services
import SwiftUI

/// isra: replaces BluetoothSection.
/// - Two PIN choices only: random, shown on the radio's screen (writes 0), or a
///   custom 6-digit PIN. Upstream's "Default" wrote 123456, a PIN everyone knows,
///   and showed 0 and 123456 alike; here 123456 shows as custom, with a warning,
///   and cannot be chosen.
/// - Changing the PIN never reboots the radio (a MeshCore Solo can hang at boot
///   after a soft reboot). The radio saves it and uses it after the next power cycle.
struct IsraBluetoothSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var pinType: PinType = .random
  @State private var customPin = ""
  @State private var showingPinEntry = false
  @State private var showingRandomConfirmation = false
  @State private var isChangingPin = false
  @State private var errorMessage: String?
  @State private var hasInitialized = false
  @State private var isPinVisible = false
  @State private var isRenaming = false
  /// The PIN written in this session, as read back from the radio. It applies only
  /// after a power cycle, and DEVICE_INFO is not re-read until the next connection.
  @State private var savedPin: UInt32?

  enum PinType: Hashable {
    case random, custom
  }

  static let randomPin: UInt32 = 0
  static let knownDefaultPin: UInt32 = 123_456
  static let customRange: ClosedRange<UInt32> = 100_000...999_999

  /// The radio's stored PIN: the one written here, else the one read at connection.
  private var storedPin: UInt32 {
    savedPin ?? appState.connectedDevice?.blePin ?? Self.randomPin
  }

  private var storedPinType: PinType {
    storedPin == Self.randomPin ? .random : .custom
  }

  var body: some View {
    Section {
      Picker(L10n.Settings.Bluetooth.pinType, selection: $pinType) {
        Text(IsraL10n.tr("Isra.UI.Pin.random")).tag(PinType.random)
        Text(IsraL10n.tr("Isra.UI.Pin.custom")).tag(PinType.custom)
      }
      .onChange(of: pinType) { _, newValue in
        guard hasInitialized, newValue != storedPinType else { return }
        if newValue == .custom {
          customPin = ""
          showingPinEntry = true
        } else {
          showingRandomConfirmation = true
        }
      }
      .radioDisabled(for: appState.connectionState, or: isChangingPin)

      if storedPinType == .custom {
        Button {
          isPinVisible.toggle()
        } label: {
          HStack {
            Text(L10n.Settings.Bluetooth.currentPin)
            Spacer()
            Group {
              if isPinVisible {
                Text(storedPin, format: .number.grouping(.never))
              } else {
                Text("••••••")
              }
            }
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)

            Image(systemName: isPinVisible ? "eye" : "eye.slash")
              .foregroundStyle(.tertiary)
              .imageScale(.small)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)

        Button(L10n.Settings.Bluetooth.changePin) {
          customPin = ""
          showingPinEntry = true
        }
        .radioDisabled(for: appState.connectionState, or: isChangingPin)
      }

      if appState.connectionState == .ready,
         let deviceID = appState.connectedDevice?.id,
         appState.connectionManager.supportsDeviceRename,
         appState.connectionManager.hasAccessory(for: deviceID) {
        Button {
          renameDevice()
        } label: {
          HStack {
            Text(L10n.Settings.Bluetooth.changeDisplayName)
            Spacer()
            if isRenaming {
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .radioDisabled(for: appState.connectionState, or: isRenaming)
      }
    } header: {
      Text(L10n.Settings.Bluetooth.header)
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if storedPin == Self.knownDefaultPin {
          Text(IsraL10n.tr("Isra.UI.Pin.knownDefault"))
            .foregroundStyle(.orange)
        }
        Text(IsraL10n.tr(storedPinType == .random ? "Isra.UI.Pin.randomFooter" : "Isra.UI.Pin.customFooter"))
        if savedPin != nil {
          Text(IsraL10n.tr("Isra.UI.Pin.pending"))
            .foregroundStyle(.orange)
        }
      }
    }
    .themedRowBackground(theme)
    .onAppear {
      isPinVisible = false
      syncPicker()
    }
    .alert(L10n.Settings.Bluetooth.Alert.SetPin.title, isPresented: $showingPinEntry) {
      TextField(L10n.Settings.Bluetooth.pinPlaceholder, text: $customPin)
        .keyboardType(.numberPad)
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        syncPicker()
      }
      Button(L10n.Settings.Bluetooth.setPin) {
        setCustomPin()
      }
    } message: {
      Text(IsraL10n.tr("Isra.UI.Pin.setMessage"))
    }
    .alert(IsraL10n.tr("Isra.UI.Pin.toRandomTitle"), isPresented: $showingRandomConfirmation) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        syncPicker()
      }
      Button(L10n.Settings.Bluetooth.Alert.change) {
        writePin(Self.randomPin)
      }
    } message: {
      Text(IsraL10n.tr("Isra.UI.Pin.toRandomMessage"))
    }
    .errorAlert($errorMessage)
  }

  /// Puts the picker back on the stored type without triggering its onChange.
  private func syncPicker() {
    hasInitialized = false
    pinType = storedPinType
    Task { @MainActor in
      hasInitialized = true
    }
  }

  private func setCustomPin() {
    guard let pin = UInt32(customPin), Self.customRange.contains(pin) else {
      errorMessage = L10n.Settings.Bluetooth.Error.invalidPin
      customPin = ""
      syncPicker()
      return
    }
    guard pin != Self.knownDefaultPin else {
      errorMessage = IsraL10n.tr("Isra.UI.Pin.knownDefault")
      customPin = ""
      syncPicker()
      return
    }
    writePin(pin)
    customPin = ""
  }

  /// Writes the PIN (the radio saves it) and reads it back. No reboot.
  private func writePin(_ pin: UInt32) {
    isChangingPin = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }
        try await settingsService.setBlePin(pin)
        let readBack = try await settingsService.queryDevice().blePin
        savedPin = readBack
        if readBack != pin {
          errorMessage = IsraL10n.tr("Isra.UI.Pin.notConfirmed")
        }
      } catch {
        errorMessage = error.userFacingMessage
      }
      syncPicker()
      isChangingPin = false
    }
  }

  private func renameDevice() {
    isRenaming = true
    Task { @MainActor in
      defer { isRenaming = false }
      do {
        try await appState.connectionManager.renameCurrentDevice()
      } catch {
        // Cancelled or failed; the user can try again.
      }
    }
  }
}
