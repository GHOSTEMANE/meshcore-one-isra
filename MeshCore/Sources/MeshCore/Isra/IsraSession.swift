import Foundation
import Synchronization

/// App-installed switches for the isra protocol extensions.
///
/// The package cannot see the app's `ISRA` compilation condition, so every isra
/// behaviour in it is off until the app installs a host-caps provider. With no
/// provider (upstream app, tests) the session never sends HELLO.
public enum IsraHooks {
  public typealias HostCapsProvider = @Sendable (_ devicePublicKey: Data) -> IsraProtocol.Caps?

  private static let provider = Mutex<HostCapsProvider?>(nil)

  /// Installs (or removes, with nil) the provider of host caps for a device.
  /// Returning nil for a device skips HELLO on that connection.
  public static func setHostCapsProvider(_ newValue: HostCapsProvider?) {
    provider.withLock { $0 = newValue }
  }

  /// True once the app installed a provider.
  public static var isInstalled: Bool {
    provider.withLock { $0 != nil }
  }

  static func hostCaps(for devicePublicKey: Data) -> IsraProtocol.Caps? {
    let current = provider.withLock { $0 }
    return current?(devicePublicKey)
  }
}

/// Outcome of the last HELLO on a session.
public enum IsraHelloState: Sendable, Equatable {
  /// Not sent: no provider installed, or no caps for this device.
  case notSent
  /// Stock firmware (`ERR_CODE_UNSUPPORTED_CMD`): every isra feature stays off.
  case unsupported
  /// Another error or no reply.
  case failed
  case supported(IsraProtocol.HelloReply, hostCaps: IsraProtocol.Caps)

  /// Caps in effect on the link: host & firmware. SENT_MSGS needs revision 2 or later
  /// (revision 1 used raw frames 30 / 31 / 32, which this build no longer reads).
  public var activeCaps: IsraProtocol.Caps {
    guard case let .supported(reply, hostCaps) = self else { return [] }
    var caps = reply.caps.intersection(hostCaps)
    if reply.revision < IsraProtocol.minimumSentMessagesRevision { caps.remove(.sentMessages) }
    return caps
  }
}

/// Per-session isra state, kept by `MeshCoreSession`.
struct IsraSessionState: Sendable {
  var hello: IsraHelloState = .notSent
  /// Set once a HELLO on this session negotiated SENT_MSGS. Never cleared during the
  /// session: on BLE the firmware keeps the cap until the link drops, even if a later
  /// HELLO goes unanswered.
  var sentMessagesNegotiated = false
}

public extension MeshCoreSession {
  /// Outcome of the last HELLO on this session.
  var israHello: IsraHelloState {
    isra.hello
  }

  /// Whether the device-sent message frames (0xE1 / 0x20-0x22) may be processed:
  /// a HELLO on this session negotiated SENT_MSGS. Never true with stock firmware.
  var israSentMessagesActive: Bool {
    isra.sentMessagesNegotiated
  }

  /// Sends HELLO again (for example after the user changed a host cap).
  /// Returns the new state; `.unsupported` is final for the session.
  @discardableResult
  func israResendHello() async throws -> IsraHelloState {
    guard let key = selfInfo?.publicKey else { return isra.hello }
    try await requestResponseSerializer.withSerialization { [self] in
      await israHelloHoldingSerialization(devicePublicKey: key)
    }
    return isra.hello
  }

  /// Sends PHONE_POS (built with ``IsraProtocol/phonePosition(latitude:longitude:altitudeMeters:horizontalAccuracy:ageSeconds:)``).
  func israSendPhonePosition(_ frame: Data) async throws -> IsraProtocol.PhonePositionOutcome {
    try await sendAndMatch(frame) { event in
      switch event {
      case .ok(value: nil):
        return .success(.accepted)
      case let .error(code):
        switch code.flatMap(ErrorCode.init(rawValue:)) {
        case .badState: return .success(.badState)
        case .illegalArgument: return .success(.illegalArgument)
        default: return .success(.deviceError(code ?? 0))
        }
      default:
        return .ignore
      }
    }
  }
}

extension MeshCoreSession {
  /// HELLO must not wait as long as ordinary commands: it runs inside the connection's
  /// APP_START, which the connection manager bounds to 10 s.
  static let israHelloTimeout: TimeInterval = 3

  /// APP_START then HELLO in one serialized slot, so no SYNC_NEXT_MESSAGE can slip in between.
  ///
  /// Over BLE the firmware keeps the host caps until the link drops (a later APP_START,
  /// sent after many settings writes, does not clear them), and a session lives for one
  /// link. So HELLO goes only with the session's first APP_START, or again after a HELLO
  /// that got no answer; ``israResendHello()`` sends it on demand.
  func israSendAppStartAndHello(_ appStart: Data) async throws -> SelfInfo {
    try await requestResponseSerializer.withSerialization { [self] in
      let info: SelfInfo = try await sendAndMatchHoldingSerialization(appStart) { event in
        if case let .selfInfo(info) = event { return .success(info) }
        return .ignore
      }
      if await israNeedsHello {
        await israHelloHoldingSerialization(devicePublicKey: info.publicKey)
      }
      return info
    }
  }

  var israNeedsHello: Bool {
    isra.hello == .notSent || isra.hello == .failed
  }

  /// The caller holds `requestResponseSerializer`. Never throws: a failed HELLO only
  /// leaves the isra features off.
  func israHelloHoldingSerialization(devicePublicKey: Data) async {
    guard isra.hello != .unsupported,
          var caps = IsraHooks.hostCaps(for: devicePublicKey) else { return }
    var state = await israExchangeHello(caps)
    // A revision 1 firmware would send device-sent messages as raw frames 30 / 31 / 32,
    // which this build no longer reads: ask again without SENT_MSGS, so it keeps
    // converting them into tagged received messages (the isra2 mirror) instead.
    if case let .supported(reply, _) = state,
       reply.revision < IsraProtocol.minimumSentMessagesRevision, caps.contains(.sentMessages) {
      caps.remove(.sentMessages)
      state = await israExchangeHello(caps)
    }
    guard let state else { return }
    isra.hello = state
    if state.activeCaps.contains(.sentMessages) { isra.sentMessagesNegotiated = true }
  }

  /// One HELLO round trip. nil on cancellation.
  private func israExchangeHello(_ caps: IsraProtocol.Caps) async -> IsraHelloState? {
    do {
      return try await sendAndMatchHoldingSerialization(
        IsraProtocol.hello(hostCaps: caps),
        timeout: min(Self.israHelloTimeout, configuration.defaultTimeout)
      ) { event in
        switch event {
        case .parseFailure:
          if case let .helloReply(reply)? = IsraProtocol.frame(from: event) {
            return .success(.supported(reply, hostCaps: caps))
          }
          return .ignore
        case let .error(code):
          return .success(code == ErrorCode.unsupportedCommand.rawValue ? .unsupported : .failed)
        default:
          return .ignore
        }
      }
    } catch is CancellationError {
      return nil
    } catch {
      logger.warning("isra HELLO failed: \(error.localizedDescription)")
      return .failed
    }
  }
}
