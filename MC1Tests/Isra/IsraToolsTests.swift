import Foundation
@testable import MC1
import MC1Services
import MeshCore
import Testing

@Suite("isra radio-writes decoder")
struct IsraRadioWriteDecoderTests {
  private func selfInfo(tx: Int8 = 22, telemetry: (UInt8, UInt8, UInt8) = (2, 1, 0)) -> SelfInfo {
    SelfInfo(
      advertisementType: 1, txPower: tx, maxTxPower: 22, publicKey: Data(repeating: 1, count: 32),
      latitude: 38.5, longitude: -8.9, multiAcks: 0, advertisementLocationPolicy: 0,
      telemetryModeEnvironment: telemetry.2, telemetryModeLocation: telemetry.1, telemetryModeBase: telemetry.0,
      manualAddContacts: true, radioFrequency: 869.618, radioBandwidth: 62.5, radioSpreadingFactor: 7,
      radioCodingRate: 6, name: "Test Node"
    )
  }

  @Test
  func `radio parameters show old and new`() {
    var decoder = IsraRadioWriteDecoder()
    decoder.observeIncoming(.selfInfo(selfInfo()))
    let frame = PacketBuilder.setRadio(frequency: 869.525, bandwidth: 250, spreadingFactor: 11, codingRate: 5)
    let decoded = decoder.decodeOutgoing(frame)
    #expect(decoded?.kind == "setRadio")
    #expect(decoded?.change?.contains("869.618 MHz") == true)
    #expect(decoded?.change?.contains("869.525 MHz") == true)
    #expect(decoded?.change?.contains("→") == true)
  }

  @Test
  func `other params with the same values are flagged as a re-send`() {
    var decoder = IsraRadioWriteDecoder()
    decoder.observeIncoming(.selfInfo(selfInfo()))
    let frame = PacketBuilder.setOtherParams(
      manualAddContacts: true, telemetryModeEnvironment: 0, telemetryModeLocation: 1, telemetryModeBase: 2,
      advertisementLocationPolicy: 0, multiAcks: 0
    )
    let decoded = decoder.decodeOutgoing(frame)
    #expect(decoded?.kind == "setOtherParams")
    #expect(decoded?.change == IsraL10n.tr("Isra.Tools.Journal.Value.unchanged"))
  }

  @Test
  func `other params list only what changes`() {
    var decoder = IsraRadioWriteDecoder()
    decoder.observeIncoming(.selfInfo(selfInfo()))
    let frame = PacketBuilder.setOtherParams(
      manualAddContacts: true, telemetryModeEnvironment: 0, telemetryModeLocation: 2, telemetryModeBase: 2,
      advertisementLocationPolicy: 0, multiAcks: 0
    )
    let change = decoder.decodeOutgoing(frame)?.change ?? ""
    #expect(change.contains(IsraL10n.tr("Isra.Tools.Journal.Value.telemetryLoc")))
    #expect(!change.contains(IsraL10n.tr("Isra.Tools.Journal.Value.telemetryBase")))
  }

  @Test
  func `coordinates and keys are never rendered`() {
    var decoder = IsraRadioWriteDecoder()
    let position = decoder.decodeOutgoing(PacketBuilder.setCoordinates(latitude: 48.858370, longitude: 2.294481))
    #expect(position?.change?.contains("38") == false)
    #expect(position?.change?.contains("8.89") == false)
    let key = decoder.decodeOutgoing(PacketBuilder.importPrivateKey(Data(repeating: 0xAB, count: 64)))
    #expect(key?.kind == "privateKey")
    #expect(key?.change?.lowercased().contains("ab") == false)
    let cliLat = decoder.decodeOutgoing(PacketBuilder.runCliCommand("Ab|set lat 48.8583"))
    #expect(cliLat?.change?.contains("38") == false)
    let cliKey = decoder.decodeOutgoing(PacketBuilder.runCliCommand("set prv.key 0011223344"))
    #expect(cliKey?.change?.contains("0011") == false)
    let pin = decoder.decodeOutgoing(PacketBuilder.setDevicePin(123_456))
    #expect(pin?.change?.contains("123456") == false)
  }

  @Test
  func `CLI set takes its old value from an earlier tagged get`() {
    var decoder = IsraRadioWriteDecoder()
    #expect(decoder.decodeOutgoing(PacketBuilder.runCliCommand("0A|get af")) == nil)
    decoder.observeIncoming(.cliReply("0A|> 1.0"))
    let decoded = decoder.decodeOutgoing(PacketBuilder.runCliCommand("0B|set af 9"))
    #expect(decoded?.kind == "cliSet")
    #expect(decoded?.cliTag == "0B|")
    #expect(decoded?.change == "1.0 → 9")
  }

