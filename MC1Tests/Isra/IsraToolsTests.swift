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

private extension PacketBuilder {
  static func cliReplyFrameForTest(_ text: String) -> Data {
    Data([ResponseCode.cliReply.rawValue]) + Data(text.utf8)
  }
}
