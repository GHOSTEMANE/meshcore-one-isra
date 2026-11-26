import Foundation
import MeshCore

/// Turns the frames the app writes to its own radio into journal lines, and keeps the
/// last values the radio reported so a line can say "old -> new".
///
/// Pure and synchronous (no I/O), so the tests drive it with raw frames.
/// Never renders coordinates, private keys, channel secrets or PIN digits.
struct IsraRadioWriteDecoder {
  /// A frame that writes to the radio, ready to be journaled.
  struct Decoded {
    let kind: String
    let what: String
    let change: String?
    /// Set for `CMD_RUN_CLI_COMMAND` frames that carry an `XY|` correlation tag.
    let cliTag: String?
    let isCLI: Bool
    /// Applied to the cache when the radio confirms the write.
    let onSuccess: (@Sendable (inout Cache) -> Void)?
  }

  /// Last values seen from the radio. RAM only (channel secrets never leave it).
  struct Cache {
    var name: String?
    var txPower: Int8?
    var radio: RadioParams?
    var manualAdd: Bool?
    var telemetryBase: UInt8?
    var telemetryLoc: UInt8?
    var telemetryEnv: UInt8?
    var advertPolicy: UInt8?
    var multiAcks: UInt8?
    var hasLocation: Bool?
    var blePin: UInt32?
    var pathHashMode: UInt8?
    var autoAdd: AutoAddConfig?
    var defaultScope: String??
    var tuning: (rxDelay: Double, af: Double)?
    var radioClock: (value: Date, seenAt: Date)?
    var contacts: [Data: ContactSummary] = [:]
    var channels: [UInt8: (name: String, secret: Data)] = [:]
    var customVars: [String: String] = [:]
    var cliValues: [String: String] = [:]
    /// CLI `get` requests awaiting their tagged reply: tag -> key.
    var cliGets: [String: String] = [:]
  }

  struct RadioParams: Equatable {
    let frequencyKHz: Double
    let bandwidthKHz: Double
    let spreadingFactor: UInt8
    let codingRate: UInt8
  }

  struct ContactSummary: Equatable {
    var name: String
    var flags: UInt8
    var outPathLength: UInt8
  }

  var cache = Cache()

  // MARK: - Incoming

  /// Records what the radio says about itself. Returns the CLI reply body when the
  /// frame is a CLI reply, so the journal can match it to its command.
  mutating func observeIncoming(_ event: MeshEvent, now: Date = .now) {
    switch event {
    case let .selfInfo(info):
      cache.name = info.name
      cache.txPower = info.txPower
      cache.radio = RadioParams(
        frequencyKHz: info.radioFrequency * 1000,
        bandwidthKHz: info.radioBandwidth,
        spreadingFactor: info.radioSpreadingFactor,
        codingRate: info.radioCodingRate
      )
      cache.manualAdd = info.manualAddContacts
      cache.telemetryBase = info.telemetryModeBase
      cache.telemetryLoc = info.telemetryModeLocation
      cache.telemetryEnv = info.telemetryModeEnvironment
      cache.advertPolicy = info.advertisementLocationPolicy
      cache.multiAcks = info.multiAcks
      cache.hasLocation = info.latitude != 0 || info.longitude != 0
    case let .deviceInfo(caps):
      cache.blePin = caps.blePin
      cache.pathHashMode = caps.pathHashMode
    case let .currentTime(date):
      cache.radioClock = (date, now)
    case let .customVars(vars):
      cache.customVars = vars
    case let .channelInfo(info):
      cache.channels[info.index] = (info.name, info.secret)
    case let .autoAddConfig(config):
      cache.autoAdd = config
    case let .defaultFloodScope(scope):
      cache.defaultScope = .some(scope?.name)
    case let .tuningParamsResponse(tuning):
      cache.tuning = (tuning.rxDelayBase, tuning.airtimeFactor)
    case let .contact(contact), let .newContact(contact):
      cache.contacts[contact.publicKey] = ContactSummary(
        name: contact.advertisedName, flags: contact.flags.rawValue, outPathLength: contact.outPathLength
      )
    case let .contactDeleted(publicKey):
      cache.contacts[publicKey] = nil
    case let .cliReply(text):
      let (tag, body) = Self.splitCLITag(text)
      if let tag, let key = cache.cliGets.removeValue(forKey: tag), body.hasPrefix("> ") {
        cache.cliValues[key] = Self.trimmed(String(body.dropFirst(2)))
      }
    default:
      break
    }
  }