  @Test
  func `reads and per-send scope are not writes`() {
    var decoder = IsraRadioWriteDecoder()
    #expect(decoder.decodeOutgoing(PacketBuilder.getStatsRadio()) == nil)
    #expect(decoder.decodeOutgoing(PacketBuilder.setFloodScopeUnscoped()) == nil)
    #expect(decoder.decodeOutgoing(PacketBuilder.runCliCommand("gps")) == nil)
    #expect(decoder.decodeOutgoing(PacketBuilder.sendAdvertisement(flood: true)) == nil)
  }

  @Test
  func `channel removal is recognised`() {
    var decoder = IsraRadioWriteDecoder()
    decoder.observeIncoming(.channelInfo(ChannelInfo(index: 3, name: "#ping", secret: Data(repeating: 7, count: 16))))
    let decoded = decoder.decodeOutgoing(PacketBuilder.setChannel(index: 3, name: "", secret: Data(count: 16)))
    #expect(decoded?.kind == "channelRemove")
    #expect(decoded?.change?.contains("#ping") == true)
  }
}

@Suite("isra radio-writes journal")
struct IsraRadioWriteJournalTests {
  @Test
  func `a write gets the radio's OK and its trigger`() {
    let journal = IsraRadioWriteJournal(fileURL: nil)
    journal.noteOutgoing(PacketBuilder.setTime(Date()), trigger: IsraWriteTrigger.clockSync)
    #expect(journal.entries.last?.result == .pending)
    journal.noteIncoming(Data([ResponseCode.ok.rawValue]))
    #expect(journal.entries.last?.result == .ok)
    #expect(journal.entries.last?.trigger == IsraWriteTrigger.clockSync)
  }

  @Test
  func `an error reply marks the write rejected`() {
    let journal = IsraRadioWriteJournal(fileURL: nil)
    journal.noteOutgoing(PacketBuilder.setTxPower(30), trigger: nil)
    journal.noteIncoming(Data([ResponseCode.error.rawValue, 6]))
    #expect(journal.entries.last?.result == .error)
  }

  @Test
  func `tagged CLI replies resolve their own write`() {
    let journal = IsraRadioWriteJournal(fileURL: nil)
    journal.noteOutgoing(PacketBuilder.runCliCommand("0C|set tz.offset 0"), trigger: IsraWriteTrigger.timezoneSync)
    journal.noteOutgoing(PacketBuilder.runCliCommand("0D|set dutycycle 10"), trigger: nil)
    journal.noteIncoming(PacketBuilder.cliReplyFrameForTest("0D|Error: bad value"))
    journal.noteIncoming(PacketBuilder.cliReplyFrameForTest("0C|OK"))
    let entries = journal.entries
    #expect(entries.count == 2)
    #expect(entries[0].result == .ok)
    #expect(entries[1].result == .error)
  }

  @Test
  func `a write refused by the link is marked not sent`() {
    let journal = IsraRadioWriteJournal(fileURL: nil)
    let frame = PacketBuilder.setName("X")
    journal.noteOutgoing(frame, trigger: nil)
    journal.noteNotSent(frame)
    #expect(journal.entries.last?.result == .notSent)
  }

  @Test
  func `the ring buffer keeps the newest entries`() {
    let journal = IsraRadioWriteJournal(fileURL: nil)
    for i in 0..<(IsraRadioWriteJournal.capacity + 20) {
      journal.noteOutgoing(PacketBuilder.setName("n\(i)"), trigger: nil)
    }
    let entries = journal.entries
    #expect(entries.count == IsraRadioWriteJournal.capacity)
    #expect(entries.last?.change?.contains("n\(IsraRadioWriteJournal.capacity + 19)") == true)
  }
}

@Suite("isra airtime math")
struct IsraAirtimeMathTests {
  private func sample(_ uptime: UInt32, tx: UInt32, rx: UInt32 = 0) -> IsraAirtimeSample {
    IsraAirtimeSample(date: .now, uptime: uptime, txSeconds: tx, rxSeconds: rx)
  }

  @Test
  func `last hour uses the oldest sample inside the hour`() {
    let samples = (0...90).map { sample(UInt32(1000 + $0 * 60), tx: UInt32($0 * 3)) }
    let window = IsraAirtimeMath.window(samples, maxSpan: 3600)
    #expect(window?.span == 3600)
    #expect(window?.txSeconds == 180)
    #expect(abs((window?.txShare ?? 0) - 0.05) < 0.0001)
  }

  @Test
  func `a reboot drops the older samples`() {
    let samples = [sample(5000, tx: 400), sample(5060, tx: 405), sample(30, tx: 1), sample(400, tx: 20)]
    let boot = IsraAirtimeMath.currentBoot(samples)
    #expect(boot.count == 2)
    #expect(IsraAirtimeMath.window(samples, maxSpan: 3600) == IsraAirtimeWindow(txSeconds: 19, rxSeconds: 0, span: 370))
  }

  @Test
  func `too short a span gives no figure`() {
    #expect(IsraAirtimeMath.window([sample(100, tx: 1), sample(160, tx: 2)], maxSpan: 600) == nil)
    #expect(IsraAirtimeMath.sinceBoot(sample(60, tx: 1)) == nil)
  }

