import Foundation
@testable import MC1Services
import MeshCore
import Testing

/// SENT_DM / SENT_CHANNEL / SENT_STATUS from an isra firmware (isra/PROTOCOL.md rev 2, section 3).
@Suite("isra device-sent messages")
@MainActor
struct IsraSentMessageServiceTests {
  private let selfKey = Data(repeating: 0x5A, count: 32)
  private let contactKey = Data([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6]) + Data(repeating: 0x77, count: 26)

  private struct Fixture {
    let transport: MockTransport
    let container: ServiceContainer
    let service: IsraSentMessageService
    let radioID: UUID
    let contactID: UUID
  }

  private func makeFixture(negotiated: Bool = true) async throws -> Fixture {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 30, clientIdentifier: "MCTst")
    )
    let start = Task { try await session.start() }
    try await poll("appStart") { await transport.sentData.count == 1 }
    await transport.simulateReceive(selfInfoPacket(key: selfKey))
    try await start.value

    let radioID = UUID()
    let container = try await ServiceContainer.forTesting(session: session, radioID: radioID)
    try await container.dataStore.saveDevice(DeviceDTO.testDevice(id: radioID, radioID: radioID, publicKey: selfKey))
    let contact = ContactDTO.testContact(radioID: radioID, publicKey: contactKey, name: "Peer Node")
    try await container.dataStore.saveContact(contact)
    let service = IsraSentMessageService(
      session: session,
      dataStore: container.dataStore,
      messageService: container.messageService,
      syncCoordinator: container.syncCoordinator,
      rxLogService: container.rxLogService,
      heardRepeatsService: container.heardRepeatsService,
      receiveLifetime: container.receiveLifetime,
      radioID: radioID,
      isNegotiated: { negotiated }
    )
    await service.start()
    return Fixture(transport: transport, container: container, service: service, radioID: radioID, contactID: contact.id)
  }

  private func sentDM(text: String, timestamp: UInt32, status: UInt8 = 0, attempt: UInt8 = 0) -> Data {
    var data = Data([0xE1, 0x20, status, attempt, 0])
    data.append(contactKey.prefix(6))
    data.append(0xFF)
    data.append(0)
    data.append(le32(timestamp))
    data.append(Data(text.utf8))
    return data
  }

  @Test
  func `SENT_DM is stored as an outgoing DM and a live ACK delivers it`() async throws {
    let fixture = try await makeFixture()
    let store = fixture.container.dataStore
    let timestamp = UInt32(Date().timeIntervalSince1970) - 5
    let heardBefore = try await store.fetchContact(id: fixture.contactID)?.lastHeardTimestamp

    await fixture.transport.simulateReceive(sentDM(text: "OK", timestamp: timestamp))
    try await poll("stored") {
      await ((try? store.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0))?.count ?? 0) == 1
    }
    let stored = try #require(try await store.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0).first)
    #expect(stored.direction == .outgoing)
    #expect(stored.status == .sent)
    #expect(stored.isRead)
    #expect(stored.text == "OK")
    #expect(stored.timestamp == timestamp)
    let contact = try #require(try await store.fetchContact(id: fixture.contactID))
    #expect(contact.unreadCount == 0)
    #expect(contact.lastHeardTimestamp == heardBefore)

    // Same frame again (re-queued after a lost link): no duplicate.
    await fixture.transport.simulateReceive(sentDM(text: "OK", timestamp: timestamp))

    // Live 0x82 for the radio's second attempt.
    let code = AckCodeBuilder.expectedAck(timestamp: timestamp, attempt: 1, text: "OK", senderPublicKey: selfKey)
    await fixture.transport.simulateReceive(Data([0x82]) + code + le32(1234))
    try await poll("delivered") {
      await (try? store.fetchMessage(id: stored.id))?.status == .delivered
    }
    let delivered = try #require(try await store.fetchMessage(id: stored.id))
    #expect(delivered.roundTripTime == 1234)
    #expect(try await store.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0).count == 1)
    await fixture.service.stop()
  }

  @Test
  func `SENT_STATUS marks retrying then failed`() async throws {
    let fixture = try await makeFixture()
    let store = fixture.container.dataStore
    let timestamp = UInt32(Date().timeIntervalSince1970) - 30
    await fixture.transport.simulateReceive(sentDM(text: "olá", timestamp: timestamp))
    try await poll("stored") {
      await ((try? store.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0))?.count ?? 0) == 1
    }
    let id = try #require(try await store.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0).first?.id)

    func sentStatus(status: UInt8, attempt: UInt8) -> Data {
      Data([0xE1, 0x22]) + contactKey.prefix(6) + le32(timestamp) + Data([status, attempt]) + le32(0)
    }
    await fixture.transport.simulateReceive(sentStatus(status: 2, attempt: 2))
    try await poll("retrying") { await (try? store.fetchMessage(id: id))?.status == .retrying }
    #expect(try await store.fetchMessage(id: id)?.retryAttempt == 2)
    await fixture.transport.simulateReceive(sentStatus(status: 3, attempt: 3))
    try await poll("failed") { await (try? store.fetchMessage(id: id))?.status == .failed }
    await fixture.service.stop()
  }

  @Test
  func `SENT_CHANNEL is stored as an outgoing channel post`() async throws {
    let fixture = try await makeFixture()
    let store = fixture.container.dataStore
    let timestamp = UInt32(Date().timeIntervalSince1970) - 2
    let raw = Data([0xE1, 0x21, 0, 0, 0, 1, 0xFF, 0]) + le32(timestamp) + Data("bom dia".utf8)
    await fixture.transport.simulateReceive(raw)
    try await poll("stored") {
      await (try? store.findSentChannelMessage(
        radioID: fixture.radioID, channelIndex: 1, timestamp: timestamp, text: "bom dia"
      )) != nil
    }
    await fixture.transport.simulateReceive(raw)
    try await Task.sleep(for: .milliseconds(200))
    let all = try await store.fetchMessages(radioID: fixture.radioID, channelIndex: 1, limit: 10, offset: 0)
    #expect(all.count == 1)
    #expect(all.first?.direction == .outgoing)
    #expect(all.first?.isRead == true)
    await fixture.service.stop()
  }

  @Test
  func `a status for an unknown message is ignored`() async throws {
    let fixture = try await makeFixture()
    let raw = Data([0xE1, 0x22]) + contactKey.prefix(6) + le32(42) + Data([1, 0]) + le32(10)
    await fixture.transport.simulateReceive(raw)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await fixture.container.dataStore.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0).isEmpty)
    await fixture.service.stop()
  }

  @Test
  func `frames are ignored unless HELLO negotiated SENT_MSGS`() async throws {
    let fixture = try await makeFixture(negotiated: false)
    let timestamp = UInt32(Date().timeIntervalSince1970) - 5
    await fixture.transport.simulateReceive(sentDM(text: "OK", timestamp: timestamp))
    await fixture.transport.simulateReceive(
      Data([0xE1, 0x21, 0, 0, 0, 1, 0xFF, 0]) + le32(timestamp) + Data("bom dia".utf8)
    )
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await fixture.container.dataStore.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0).isEmpty)
    #expect(try await fixture.container.dataStore.fetchMessages(
      radioID: fixture.radioID, channelIndex: 1, limit: 10, offset: 0
    ).isEmpty)
    await fixture.service.stop()
  }

  @Test
  func `raw frame 30 of revision 1 is not read`() async throws {
    let fixture = try await makeFixture()
    var raw = Data([30, 0, 0, 0]) + contactKey.prefix(6) + Data([0xFF, 0])
    raw.append(le32(UInt32(Date().timeIntervalSince1970) - 5))
    raw.append(Data("OK".utf8))
    await fixture.transport.simulateReceive(raw)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await fixture.container.dataStore.fetchMessages(contactID: fixture.contactID, limit: 10, offset: 0).isEmpty)
    await fixture.service.stop()
  }

  @Test
  func `sort date falls back to arrival when the radio clock is implausible`() {
    let now = Date()
    #expect(IsraSentMessageService.sortDate(timestamp: 1000, arrival: now) == now)
    let recent = UInt32(now.timeIntervalSince1970) - 60
    #expect(IsraSentMessageService.sortDate(timestamp: recent, arrival: now)
      == Date(timeIntervalSince1970: TimeInterval(recent)))
  }
}

private func le32(_ value: UInt32) -> Data {
  withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func poll(
  _ what: String,
  timeout: Duration = .seconds(30),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  struct Timeout: Error { let what: String }
  throw Timeout(what: what)
}

private func selfInfoPacket(key: Data) -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1)
  payload.append(UInt8(bitPattern: 22))
  payload.append(UInt8(bitPattern: 22))
  payload.append(key)
  payload.append(le32(0))
  payload.append(le32(0))
  payload.append(contentsOf: [0, 0, 0, 0])
  payload.append(le32(869_618))
  payload.append(le32(62_500))
  payload.append(7)
  payload.append(6)
  return payload
}