  // MARK: - Outgoing

  /// Returns a journal line for a frame that writes to the radio, nil for anything else.
  /// Also notes CLI `get` requests so their replies fill the cache.
  mutating func decodeOutgoing(_ frame: Data, now: Date = .now) -> Decoded? {
    guard let opcode = frame.first else { return nil }
    let body = frame.dropFirst()
    switch CommandCode(rawValue: opcode) {
    case .setTime: return decodeSetTime(body, now: now)
    case .setName: return decodeSetName(body)
    case .setRadio: return decodeSetRadio(body)
    case .setTxPower: return decodeTxPower(body)
    case .setCoordinates: return decodeCoordinates(body)
    case .updateContact: return decodeUpdateContact(body)
    case .removeContact: return decodeRemoveContact(body)
    case .resetPath: return decodeResetPath(body)
    case .importContact:
      return Decoded(kind: "contactImport", what: L("Journal.What.contactImport"), change: nil)
    case .reboot:
      return Decoded(kind: "reboot", what: L("Journal.What.reboot"), change: nil)
    case .setTuning: return decodeTuning(body)
    case .importPrivateKey:
      return Decoded(kind: "privateKey", what: L("Journal.What.privateKey"), change: L("Journal.Value.key"))
    case .setChannel: return decodeSetChannel(body)
    case .setDevicePin: return decodePin(body)
    case .setOtherParams: return decodeOtherParams(body)
    case .setCustomVar: return decodeCustomVar(body)
    case .factoryReset:
      return Decoded(kind: "factoryReset", what: L("Journal.What.factoryReset"), change: nil)
    case .setAutoAddConfig: return decodeAutoAdd(body)
    case .setPathHashMode: return decodePathHashMode(body)
    case .setDefaultFloodScope: return decodeDefaultScope(body)
    case .runCliCommand: return decodeCLI(body)
    default: return nil
    }
  }

  // MARK: - Decoders

  private func decodeSetTime(_ body: Data.SubSequence, now: Date) -> Decoded? {
    guard let seconds = body.u32(at: 0) else { return nil }
    let new = Date(timeIntervalSince1970: TimeInterval(seconds))
    var change = Self.clock(new)
    if let seen = cache.radioClock, now.timeIntervalSince(seen.seenAt) < 120 {
      let radioNow = seen.value.addingTimeInterval(now.timeIntervalSince(seen.seenAt))
      let drift = Int(new.timeIntervalSince(radioNow).rounded())
      change = "\(Self.clock(radioNow)) → \(Self.clock(new)) (\(L("Journal.Value.drift", Self.signed(drift))))"
    }
    return Decoded(kind: "setTime", what: L("Journal.What.setTime"), change: change)
  }

  private func decodeSetName(_ body: Data.SubSequence) -> Decoded {
    let new = Self.cString(body)
    return Decoded(
      kind: "setName", what: L("Journal.What.setName"), change: Self.arrow(cache.name, new),
      onSuccess: { $0.name = new }
    )
  }

  private func decodeSetRadio(_ body: Data.SubSequence) -> Decoded? {
    guard let freq = body.u32(at: 0), let bw = body.u32(at: 4), let sf = body.byte(at: 8), let cr = body.byte(at: 9)
    else { return nil }
    let new = RadioParams(
      frequencyKHz: Double(freq), bandwidthKHz: Double(bw) / 1000, spreadingFactor: sf, codingRate: cr
    )
    var change = Self.arrow(cache.radio.map(Self.format), Self.format(new))
    if let repeatFlag = body.byte(at: 10) {
      change += " · " + L("Journal.Value.clientRepeat", repeatFlag != 0 ? L("Journal.Value.on") : L("Journal.Value.off"))
    }
    return Decoded(kind: "setRadio", what: L("Journal.What.setRadio"), change: change, onSuccess: { $0.radio = new })
  }

