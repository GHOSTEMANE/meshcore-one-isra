import Foundation
@testable import MeshCore
import Testing

@Suite("isra protocol (PROTOCOL.md rev 2)")
struct IsraProtocolTests {
  @Test
  func `hello carries host caps little-endian`() {
    let data = IsraProtocol.hello(hostCaps: [.sentMessages, .phonePosition])
    #expect(data == Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00]))
  }

  @Test
  func `hello reply parses caps revision and state`() {
    let raw = Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x07])
    let event = PacketParser.parse(raw)
    guard case let .helloReply(reply)? = IsraProtocol.frame(from: event) else {
      Issue.record("expected hello reply, got \(event)")
      return
    }
    #expect(reply.caps == [.sentMessages, .phonePosition])
    #expect(reply.revision == 2)
    #expect(reply.state == [.phonePositionSetting, .gpsOn, .gpsDutyCycle])
  }

  @Test
  func `position request push parses`() {
    #expect(IsraProtocol.frame(from: PacketParser.parse(Data([0xE1, 0x10]))) == .positionRequest)
  }

  @Test
  func `unknown sub-op is reported, not dropped`() {
    #expect(IsraProtocol.parse(Data([0xE1, 0x55])) == .unknown(subOp: 0x55))
  }

  @Test
  func `phone position layout`() throws {
    let data = try #require(IsraProtocol.phonePosition(
      latitude: 48.858_123, longitude: 2.294_456,
      altitudeMeters: 12.345, horizontalAccuracy: 65.2, ageSeconds: 7
    ))
    #expect(data.count == 19)
    #expect(data[0] == 0xE1)
    #expect(data[1] == 0x01)
    #expect(data.readInt32LE(at: 2) == 48_858_123)
    #expect(data.readInt32LE(at: 6) == 2_294_456)
    #expect(data.readInt32LE(at: 10) == 12_345)
    #expect(data[14] == 0x01)
    #expect(data.readUInt16LE(at: 15) == 66)
    #expect(data.readUInt16LE(at: 17) == 7)
  }

  @Test
  func `phone position without altitude or accuracy`() throws {
    let data = try #require(IsraProtocol.phonePosition(
      latitude: 1, longitude: 2, altitudeMeters: nil, horizontalAccuracy: nil, ageSeconds: 100_000
    ))
    #expect(data.readInt32LE(at: 10) == 0)
    #expect(data[14] == 0x00)
    #expect(data.readUInt16LE(at: 15) == 0xFFFF)
    #expect(data.readUInt16LE(at: 17) == 0xFFFF)
  }

  @Test
  func `phone position rejects null island and out of range`() {
    #expect(IsraProtocol.phonePosition(latitude: 0, longitude: 0, altitudeMeters: nil, horizontalAccuracy: 5, ageSeconds: 0) == nil)
    #expect(IsraProtocol.phonePosition(latitude: 91, longitude: 0, altitudeMeters: nil, horizontalAccuracy: 5, ageSeconds: 0) == nil)
    #expect(IsraProtocol.phonePosition(latitude: .nan, longitude: 0, altitudeMeters: nil, horizontalAccuracy: 5, ageSeconds: 0) == nil)
  }

  @Test
  func `SENT_DM parses status attempt prefix timestamp and text`() {
    var raw = Data([0xE1, 0x20, 2, 1, 0])
    raw.append(Data([0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]))
    raw.append(0xFF) // path_len
    raw.append(0x00) // txt_type
    raw.append(Data([0x78, 0x56, 0x34, 0x12]))
    raw.append(Data("olá".utf8))
    guard case let .sentContactMessage(msg)? = IsraProtocol.frame(from: PacketParser.parse(raw)) else {
      Issue.record("expected SENT_DM")
      return
    }
    #expect(msg.status == .retrying)
    #expect(msg.attempt == 1)
    #expect(msg.recipientPrefix == Data([0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]))
    #expect(msg.pathLength == 0xFF)
    #expect(msg.timestamp == 0x1234_5678)
    #expect(msg.text == "olá")
  }

  @Test
  func `SENT_CHANNEL parses channel body`() {
    var raw = Data([0xE1, 0x21, 0, 0, 0, 3, 0xFF, 0x00])
    raw.append(Data([0x01, 0x00, 0x00, 0x00]))
    raw.append(Data("bom dia".utf8))
    #expect(IsraProtocol.parse(raw) == .sentChannelMessage(.init(
      channelIndex: 3, pathLength: 0xFF, textType: 0, timestamp: 1, text: "bom dia"
    )))
  }

  @Test
  func `SENT_STATUS parses status`() {
    var raw = Data([0xE1, 0x22])
    raw.append(Data([1, 2, 3, 4, 5, 6]))
    raw.append(Data([0x10, 0, 0, 0]))
    raw.append(contentsOf: [1, 3])
    raw.append(Data([0xE8, 0x03, 0, 0]))
    #expect(IsraProtocol.parse(raw) == .sentMessageStatus(.init(
      recipientPrefix: Data([1, 2, 3, 4, 5, 6]), timestamp: 16, status: .delivered, attempt: 3, roundTripMs: 1000
    )))
  }

  @Test
  func `raw frames 30 31 32 of revision 1 are no longer isra frames`() {
    var frame30 = Data([30, 0, 0, 0, 1, 2, 3, 4, 5, 6, 0xFF, 0, 1, 0, 0, 0])
    frame30.append(Data("hi".utf8))
    #expect(IsraProtocol.parse(frame30) == nil)
    #expect(IsraProtocol.parse(Data([31, 0, 0, 0, 1, 0xFF, 0, 1, 0, 0, 0])) == nil)
    #expect(IsraProtocol.parse(Data([32, 1, 2, 3, 4, 5, 6, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0])) == nil)
  }

  @Test
  func `short or foreign frames are not isra frames`() {
    #expect(IsraProtocol.parse(Data([0xE1, 0x20, 0, 0])) == nil)
    #expect(IsraProtocol.parse(Data([0xE1, 0x22, 1, 2])) == nil)
    #expect(IsraProtocol.parse(Data([0xE1])) == nil)
    #expect(IsraProtocol.parse(Data([0x07, 0, 0])) == nil)
  }

  @Test
  func `revision 1 firmware never activates SENT_MSGS`() {
    let rev1 = IsraHelloState.supported(
      .init(caps: [.sentMessages, .phonePosition], revision: 1, state: []), hostCaps: [.sentMessages, .phonePosition]
    )
    #expect(rev1.activeCaps == .phonePosition)
    let rev3 = IsraHelloState.supported(
      .init(caps: [.sentMessages], revision: 3, state: []), hostCaps: [.sentMessages, .phonePosition]
    )
    #expect(rev3.activeCaps == .sentMessages)
  }

  @Test
  func `malformed known frame is not taken for an unknown one`() {
    // A truncated contact message (0x10) reports its payload; its first byte 0x1E must not
    // be read as frame 30.
    let event = PacketParser.parse(Data([0x10, 0x1E]))
    #expect(IsraProtocol.frame(from: event) == nil)
    if case let .parseFailure(data, reason) = event {
      #expect(!IsraProtocol.isUnknownReplyFrame(data: data, reason: reason))
    }
  }

  @Test
  func `unknown reply versus push`() {
    if case let .parseFailure(data, reason) = PacketParser.parse(Data([30, 0, 0, 0])) {
      #expect(IsraProtocol.isUnknownReplyFrame(data: data, reason: reason))
      #expect(IsraProtocol.isDrainSkipFrame(data: data, reason: reason))
    } else {
      Issue.record("code 30 should be a parse failure for the stock parser")
    }
    if case let .parseFailure(data, reason) = PacketParser.parse(Data([0xE1, 0x10])) {
      #expect(!IsraProtocol.isUnknownReplyFrame(data: data, reason: reason))
      #expect(!IsraProtocol.isDrainSkipFrame(data: data, reason: reason))
      #expect(IsraProtocol.isUnknownCodeFrame(data: data, reason: reason))
    } else {
      Issue.record("0xE1 should be a parse failure for the stock parser")
    }
    if case let .parseFailure(data, reason) = PacketParser.parse(Data([0xE1, 0x21, 0, 0, 0, 1, 0xFF, 0, 1, 0, 0, 0])) {
      #expect(IsraProtocol.isDrainSkipFrame(data: data, reason: reason))
    } else {
      Issue.record("0xE1 / 0x21 should be a parse failure for the stock parser")
    }
  }
}
