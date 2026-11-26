import Foundation
@testable import MeshCore
import Testing

/// Keys the test provider answers for. Every other device (all other suites) gets nil,
/// so installing the process-wide provider leaves their exchanges unchanged.
private let helloKey = Data(repeating: 0xAB, count: 32)
private let stockKey = Data(repeating: 0xAC, count: 32)

private func installTestProvider() {
  IsraHooks.setHostCapsProvider { key in
    key == helloKey || key == stockKey ? [.sentMessages, .phonePosition] : nil
  }
}

@Suite("isra session")
struct IsraSessionTests {
  @Test
  func `hello follows app start and stores the firmware reply`() async throws {
    installTestProvider()
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
    await transport.simulateReceive(Data([0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x03]))
    try await startTask.value

    let hello = await session.israHello
    #expect(hello == .supported(
      IsraProtocol.HelloReply(caps: .sentMessages, revision: 1, state: [.phonePositionSetting, .gpsOn]),
      hostCaps: [.sentMessages, .phonePosition]
    ))
    #expect(hello.activeCaps == .sentMessages)
    await session.stop()
  }

  @Test
  func `stock firmware answers unsupported and hello is not repeated`() async throws {
    installTestProvider()
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

    let state = try await session.israResendHello()
    #expect(state == .unsupported)
    #expect(await transport.sentData.count == 2)
    await session.stop()
  }

  @Test
  func `other devices get no hello`() async throws {
    installTestProvider()
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
