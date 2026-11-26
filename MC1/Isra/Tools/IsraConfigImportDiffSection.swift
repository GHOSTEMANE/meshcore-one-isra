import MC1Services
import SwiftUI

/// Config import preview, isra part: the whole diff (radio now vs file) and the
/// opt-ins for the fields that stay out by default. Upstream's section toggles and
/// its confirmation alert still apply on top of this.
struct IsraConfigImportDiffSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: NodeConfigImportViewModel
  @State private var guardModel = IsraConfigImportGuard.shared
  @State private var current = IsraConfigImportGuard.Current()

  private var original: MeshCoreNodeConfig? { viewModel.importedConfig }
  private var optIns: IsraConfigImportGuard.OptIns { guardModel.optIns(for: viewModel.inputID) }

  var body: some View {
    if let original {
      let rows = IsraConfigImportGuard.rows(original, current: current, optIns: optIns)
      Section {
        if original.privateKey != nil {
          optIn(IsraL10n.tr("Isra.Tools.Import.optInPrivateKey"), \.privateKey, warning: true)
        }
        if let other = original.otherSettings {
          if other.telemetryModeBase != nil || other.telemetryModeLocation != nil || other.telemetryModeEnvironment != nil {
            optIn(IsraL10n.tr("Isra.Tools.Import.optInTelemetry"), \.telemetry, warning: false)
          }
          if other.advertLocationPolicy != nil {
            optIn(IsraL10n.tr("Isra.Tools.Import.optInAdvertPolicy"), \.advertPolicy, warning: false)
          }
        }
        Label(IsraL10n.tr("Isra.Tools.Import.pinNote"), systemImage: "lock")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } header: {
        Text(IsraL10n.tr("Isra.Tools.Import.excludedHeader"))
      } footer: {
        Text(IsraL10n.tr("Isra.Tools.Import.excludedFooter"))
      }
      .themedRowBackground(theme)

      Section {
        if rows.isEmpty {
          Text(IsraL10n.tr("Isra.Tools.Import.nothing"))
            .foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(row.label)
                .font(.subheadline.weight(row.changes ? .semibold : .regular))
              Spacer()
              if row.excluded {
                Text(IsraL10n.tr("Isra.Tools.Import.notApplied"))
                  .font(.caption)
                  .foregroundStyle(.orange)
              } else if !row.changes {
                Text(IsraL10n.tr("Isra.Tools.Import.same"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Text("\(row.current) → \(row.file)")
              .font(.footnote.monospacedDigit())
              .foregroundStyle(row.changes && !row.excluded ? .primary : .secondary)
              .strikethrough(row.excluded)
          }
          .accessibilityElement(children: .combine)
        }
      } header: {
        Text(IsraL10n.tr("Isra.Tools.Import.diffHeader"))
      } footer: {
        Text(IsraL10n.tr("Isra.Tools.Import.diffFooter"))
      }
      .themedRowBackground(theme)
      .task(id: appState.connectedDevice?.id) { await loadCurrent() }
    }
  }

  private func optIn(_ title: String, _ keyPath: WritableKeyPath<IsraConfigImportGuard.OptIns, Bool>, warning: Bool) -> some View {
    Toggle(isOn: Binding(
      get: { optIns[keyPath: keyPath] },
      set: { isOn in
        var newOptIns = optIns
        newOptIns[keyPath: keyPath] = isOn
        apply(newOptIns)
      }
    )) {
      Text(title)
        .foregroundStyle(warning && optIns[keyPath: keyPath] ? .orange : .primary)
    }
    .disabled(viewModel.isApplying || viewModel.isPreparingConfirmation)
  }

  /// Opting in also turns on the upstream section that carries the field.
  private func apply(_ newOptIns: IsraConfigImportGuard.OptIns) {
    guardModel.set(newOptIns, for: viewModel.inputID)
    if newOptIns.privateKey { viewModel.sections.nodeIdentity = true }
    if newOptIns.telemetry || newOptIns.advertPolicy { viewModel.sections.otherSettings = true }
  }

  private func loadCurrent() async {
    guard let device = appState.connectedDevice else { return }
    var value = IsraConfigImportGuard.Current()
    value.name = device.nodeName
    value.publicKeyHex = device.publicKey.map { String(format: "%02x", $0) }.joined()
    value.frequencyKHz = device.frequency
    value.bandwidthHz = device.bandwidth
    value.spreadingFactor = device.spreadingFactor
    value.codingRate = device.codingRate
    value.txPower = device.txPower
    value.hasPosition = device.latitude != 0 || device.longitude != 0
    value.manualAdd = device.manualAddContacts
    value.advertPolicy = device.advertLocationPolicy
    value.telemetryBase = device.telemetryModeBase
    value.telemetryLoc = device.telemetryModeLoc
    value.telemetryEnv = device.telemetryModeEnv
    value.multiAcks = device.multiAcks
    // The cached device can be stale (the device does not push changes made on it):
    // compare against a fresh SELF_INFO when the radio answers.
    if let info = try? await appState.services?.settingsService.getSelfInfo() {
      value.name = info.name
      value.frequencyKHz = UInt32((info.radioFrequency * 1000).rounded())
      value.bandwidthHz = UInt32((info.radioBandwidth * 1000).rounded())
      value.spreadingFactor = info.radioSpreadingFactor
      value.codingRate = info.radioCodingRate
      value.txPower = info.txPower
      value.hasPosition = info.latitude != 0 || info.longitude != 0
      value.manualAdd = info.manualAddContacts
      value.advertPolicy = info.advertisementLocationPolicy
      value.telemetryBase = info.telemetryModeBase
      value.telemetryLoc = info.telemetryModeLocation
      value.telemetryEnv = info.telemetryModeEnvironment
      value.multiAcks = info.multiAcks
    }
    if let store = appState.offlineDataStore {
      if let channels = try? await store.fetchChannels(radioID: device.radioID) {
        for channel in channels where !channel.name.isEmpty {
          value.channelsBySecret[channel.secret.map { String(format: "%02x", $0) }.joined()] = channel.name
          value.channelNames.insert(channel.name)
        }
      }
      if let contacts = try? await store.fetchContacts(radioID: device.radioID) {
        for contact in contacts {
          value.contactFlags[contact.publicKey.map { String(format: "%02x", $0) }.joined()] = contact.flags
        }
      }
    }
    current = value
  }
}
