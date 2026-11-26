import Foundation
import MC1Services
import MeshCore
import Observation

/// App-side state of the isra protocol extensions (`isra/PROTOCOL.md`) for the current
/// connection: what the firmware said in HELLO, and the 0xE1 pushes it sends.
///
/// With stock firmware HELLO is answered `ERR_CODE_UNSUPPORTED_CMD`, `hello` becomes
/// `.unsupported` and nothing here does anything else.
@MainActor
@Observable
final class IsraCenter {
  static let shared = IsraCenter()

  /// Outcome of the last HELLO on the current connection.
  private(set) var hello: IsraHelloState = .notSent
  /// Public key of the connected device, nil while disconnected.
  private(set) var devicePublicKey: Data?

  /// Phone position for telemetry (section 2).
  let phonePos = IsraPhonePosService()

  @ObservationIgnored private(set) var session: MeshCoreSession?
  @ObservationIgnored private var eventsTask: Task<Void, Never>?
  @ObservationIgnored private var eventsSubscription: UUID?

  private init() {}

  /// Installs the host-caps provider so every APP_START is followed by HELLO.
  /// Call before the connection manager starts connecting.
  nonisolated static func installHooks() {
    IsraHooks.setHostCapsProvider { key in
      IsraSettings.hostCaps(devicePublicKey: key)
    }
  }

  var firmwareReply: IsraProtocol.HelloReply? {
    if case let .supported(reply, _) = hello { return reply }
    return nil
  }

  /// Caps in effect: host & firmware.
  var activeCaps: IsraProtocol.Caps {
    hello.activeCaps
  }

  var isConnected: Bool {
    session != nil
  }

  // MARK: - Connection lifecycle

  /// Called when the app has wired a new connection.
  func connectionReady(_ snapshot: ConnectionSnapshot) async {
    let session = snapshot.services.session
    guard self.session !== session else { return }
    stopListening()
    self.session = session
    devicePublicKey = snapshot.device.publicKey
    hello = await session.israHello
    guard self.session === session else { return }
    await startListening(to: session)
    guard self.session === session else { return }
    updatePhonePosBinding(sendNow: true)
  }

  /// Called on connection loss and explicit disconnect.
  func connectionLost() {
    phonePos.unbind()
    stopListening()
    session = nil
    devicePublicKey = nil
    hello = .notSent
  }

  /// Sends HELLO again (new host caps, or to refresh the device state flags).
  func resendHello() async {
    guard let session else { return }
    do {
      let state = try await session.israResendHello()
      guard self.session === session else { return }
      hello = state
      updatePhonePosBinding(sendNow: false)
    } catch {
      // Cancellation or a dropped link: the next connection sends HELLO anyway.
    }
  }

  // MARK: - Phone position

  /// Turns the feature on or off for a device, and tells a connected radio at once.
  func setPhonePositionEnabled(_ enabled: Bool, devicePublicKey key: Data) async {
    IsraSettings.setPhonePositionEnabled(enabled, devicePublicKey: key)
    guard devicePublicKey == key, session != nil else { return }
    await resendHello()
    if enabled { phonePos.handlePositionRequest() }
  }

  /// Answers position requests only while the link has the PHONE_POS cap.
  private func updatePhonePosBinding(sendNow: Bool) {
    guard let session, activeCaps.contains(.phonePosition) else {
      phonePos.unbind()
      return
    }
    if phonePos.isBound, !sendNow { return }
    phonePos.bind(sender: { frame in
      try await session.israSendPhonePosition(frame)
    }, sendNow: sendNow)
  }

  // MARK: - 0xE1 frames

  private func startListening(to session: MeshCoreSession) async {
    let filter = EventFilter { event in
      switch IsraProtocol.frame(from: event) {
      case .helloReply?, .positionRequest?: true
      default: false
      }
    }
    let (id, stream) = await session.eventsTracked(filter: filter)
    guard self.session === session else {
      await session.finishEvents(id: id)
      return
    }
    eventsSubscription = id
    eventsTask = Task { [weak self] in
      for await event in stream {
        guard let frame = IsraProtocol.frame(from: event) else { continue }
        await self?.handle(frame, from: session)
      }
    }
  }

  private func stopListening() {
    eventsTask?.cancel()
    eventsTask = nil
    if let id = eventsSubscription, let session {
      Task { await session.finishEvents(id: id) }
    }
    eventsSubscription = nil
  }

  private func handle(_ frame: IsraProtocol.Frame, from session: MeshCoreSession) async {
    guard self.session === session else { return }
    switch frame {
    case let .helloReply(reply):
      // A HELLO the session sent after a mid-session APP_START (settings changes).
      let hostCaps = devicePublicKey.map { IsraSettings.hostCaps(devicePublicKey: $0) } ?? []
      hello = .supported(reply, hostCaps: hostCaps)
      updatePhonePosBinding(sendNow: false)
    case .positionRequest:
      phonePos.handlePositionRequest()
    case .sentContactMessage, .sentChannelMessage, .sentMessageStatus, .unknown:
      break
    }
  }
}