  private func decodeTxPower(_ body: Data.SubSequence) -> Decoded? {
    guard let raw = body.byte(at: 0) else { return nil }
    let new = Int8(bitPattern: raw)
    return Decoded(
      kind: "setTxPower", what: L("Journal.What.setTxPower"),
      change: Self.arrow(cache.txPower.map { "\($0) dBm" }, "\(new) dBm"),
      onSuccess: { $0.txPower = new }
    )
  }

  private func decodeCoordinates(_ body: Data.SubSequence) -> Decoded? {
    guard let lat = body.i32(at: 0), let lon = body.i32(at: 4) else { return nil }
    let cleared = lat == 0 && lon == 0
    let old = cache.hasLocation.map { $0 ? L("Journal.Value.position") : L("Journal.Value.noPosition") }
    let new = cleared ? L("Journal.Value.noPosition") : L("Journal.Value.position")
    return Decoded(
      kind: "setCoordinates", what: L("Journal.What.setCoordinates"), change: Self.arrow(old, new),
      onSuccess: { $0.hasLocation = !cleared }
    )
  }

  private func decodeUpdateContact(_ body: Data.SubSequence) -> Decoded? {
    guard body.count >= 131, let flags = body.byte(at: 33), let pathLength = body.byte(at: 34) else { return nil }
    let key = Data(body.prefix(32))
    let name = Self.cString(body.dropFirst(99).prefix(32))
    let new = ContactSummary(name: name, flags: flags, outPathLength: pathLength)
    let update: @Sendable (inout Cache) -> Void = { $0.contacts[key] = new }
    guard let old = cache.contacts[key] else {
      return Decoded(
        kind: "contactAdd", what: L("Journal.What.contactAdd", name),
        change: L("Journal.Value.flags", Self.flags(flags)), onSuccess: update
      )
    }
    var parts: [String] = []
    if old.name != name { parts.append(L("Journal.Value.name") + ": " + Self.arrow(old.name, name)) }
    if old.flags != flags {
      parts.append(L("Journal.Value.flagsLabel") + ": " + Self.arrow(Self.flags(old.flags), Self.flags(flags)))
    }
    if old.outPathLength != pathLength {
      parts.append(L("Journal.Value.path") + ": " + Self.arrow(Self.path(old.outPathLength), Self.path(pathLength)))
    }
    let change = parts.isEmpty ? L("Journal.Value.unchanged") : parts.joined(separator: " · ")
    return Decoded(kind: "contactUpdate", what: L("Journal.What.contactUpdate", name), change: change, onSuccess: update)
  }

  private func decodeRemoveContact(_ body: Data.SubSequence) -> Decoded? {
    guard body.count >= 32 else { return nil }
    let key = Data(body.prefix(32))
    return Decoded(
      kind: "contactRemove", what: L("Journal.What.contactRemove", contactLabel(key)), change: nil,
      onSuccess: { $0.contacts[key] = nil }
    )
  }

  private func decodeResetPath(_ body: Data.SubSequence) -> Decoded? {
    guard body.count >= 32 else { return nil }
    let key = Data(body.prefix(32))
    let old = cache.contacts[key].map { Self.path($0.outPathLength) }
    return Decoded(
      kind: "resetPath", what: L("Journal.What.resetPath", contactLabel(key)),
      change: Self.arrow(old, Self.path(0xFF)),
      onSuccess: { $0.contacts[key]?.outPathLength = 0xFF }
    )
  }

  private func decodeTuning(_ body: Data.SubSequence) -> Decoded? {
    guard let rx = body.u32(at: 0), let afRaw = body.u32(at: 4) else { return nil }
    let rxDelay = Double(rx) / 1000
    let af = Double(afRaw) / 1000
    let old = cache.tuning.map { Self.tuning(rxDelay: $0.rxDelay, af: $0.af) }
    return Decoded(
      kind: "setTuning", what: L("Journal.What.setTuning"),
      change: Self.arrow(old, Self.tuning(rxDelay: rxDelay, af: af)),
      onSuccess: { $0.tuning = (rxDelay, af) }
    )
  }

