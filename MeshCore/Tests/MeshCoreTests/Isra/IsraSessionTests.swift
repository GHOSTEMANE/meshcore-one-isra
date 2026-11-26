import Foundation
@testable import MeshCore
import Testing

/// Keys the test provider answers for.
private let helloKey = Data(repeating: 0xAB, count: 32)
private let stockKey = Data(repeating: 0xAC, count: 32)

/// Runs `body` with the host-caps provider scoped to this test's task tree: nothing
/// process-wide is installed, so other suites keep the stock `sendAppStart` path.
private func withTestProvider(_ body: () async throws -> Void) async throws {
  try await IsraHooks.withScopedProvider({ key in
    key == helloKey || key == stockKey ? [.sentMessages, .phonePosition] : nil
  }, operation: body)
}

@Suite("isra session")
struct IsraSessionTests {
  @Test
  func `hello follows app start and stores the firmware reply`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      #expect(await transport.sentData[1] == IsraProtocol.hello(hostCaps: [.sentMessages, .phonePosition]))
      await transport.simulateReceive(Data([0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x03]))
      try await startTask.value

      let hello = await session.israHello
      #expect(hello == .supported(
        IsraProtocol.HelloReply(caps: .sentMessages, revision: 2, state: [.phonePositionSetting, .gpsOn]),
        hostCaps: [.sentMessages, .phonePosition]
      ))
      #expect(hello.activeCaps == .sentMessages)
      #expect(await session.israSentMessagesActive)

      // A later APP_START (settings refresh) does not repeat HELLO: BLE keeps the caps.
      let refresh = Task { try await session.sendAppStart() }
      try await waitUntil("second appStart") { await transport.sentData.count == 3 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      _ = try await refresh.value
      #expect(await transport.sentData.count == 3)

      // On demand it is sent again.
      let resend = Task { try await session.israResendHello() }
      try await waitUntil("resent hello") { await transport.sentData.count == 4 }
      await transport.simulateReceive(Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x07]))
      #expect(try await resend.value.activeCaps == [.sentMessages, .phonePosition])
      await session.stop()
    }
  }

  @Test
  func `stock firmware answers unsupported and hello is not repeated`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: stockKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      await transport.simulateReceive(Data([ResponseCode.error.rawValue, ErrorCode.unsupportedCommand.rawValue]))
      try await startTask.value
      #expect(await session.israHello == .unsupported)
      #expect(!(await session.israSentMessagesActive))

      let state = try await session.israResendHello()
      #expect(state == .unsupported)
      #expect(await transport.sentData.count == 2)
      await session.stop()
    }
  }

  @Test
  func `revision 1 firmware is asked again without SENT_MSGS`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      await transport.simulateReceive(Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00]))
      try await waitUntil("second hello") { await transport.sentData.count == 3 }
      #expect(await transport.sentData[2] == IsraProtocol.hello(hostCaps: .phonePosition))
      await transport.simulateReceive(Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00]))
      try await startTask.value
      #expect(await session.israHello.activeCaps == .phonePosition)
      #expect(!(await session.israSentMessagesActive))
      await session.stop()
    }
  }

  @Test
  func `off BLE hello follows every app start`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      await session.israSetLinkKeepsCaps(false)
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      await transport.simulateReceive(Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x07]))
      try await startTask.value

      let refresh = Task { try await session.sendAppStart() }
      try await waitUntil("second appStart") { await transport.sentData.count == 3 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello again") { await transport.sentData.count == 4 }
      #expect(await transport.sentData[3] == IsraProtocol.hello(hostCaps: [.sentMessages, .phonePosition]))
      await transport.simulateReceive(Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x07]))
      _ = try await refresh.value
      #expect(await session.israHello.activeCaps == [.sentMessages, .phonePosition])
      await session.stop()
    }
  }

  @Test
  func `two unanswered hellos give up for the session`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 0.3, clientIdentifier: "MCTst")
      )
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      try await startTask.value
      #expect(await session.israHello == .failed)

      let second = Task { try await session.sendAppStart() }
      try await waitUntil("second appStart") { await transport.sentData.count == 3 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("second hello") { await transport.sentData.count == 4 }
      _ = try await second.value
      #expect(await session.israHello == .gaveUp)

      let third = Task { try await session.sendAppStart() }
      try await waitUntil("third appStart") { await transport.sentData.count == 5 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      _ = try await third.value
      #expect(try await session.israResendHello() == .gaveUp)
      #expect(await transport.sentData.count == 5)
      await session.stop()
    }
  }

  @Test
  func `an invalidated hello is sent with the next app start`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      await transport.simulateReceive(Data([0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]))
      try await startTask.value

      await session.israInvalidateHello()
      #expect(await session.israHello == .failed)
      // SENT_MSGS stays negotiated: on BLE the firmware keeps the cap.
      #expect(await session.israSentMessagesActive)

      let refresh = Task { try await session.sendAppStart() }
      try await waitUntil("second appStart") { await transport.sentData.count == 3 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello again") { await transport.sentData.count == 4 }
      await transport.simulateReceive(Data([0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]))
      _ = try await refresh.value
      #expect(await session.israHello.activeCaps == .sentMessages)
      await session.stop()
    }
  }

  @Test
  func `session records hello byte 8 and STATE pushes in arrival order`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      #expect(await session.israLiveState == IsraProtocol.LiveState())
      let startTask = Task { try await session.start() }
      try await waitUntil("appStart") { await transport.sentData.count == 1 }
      await transport.simulateReceive(makeSelfInfoPacket(key: helloKey))
      try await waitUntil("hello") { await transport.sentData.count == 2 }
      await transport.simulateReceive(Data([0xE1, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x07, 0x00]))
      try await startTask.value
      #expect(await session.israLiveState == .init(flags: [.phonePositionSetting, .gpsOn, .gpsDutyCycle], advertPolicy: 0))
      if case let .supported(reply, _) = await session.israHello {
        #expect(reply.advertPolicy == 0)
      } else {
        Issue.record("expected a supported hello")
      }

      // The policy and GPS changed on the device.
      await transport.simulateReceive(Data([0xE1, 0x11, 0x01, 0x02]))
      try await waitUntil("state push") { await session.israLiveState.advertPolicy == 2 }
      #expect(await session.israLiveState.flags == .phonePositionSetting)
      await session.stop()
    }
  }

  @Test
  func `without the hooks a STATE push changes nothing`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport, key: Data(repeating: 0x05, count: 32))
    await transport.simulateReceive(Data([0xE1, 0x11, 0x07, 0x02]))
    // A later frame, so the push above has been handled.
    let ping = Task { try await session.sendAppStart() }
    try await waitUntil("appStart") { await transport.sentData.count == 2 }
    await transport.simulateReceive(makeSelfInfoPacket(key: Data(repeating: 0x05, count: 32)))
    _ = try await ping.value
    #expect(await session.israLiveState == IsraProtocol.LiveState())
    #expect(await transport.sentData.count == 2)
    await session.stop()
  }

  @Test
  func `other devices get no hello`() async throws {
    try await withTestProvider {
      let transport = MockTransport()
      let session = MeshCoreSession(
        transport: transport,
        configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
      )
      try await startSession(session, transport: transport, key: Data(repeating: 0x03, count: 32))
      #expect(await transport.sentData.count == 1)
      #expect(await session.israHello == .notSent)
      await session.stop()
    }
  }

  @Test
  func `phone position errors map to outcomes`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport, key: Data(repeating: 0x04, count: 32))
    let frame = try #require(IsraProtocol.phonePosition(
      latitude: 38.5, longitude: -8.9, altitudeMeters: nil, horizontalAccuracy: 20, ageSeconds: 1
    ))
    for (reply, expected): (Data, IsraProtocol.PhonePositionOutcome) in [
      (Data([ResponseCode.ok.rawValue]), .accepted),
      (Data([ResponseCode.error.rawValue, ErrorCode.badState.rawValue]), .badState),
      (Data([ResponseCode.error.rawValue, ErrorCode.illegalArgument.rawValue]), .illegalArgument)
    ] {
      let before = await transport.sentData.count
      let task = Task { try await session.israSendPhonePosition(frame) }
      try await waitUntil("phone pos sent") { await transport.sentData.count == before + 1 }
      await transport.simulateReceive(reply)
      #expect(try await task.value == expected)
    }
    await session.stop()
  }
}

private func startSession(_ session: MeshCoreSession, transport: MockTransport, key: Data) async throws {
  let startTask = Task { try await session.start() }
  try await waitUntil("appStart") { await transport.sentData.count == 1 }
  await transport.simulateReceive(makeSelfInfoPacket(key: key))
  try await startTask.value
}

private func makeSelfInfoPacket(key: Data) -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1) // adv type
  payload.append(UInt8(bitPattern: 22)) // tx power
  payload.append(UInt8(bitPattern: 22)) // max tx power
  payload.append(key)
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
  payload.append(0) // multi acks
  payload.append(0) // adv loc policy
  payload.append(0) // telemetry mode
  payload.append(0) // manual add
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) }) // freq
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) }) // bw
  payload.append(11) // sf
  payload.append(5) // cr
  return payload
}
