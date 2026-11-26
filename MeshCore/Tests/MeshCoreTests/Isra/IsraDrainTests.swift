import Foundation
@testable import MeshCore
import Testing

@Suite("isra drain robustness")
struct IsraDrainTests {
  @Test
  func `drain skips an unknown reply frame and fetches the next message`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await drainStartSession(session, transport: transport, key: Data(repeating: 0x01, count: 32))
    let base = await transport.sentData.count

    let task = Task { try await session.getMessage() }
    try await waitUntil("first SYNC") { await transport.sentData.count == base + 1 }

    var frame30 = Data([30, 0, 0, 0, 1, 2, 3, 4, 5, 6, 0xFF, 0, 1, 0, 0, 0])
    frame30.append(Data("hi".utf8))
    await transport.simulateReceive(frame30)

    try await waitUntil("second SYNC after the unknown frame") { await transport.sentData.count == base + 2 }
    #expect(await transport.sentData.last == PacketBuilder.getMessage())
    await transport.simulateReceive(Data([ResponseCode.noMoreMessages.rawValue]))

    let result = try await task.value
    guard case .noMoreMessages = result else {
      Issue.record("expected noMoreMessages, got \(result)")
      await session.stop()
      return
    }
    await session.stop()
  }

  @Test
  func `unknown push during drain is ignored, not taken as the reply`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await drainStartSession(session, transport: transport, key: Data(repeating: 0x02, count: 32))
    let base = await transport.sentData.count

    let task = Task { try await session.getMessage() }
    try await waitUntil("SYNC") { await transport.sentData.count == base + 1 }
    await transport.simulateReceive(Data([0xE1, 0x10]))
    await transport.simulateReceive(Data([ResponseCode.noMoreMessages.rawValue]))
    let result = try await task.value
    guard case .noMoreMessages = result else {
      Issue.record("expected noMoreMessages, got \(result)")
      await session.stop()
      return
    }
    #expect(await transport.sentData.count == base + 1)
    await session.stop()
  }

}

private func drainStartSession(_ session: MeshCoreSession, transport: MockTransport, key: Data) async throws {
  let startTask = Task { try await session.start() }
  try await waitUntil("appStart") { await transport.sentData.count == 1 }
  await transport.simulateReceive(drainSelfInfoPacket(key: key))
  try await startTask.value
}

private func drainSelfInfoPacket(key: Data) -> Data {
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
