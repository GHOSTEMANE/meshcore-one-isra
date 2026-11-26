import Foundation
import MC1Services
import Observation

/// Config import: what the file would change, field by field, and the sensitive
/// fields that stay out unless explicitly opted in (private key, telemetry modes,
/// advert position policy). The file shown stays as read; the filter is applied when
/// the import runs, so a field left out is never sent (the radio keeps its value:
/// `setOtherParamsVerified` merges missing fields from the radio). The PIN is not part
/// of the MeshCore config format.
@Observable
@MainActor
final class IsraConfigImportGuard {
  static let shared = IsraConfigImportGuard()

  struct OptIns: Equatable {
    var privateKey = false
    var telemetry = false
    var advertPolicy = false
  }

  /// The import input the opt-ins were chosen for. Opt-ins never carry over to another file.
  private(set) var inputID: UUID?
  private(set) var optIns = OptIns()

  /// Opt-ins for `inputID`; another input starts with every opt-in off.
  func optIns(for inputID: UUID?) -> OptIns {
    inputID != nil && inputID == self.inputID ? optIns : OptIns()
  }

  func set(_ optIns: OptIns, for inputID: UUID?) {
    self.inputID = inputID
    self.optIns = optIns
  }

  /// Hook for the apply step: the config actually written to the radio.
  func filtered(_ config: MeshCoreNodeConfig, inputID: UUID) -> MeshCoreNodeConfig {
    Self.filter(config, optIns(for: inputID))
  }

  nonisolated static func filter(_ config: MeshCoreNodeConfig, _ optIns: OptIns) -> MeshCoreNodeConfig {
    var config = config
    if !optIns.privateKey { config.privateKey = nil }
    if var other = config.otherSettings {
      if !optIns.telemetry {
        other.telemetryModeBase = nil
        other.telemetryModeLocation = nil
        other.telemetryModeEnvironment = nil
      }
      if !optIns.advertPolicy { other.advertLocationPolicy = nil }
      let empty = other.manualAddContacts == nil && other.advertLocationPolicy == nil
        && other.telemetryModeBase == nil && other.telemetryModeLocation == nil
        && other.telemetryModeEnvironment == nil && other.multiAcks == nil
      config.otherSettings = empty ? nil : other
    }
    return config
  }

  // MARK: - Diff

  /// The radio's current values the diff compares against.
  struct Current: Equatable {
    var name: String?
    var publicKeyHex: String?
    var frequencyKHz: UInt32?
    var bandwidthHz: UInt32?
    var spreadingFactor: UInt8?
    var codingRate: UInt8?
    var txPower: Int8?
    var hasPosition: Bool?
    var manualAdd: Bool?
    var advertPolicy: UInt8?
    var telemetryBase: UInt8?
    var telemetryLoc: UInt8?
    var telemetryEnv: UInt8?
    var multiAcks: UInt8?
    /// Channel secret (hex, lowercase) -> name.
    var channelsBySecret: [String: String] = [:]
    var channelNames: Set<String> = []
    /// Contact public key (hex, lowercase) -> flags.
    var contactFlags: [String: UInt8] = [:]
  }

  struct Row: Identifiable, Equatable {
    enum Group: String { case identity, radio, position, other, channels, contacts }
    let id: String
    let group: Group
    let label: String
    let current: String
    let file: String
    let changes: Bool
    /// Not applied unless opted in.
    let excluded: Bool
  }