  private func decodeSetChannel(_ body: Data.SubSequence) -> Decoded? {
    guard let index = body.byte(at: 0) else { return nil }
    let name = Self.cString(body.dropFirst(1).prefix(32))
    let secret = Data(body.dropFirst(33).prefix(16))
    let old = cache.channels[index]
    if name.isEmpty, secret.allSatisfy({ $0 == 0 }) {
      return Decoded(
        kind: "channelRemove",
        what: L("Journal.What.channelRemove", Int(index)),
        change: old.map { Self.arrow($0.name, "—") },
        onSuccess: { $0.channels[index] = nil }
      )
    }
    var change = Self.arrow(old?.name, name)
    if let old, old.name == name {
      change = old.secret == secret ? L("Journal.Value.unchanged") : L("Journal.Value.channelKeyChanged")
    }
    return Decoded(
      kind: "channelSet", what: L("Journal.What.channelSet", Int(index)), change: change,
      onSuccess: { $0.channels[index] = (name, secret) }
    )
  }

  private func decodePin(_ body: Data.SubSequence) -> Decoded? {
    guard let pin = body.u32(at: 0) else { return nil }
    return Decoded(
      kind: "setPin", what: L("Journal.What.setPin"),
      change: Self.arrow(cache.blePin.map(Self.pin), Self.pin(pin)),
      onSuccess: { $0.blePin = pin }
    )
  }

  private func decodeOtherParams(_ body: Data.SubSequence) -> Decoded? {
    guard let manual = body.byte(at: 0), let telemetry = body.byte(at: 1), let policy = body.byte(at: 2) else {
      return nil
    }
    let multiAcks = body.byte(at: 3)
    let base = telemetry & 0b11
    let loc = (telemetry >> 2) & 0b11
    let env = (telemetry >> 4) & 0b11
    var parts: [String] = []
    func field(_ label: String, _ old: String?, _ new: String) {
      if old != new { parts.append("\(label): \(Self.arrow(old, new))") }
    }
    field(L("Journal.Value.manualAdd"), cache.manualAdd.map(Self.onOff), Self.onOff(manual != 0))
    field(L("Journal.Value.telemetryBase"), cache.telemetryBase.map(Self.telemetry), Self.telemetry(base))
    field(L("Journal.Value.telemetryLoc"), cache.telemetryLoc.map(Self.telemetry), Self.telemetry(loc))
    field(L("Journal.Value.telemetryEnv"), cache.telemetryEnv.map(Self.telemetry), Self.telemetry(env))
    field(L("Journal.Value.advertPolicy"), cache.advertPolicy.map { String($0) }, String(policy))
    if let multiAcks {
      field(L("Journal.Value.multiAcks"), cache.multiAcks.map { String($0) }, String(multiAcks))
    }
    return Decoded(
      kind: "setOtherParams", what: L("Journal.What.setOtherParams"),
      change: parts.isEmpty ? L("Journal.Value.unchanged") : parts.joined(separator: " · "),
      onSuccess: {
        $0.manualAdd = manual != 0
        $0.telemetryBase = base
        $0.telemetryLoc = loc
        $0.telemetryEnv = env
        $0.advertPolicy = policy
        if let multiAcks { $0.multiAcks = multiAcks }
      }
    )
  }

  private func decodeCustomVar(_ body: Data.SubSequence) -> Decoded? {
    let text = String(decoding: body, as: UTF8.self)
    guard let colon = text.firstIndex(of: ":") else { return nil }
    let key = String(text[..<colon])
    let value = String(text[text.index(after: colon)...])
    let shown = Self.masked(key: key, value: value)
    let oldShown = cache.customVars[key].map { Self.masked(key: key, value: $0) }
    return Decoded(
      kind: "customVar", what: L("Journal.What.customVar", key), change: Self.arrow(oldShown, shown),
      onSuccess: { $0.customVars[key] = value }
    )
  }