  @Test
  func `since boot comes from one sample`() {
    let window = IsraAirtimeMath.sinceBoot(sample(36000, tx: 360))
    #expect(window?.txShare == 0.01)
    #expect(window?.shareUncertainty == 1.0 / 36000)
  }
}

@Suite("isra config import guard")
struct IsraConfigImportGuardTests {
  private let config = MeshCoreNodeConfig(
    name: "Test Node",
    publicKey: "aa",
    privateKey: String(repeating: "ab", count: 64),
    otherSettings: .init(
      manualAddContacts: 1, advertLocationPolicy: 1, telemetryModeBase: 2, telemetryModeLocation: 2,
      telemetryModeEnvironment: 2, multiAcks: nil
    )
  )

  @Test
  func `sensitive fields are dropped unless opted in`() {
    let filtered = IsraConfigImportGuard.filter(config, .init())
    #expect(filtered.privateKey == nil)
    #expect(filtered.otherSettings?.telemetryModeBase == nil)
    #expect(filtered.otherSettings?.telemetryModeLocation == nil)
    #expect(filtered.otherSettings?.advertLocationPolicy == nil)
    #expect(filtered.otherSettings?.manualAddContacts == 1)
    #expect(filtered.name == "Test Node")
  }

  @Test
  func `opt-ins keep their fields`() {
    let filtered = IsraConfigImportGuard.filter(config, .init(privateKey: true, telemetry: true, advertPolicy: true))
    #expect(filtered == config)
  }

  @Test
  func `other settings that end up empty are dropped`() {
    var onlyTelemetry = config
    onlyTelemetry.otherSettings = .init(telemetryModeBase: 2)
    #expect(IsraConfigImportGuard.filter(onlyTelemetry, .init()).otherSettings == nil)
  }

  @Test
  func `the diff marks excluded and changed fields`() {
    var current = IsraConfigImportGuard.Current()
    current.name = "Test Node"
    current.telemetryBase = 2
    current.telemetryLoc = 1
    let rows = IsraConfigImportGuard.rows(config, current: current, optIns: .init())
    let name = rows.first { $0.id == "name" }
    #expect(name?.changes == false)
    let loc = rows.first { $0.id == "telLoc" }
    #expect(loc?.changes == true)
    #expect(loc?.excluded == true)
    #expect(rows.first { $0.id == "privateKey" }?.excluded == true)
  }

  @Test
  @MainActor
  func `opt-ins never carry over to another file`() {
    let guardModel = IsraConfigImportGuard()
    let first = UUID()
    #expect(guardModel.filtered(config, inputID: first).privateKey == nil)
    guardModel.set(.init(privateKey: true), for: first)
    #expect(guardModel.filtered(config, inputID: first).privateKey != nil)
    #expect(guardModel.filtered(config, inputID: UUID()).privateKey == nil)
  }
}

@Suite("isra effective scope")
struct IsraEffectiveScopeTests {
  @Test
  func `an app region overrides the radio`() {
    let scope = IsraEffectiveScope.resolve(
      channelScope: .region("pt-setubal"), supportsUnscopedFloodSend: true, defaultScopeName: "pt"
    )
    #expect(scope == .appRegion("pt-setubal"))
  }

  @Test
  func `all regions is forced unscoped only where the radio supports it`() {
    #expect(IsraEffectiveScope.resolve(channelScope: .allRegions, supportsUnscopedFloodSend: true, defaultScopeName: nil) == .appUnscoped)
    #expect(IsraEffectiveScope.resolve(channelScope: .allRegions, supportsUnscopedFloodSend: false, defaultScopeName: "pt") == .radio(defaultName: "pt"))
  }

  @Test
  func `inherit leaves it to the radio`() {
    #expect(IsraEffectiveScope.resolve(channelScope: .inherit, supportsUnscopedFloodSend: true, defaultScopeName: "") == .radio(defaultName: nil))
  }
}

@Suite("isra DM budget")
struct IsraDMBudgetTests {
  @Test
  func `upstream default is eight sends`() {
    let cost = IsraDMBudget.worstCase(DMSendBudget(directAttempts: 4, floodAttempts: 4))
    #expect(cost.total == 8)
    #expect(IsraDMBudget.worstCase(DMSendBudget(directAttempts: 1, floodAttempts: 0)).total == 1)
  }
}

private extension PacketBuilder {
  static func cliReplyFrameForTest(_ text: String) -> Data {
    Data([ResponseCode.cliReply.rawValue]) + Data(text.utf8)
  }
}

@Suite("isra upstream import tests opt-in")
@MainActor
struct IsraUpstreamImportOptInTests {
  @Test
  func `only the shared guard honours the test bundle marker`() {
    #expect(IsraConfigImportGuard.upstreamTestsOptIn)
    #expect(IsraConfigImportGuard.shared.optIns(for: UUID()) == .all)
    #expect(IsraConfigImportGuard().optIns(for: UUID()) == .init())
  }
}