  nonisolated static func rows(_ config: MeshCoreNodeConfig, current: Current, optIns: OptIns) -> [Row] {
    var rows: [Row] = []
    let dash = "—"
    func add(_ id: String, _ group: Row.Group, _ label: String, _ cur: String?, _ new: String?, excluded: Bool = false) {
      guard let new else { return }
      let cur = cur ?? dash
      rows.append(Row(id: id, group: group, label: label, current: cur, file: new, changes: cur != new, excluded: excluded))
    }

    add("name", .identity, L("Import.Field.name"), current.name, config.name)
    if let key = config.privateKey {
      let sameIdentity = config.publicKey.map { $0.lowercased() == current.publicKeyHex?.lowercased() }
      let fileValue = switch sameIdentity {
      case true?: L("Import.Value.sameIdentity")
      case false?: L("Import.Value.otherIdentity")
      case nil: L("Import.Value.keyPresent")
      }
      _ = key
      rows.append(Row(
        id: "privateKey", group: .identity, label: L("Import.Field.privateKey"),
        current: L("Import.Value.keyCurrent"), file: fileValue, changes: sameIdentity != true,
        excluded: !optIns.privateKey
      ))
    }

    if let radio = config.radioSettings {
      add("freq", .radio, L("Import.Field.frequency"), current.frequencyKHz.map(mhz), mhz(radio.frequency))
      add("bw", .radio, L("Import.Field.bandwidth"), current.bandwidthHz.map(khz), khz(radio.bandwidth))
      add("sf", .radio, "SF", current.spreadingFactor.map { String($0) }, String(radio.spreadingFactor))
      add("cr", .radio, "CR", current.codingRate.map { String($0) }, String(radio.codingRate))
      add("tx", .radio, L("Import.Field.txPower"), current.txPower.map { "\($0) dBm" }, "\(radio.txPower) dBm")
    }

    if let position = config.positionSettings {
      let filePos = position.isZero ? L("Import.Value.noPosition") : L("Import.Value.position")
      let curPos = current.hasPosition.map { $0 ? L("Import.Value.position") : L("Import.Value.noPosition") }
      // Coordinates are not shown here; the upstream rows below show them.
      add("position", .position, L("Import.Field.position"), curPos, filePos)
    }

    if let other = config.otherSettings {
      add("manualAdd", .other, L("Import.Field.manualAdd"), current.manualAdd.map(onOff), other.manualAddContacts.map { onOff($0 != 0) })
      add("multiAcks", .other, L("Import.Field.multiAcks"), current.multiAcks.map { String($0) }, other.multiAcks.map { String($0) })
      add(
        "advertPolicy", .other, L("Import.Field.advertPolicy"), current.advertPolicy.map(policy),
        other.advertLocationPolicy.map(policy), excluded: !optIns.advertPolicy
      )
      add(
        "telBase", .other, L("Import.Field.telemetryBase"), current.telemetryBase.map(telemetry),
        other.telemetryModeBase.map(telemetry), excluded: !optIns.telemetry
      )
      add(
        "telLoc", .other, L("Import.Field.telemetryLoc"), current.telemetryLoc.map(telemetry),
        other.telemetryModeLocation.map(telemetry), excluded: !optIns.telemetry
      )
      add(
        "telEnv", .other, L("Import.Field.telemetryEnv"), current.telemetryEnv.map(telemetry),
        other.telemetryModeEnvironment.map(telemetry), excluded: !optIns.telemetry
      )
    }

    if let channels = config.channels {
      for (index, channel) in channels.enumerated() {
        let existing = current.channelsBySecret[channel.secret.lowercased()]
        let cur: String = if let existing {
          existing
        } else if current.channelNames.contains(channel.name) {
          L("Import.Value.sameNameOtherKey")
        } else {
          L("Import.Value.absent")
        }
        rows.append(Row(
          id: "ch\(index)", group: .channels, label: channel.name, current: cur,
          file: existing == nil ? L("Import.Value.added") : channel.name,
          changes: existing != channel.name, excluded: false
        ))
      }
    }

    if let contacts = config.contacts {
      var new = 0, flagChanges = 0, same = 0
      for contact in contacts {
        guard let flags = current.contactFlags[contact.publicKey.lowercased()] else { new += 1; continue }
        if flags != contact.flags { flagChanges += 1 } else { same += 1 }
      }
      rows.append(Row(
        id: "contacts", group: .contacts, label: L("Import.Field.contacts"),
        current: L("Import.Value.contactsCurrent", current.contactFlags.count),
        file: L("Import.Value.contactsFile", contacts.count, new, flagChanges, same),
        changes: new + flagChanges > 0, excluded: false
      ))
    }
    return rows
  }

  nonisolated static func mhz(_ kHz: UInt32) -> String {
    (Double(kHz) / 1000).formatted(.number.precision(.fractionLength(0...3)).locale(.posix)) + " MHz"
  }

  nonisolated static func khz(_ hz: UInt32) -> String {
    (Double(hz) / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(.posix)) + " kHz"
  }

  nonisolated static func onOff(_ on: Bool) -> String {
    on ? L("Import.Value.on") : L("Import.Value.off")
  }

  nonisolated static func telemetry(_ mode: UInt8) -> String {
    switch mode {
    case 0: IsraL10n.tr("Isra.Tools.Journal.Value.telemetryNone")
    case 1: IsraL10n.tr("Isra.Tools.Journal.Value.telemetryTrusted")
    case 2: IsraL10n.tr("Isra.Tools.Journal.Value.telemetryAll")
    default: String(mode)
    }
  }

  nonisolated static func policy(_ value: UInt8) -> String {
    switch value {
    case 0: L("Import.Value.policyNone")
    case 1: L("Import.Value.policyShare")
    default: String(value)
    }
  }
}

private func L(_ key: String, _ args: CVarArg...) -> String {
  let format = IsraL10n.tr("Isra.Tools." + key)
  return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}