  private func decodeAutoAdd(_ body: Data.SubSequence) -> Decoded? {
    guard let mask = body.byte(at: 0) else { return nil }
    let hops = body.byte(at: 1) ?? 0
    let fmt: (UInt8, UInt8) -> String = { String(format: "0x%02x", $0) + " · " + L("Journal.Value.maxHops", Int($1)) }
    return Decoded(
      kind: "autoAdd", what: L("Journal.What.autoAdd"),
      change: Self.arrow(cache.autoAdd.map { fmt($0.bitmask, $0.maxHops) }, fmt(mask, hops)),
      onSuccess: { $0.autoAdd = AutoAddConfig(bitmask: mask, maxHops: hops) }
    )
  }

  private func decodePathHashMode(_ body: Data.SubSequence) -> Decoded? {
    guard let mode = body.byte(at: 1) else { return nil }
    let fmt: (UInt8) -> String = { L("Journal.Value.hashBytes", Int($0) + 1) }
    return Decoded(
      kind: "pathHashMode", what: L("Journal.What.pathHashMode"),
      change: Self.arrow(cache.pathHashMode.map(fmt), fmt(mode)),
      onSuccess: { $0.pathHashMode = mode }
    )
  }

  private func decodeDefaultScope(_ body: Data.SubSequence) -> Decoded {
    let name = Self.cString(body.prefix(31))
    let shown = name.isEmpty ? L("Journal.Value.none") : name
    let old = cache.defaultScope.map { $0.flatMap { $0.isEmpty ? nil : $0 } ?? L("Journal.Value.none") }
    return Decoded(
      kind: "defaultScope", what: L("Journal.What.defaultScope"), change: Self.arrow(old, shown),
      onSuccess: { $0.defaultScope = .some(name.isEmpty ? nil : name) }
    )
  }

  private mutating func decodeCLI(_ body: Data.SubSequence) -> Decoded? {
    let (tag, command) = Self.splitCLITag(String(decoding: body, as: UTF8.self))
    let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let verb = words.first?.lowercased() else { return nil }
    if verb == "get", words.count >= 2 {
      if let tag { cache.cliGets[tag] = words[1] }
      return nil
    }
    guard Self.cliWriteVerbs.contains(verb) else { return nil }
    if verb == "gps", words.count < 2 { return nil }
    if verb == "region", words.count < 2 || ["list", "get"].contains(words[1].lowercased()) { return nil }
    if verb == "set", words.count >= 2 {
      let key = words[1]
      let value = words.dropFirst(2).joined(separator: " ")
      let shown = Self.masked(key: key, value: value)
      let old = cache.cliValues[key].map { Self.masked(key: key, value: $0) }
      return Decoded(
        kind: "cliSet", what: L("Journal.What.cliSet", key), change: Self.arrow(old, shown),
        cliTag: tag, isCLI: true, onSuccess: { $0.cliValues[key] = value }
      )
    }
    let shownCommand = Self.sensitive(verb) ? verb + " " + L("Journal.Value.hidden") : command
    return Decoded(
      kind: "cli", what: L("Journal.What.cli"), change: shownCommand, cliTag: tag, isCLI: true, onSuccess: nil
    )
  }

  private func contactLabel(_ key: Data) -> String {
    cache.contacts[key]?.name ?? key.prefix(4).map { String(format: "%02X", $0) }.joined()
  }

  // MARK: - Formatting

  static let cliWriteVerbs: Set<String> = [
    "set", "password", "erase", "clock", "time", "reboot", "poweroff", "start", "clear", "gps", "region", "setperm",
  ]

  /// Keys whose values never reach the journal.
  static func sensitive(_ key: String) -> Bool {
    let key = key.lowercased()
    return ["pin", "pass", "pwd", "key", "secret", "psk", "password"].contains { key.contains($0) }
  }

  static func isPositionKey(_ key: String) -> Bool {
    let key = key.lowercased()
    return ["lat", "lon", "latitude", "longitude", "node_lat", "node_lon"].contains(key)
  }

  static func masked(key: String, value: String) -> String {
    if isPositionKey(key) { return L("Journal.Value.position") }
    if sensitive(key) { return key.lowercased().contains("key") ? L("Journal.Value.key") : L("Journal.Value.hidden") }
    return value.isEmpty ? "—" : value
  }

