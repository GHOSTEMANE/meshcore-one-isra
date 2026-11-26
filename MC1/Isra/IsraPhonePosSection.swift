import CoreLocation
import MeshCore
import SwiftUI

/// Settings section "Phone position for telemetry" (isra/PROTOCOL.md section 2).
/// Shown under the Location section; per device.
struct IsraPhonePosSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.openURL) private var openURL
  @State private var enabled = false
  @State private var askedForAlways = false

  private var center: IsraCenter { IsraCenter.shared }
  private var service: IsraPhonePosService { IsraCenter.shared.phonePos }

  var body: some View {
    if let device = appState.connectedDevice {
      Section {
        Toggle(isOn: Binding(
          get: { enabled },
          set: { newValue in
            enabled = newValue
            Task { await center.setPhonePositionEnabled(newValue, devicePublicKey: device.publicKey) }
          }
        )) {
          Text(tr("toggle"))
        }

        if enabled {
          permissionRow
          statusRow(tr("firmware"), value: firmwareText, ok: firmwareSupports)
          // Live: HELLO reply, then every STATE push from the radio.
          if firmwareSupports, let state = center.deviceState {
            statusRow(tr("deviceSetting"), value: onOff(state.contains(.phonePositionSetting)),
                      ok: state.contains(.phonePositionSetting))
            statusRow(tr("gps"), value: gpsText(state),
                      ok: state.isSuperset(of: [.gpsOn, .gpsDutyCycle]))
            if !state.isSuperset(of: [.phonePositionSetting, .gpsOn, .gpsDutyCycle]) {
              Text(tr("deviceHint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button(tr("refresh")) {
              Task { await center.resendHello() }
            }
          }
          lastSentRow
          if let failure = service.lastFailure {
            Text(failureText(failure))
              .font(.footnote)
              .foregroundStyle(.orange)
            if let until = service.backoffUntil, until > Date() {
              Text(IsraL10n.tr("Isra.Core.phonePos.backoff", until.formatted(date: .omitted, time: .shortened)))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        Text(tr("header"))
      } footer: {
        Text(tr("footer"))
      }
      .themedRowBackground(theme)
      .onAppear {
        enabled = IsraSettings.phonePositionEnabled(devicePublicKey: device.publicKey)
        if enabled { service.refreshAuthorization() }
      }
    }
  }

  // MARK: - Rows

  @ViewBuilder
  private var permissionRow: some View {
    let status = service.authorization
    statusRow(tr("permission"), value: permissionText(status), ok: status == .authorizedAlways)
    if status != .authorizedAlways {
      Button(permissionButtonTitle(status)) {
        if askedForAlways || !service.requestAlwaysAuthorization() {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        askedForAlways = true
      }
    }
  }

  @ViewBuilder
  private var lastSentRow: some View {
    HStack {
      Text(tr("lastSent"))
      Spacer()
      if let date = service.lastSentAt {
        Text(date, format: .dateTime.hour().minute().second())
          .foregroundStyle(.secondary)
      } else {
        Text(tr("never"))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func statusRow(_ title: String, value: String, ok: Bool) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(ok ? Color.secondary : Color.orange)
        .multilineTextAlignment(.trailing)
    }
  }

  // MARK: - Texts

  private var firmwareSupports: Bool {
    center.firmwareReply?.caps.contains(.phonePosition) == true
  }

  private var firmwareText: String {
    switch center.hello {
    case let .supported(reply, _):
      reply.caps.contains(.phonePosition) ? tr("firmware.yes") : tr("firmware.noFeature")
    case .unsupported:
      tr("firmware.stock")
    case .failed, .notSent, .gaveUp:
      tr("firmware.unknown")
    }
  }

  private func gpsText(_ state: IsraProtocol.DeviceState) -> String {
    if !state.contains(.gpsOn) { return tr("gps.off") }
    return state.contains(.gpsDutyCycle) ? tr("gps.dutyCycle") : tr("gps.alwaysOn")
  }

  private func permissionText(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways: tr("permission.always")
    case .authorizedWhenInUse: tr("permission.whenInUse")
    case .denied, .restricted: tr("permission.denied")
    case .notDetermined: tr("permission.notDetermined")
    @unknown default: tr("permission.notDetermined")
    }
  }

  private func permissionButtonTitle(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: tr("permission.request")
    case .authorizedWhenInUse where !askedForAlways: tr("permission.request")
    default: tr("permission.openSettings")
    }
  }

  private func failureText(_ failure: IsraPhonePosService.Failure) -> String {
    switch failure {
    case .deviceSetting: tr("error.deviceSetting")
    case .rejected: tr("error.rejected")
    case let .deviceError(code): IsraL10n.tr("Isra.Core.phonePos.error.device", Int(code))
    case .noFix: tr("error.noFix")
    case .unusableFix: tr("error.unusableFix")
    case .notSent: tr("error.notSent")
    }
  }

  private func onOff(_ on: Bool) -> String {
    on ? tr("on") : tr("off")
  }

  private func tr(_ key: String) -> String {
    IsraL10n.tr("Isra.Core.phonePos." + key)
  }
}