  /// `XY|rest` -> ("XY|", "rest"). Matches `RadioCLICorrelationScope` tags.
  static func splitCLITag(_ text: String) -> (tag: String?, body: String) {
    let bytes = Array(text.utf8)
    guard bytes.count >= 3, bytes[2] == UInt8(ascii: "|"),
          bytes[0].isASCIIAlphanumeric, bytes[1].isASCIIAlphanumeric else { return (nil, text) }
    return (String(decoding: bytes[0..<3], as: UTF8.self), String(decoding: bytes[3...], as: UTF8.self))
  }

  static func arrow(_ old: String?, _ new: String) -> String {
    guard let old else { return "→ " + new }
    return old == new ? new + " (" + L("Journal.Value.same") + ")" : old + " → " + new
  }

  static func format(_ radio: RadioParams) -> String {
    let freq = (radio.frequencyKHz / 1000).formatted(.number.precision(.fractionLength(0...3)).locale(.posix))
    let bw = radio.bandwidthKHz.formatted(.number.precision(.fractionLength(0...1)).locale(.posix))
    return "\(freq) MHz · BW \(bw) · SF\(radio.spreadingFactor) · CR\(radio.codingRate)"
  }

  static func tuning(rxDelay: Double, af: Double) -> String {
    let fmt: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...2)).locale(.posix)) }
    let duty = 100 / (1 + af)
    return "rxdelay \(fmt(rxDelay)) · af \(fmt(af)) (\(L("Journal.Value.dutyCycle", fmt(duty))))"
  }

  static func pin(_ pin: UInt32) -> String {
    pin == 0 ? L("Journal.Value.pinRandom") : L("Journal.Value.pinFixed")
  }

  static func onOff(_ on: Bool) -> String { on ? L("Journal.Value.on") : L("Journal.Value.off") }

  static func telemetry(_ mode: UInt8) -> String {
    switch mode {
    case 0: L("Journal.Value.telemetryNone")
    case 1: L("Journal.Value.telemetryTrusted")
    case 2: L("Journal.Value.telemetryAll")
    default: String(mode)
    }
  }

  static func flags(_ raw: UInt8) -> String {
    var names: [String] = []
    if raw & 0x01 != 0 { names.append(L("Journal.Flag.favorite")) }
    if raw & 0x02 != 0 { names.append(L("Journal.Flag.base")) }
    if raw & 0x04 != 0 { names.append(L("Journal.Flag.location")) }
    if raw & 0x08 != 0 { names.append(L("Journal.Flag.environment")) }
    if raw & 0x10 != 0 { names.append(L("Journal.Flag.cli")) }
    return names.isEmpty ? L("Journal.Value.none") : names.joined(separator: ", ")
  }

  static func path(_ length: UInt8) -> String {
    if length == 0xFF { return L("Journal.Value.flood") }
    return L("Journal.Value.direct", Int(length & 0x3F))
  }

  static func clock(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.twoDigits).hour().minute().second())
  }

  static func signed(_ seconds: Int) -> String { seconds >= 0 ? "+\(seconds) s" : "\(seconds) s" }

  static func cString(_ bytes: some Collection<UInt8>) -> String {
    let trimmed = bytes.prefix { $0 != 0 }
    return String(decoding: trimmed, as: UTF8.self)
  }

  static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension IsraRadioWriteDecoder.Decoded {
  init(kind: String, what: String, change: String?, onSuccess: (@Sendable (inout IsraRadioWriteDecoder.Cache) -> Void)? = nil) {
    self.init(kind: kind, what: what, change: change, cliTag: nil, isCLI: false, onSuccess: onSuccess)
  }
}

private func L(_ key: String, _ args: CVarArg...) -> String {
  let format = IsraL10n.tr("Isra.Tools." + key)
  return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

private extension UInt8 {
  var isASCIIAlphanumeric: Bool {
    (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
  }
}

extension Data.SubSequence {
  func byte(at offset: Int) -> UInt8? {
    let index = startIndex + offset
    return index < endIndex ? self[index] : nil
  }

  func u32(at offset: Int) -> UInt32? {
    let start = startIndex + offset
    guard start + 4 <= endIndex else { return nil }
    return self[start..<start + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
  }

  func i32(at offset: Int) -> Int32? {
    u32(at: offset).map { Int32(bitPattern: $0) }
  }
}
